//! Accumulates decimated mono PCM into upload-sized chunks with overlap
//! carry-forward.
//!
//! **A subtlety worth documenting carefully, since getting it wrong would
//! corrupt the capture timeline:** a chunk after the first *re-includes*
//! `overlap_ms` of audio duplicated from the tail of the previous chunk (so
//! the server's transcript-level dedup has material to work with). That
//! means two different things are both colloquially "this chunk's
//! duration":
//!
//! - [`EmittedChunk::audio_duration_ms`] -- the full length of the actual
//!   uploaded audio (overlap prefix + new content). This is what goes in
//!   the `X-Chunk-Duration-Ms` header.
//! - [`EmittedChunk::new_content_ms`] -- just the genuinely new portion.
//!   This is the amount by which the capture timeline actually advances,
//!   and is what must be passed to `nrd-ledger`'s
//!   `Store::allocate_sequence(source_id, duration_ms)` so
//!   `monotonic_offset_ms` reflects real elapsed time rather than
//!   double-counting overlapped audio on every chunk.

pub struct EmittedChunk {
    pub samples: Vec<i16>,
    pub audio_duration_ms: u32,
    pub overlap_ms: u32,
    pub new_content_ms: u32,
    pub is_final: bool,
}

pub struct Chunker {
    sample_rate: u32,
    target_samples: usize,
    overlap_samples: usize,
    /// Newly arrived samples not yet emitted, excluding the overlap prefix.
    pending: Vec<i16>,
    /// The tail of the most recently emitted chunk, to prefix onto the
    /// next one. Empty until the first chunk has been emitted.
    overlap_tail: Vec<i16>,
}

impl Chunker {
    pub fn new(sample_rate: u32, target_ms: u32, overlap_ms: u32) -> Self {
        let target_samples = ms_to_samples(sample_rate, target_ms);
        let overlap_samples =
            ms_to_samples(sample_rate, overlap_ms).min(target_samples.saturating_sub(1));
        Chunker {
            sample_rate,
            target_samples,
            overlap_samples,
            pending: Vec::new(),
            overlap_tail: Vec::new(),
        }
    }

    pub fn push(&mut self, samples: &[i16]) {
        self.pending.extend_from_slice(samples);
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    /// Emits a chunk once `target_samples` of new content have accumulated,
    /// or immediately (with whatever is left, however short) when
    /// `force_final` is set -- matching the server's relaxed minimum
    /// duration for a chunk marked `X-Final-Chunk: true`. Returns `None` if
    /// there is nothing to emit (not enough pending audio, and not final).
    pub fn take_chunk(&mut self, force_final: bool) -> Option<EmittedChunk> {
        if self.pending.is_empty() && !force_final {
            return None;
        }
        if self.pending.len() < self.target_samples && !force_final {
            return None;
        }
        if self.pending.is_empty() && force_final {
            return None; // nothing at all to flush
        }

        let take = if force_final {
            self.pending.len()
        } else {
            self.target_samples
        };
        let new_content: Vec<i16> = self.pending.drain(..take).collect();

        let mut samples = Vec::with_capacity(self.overlap_tail.len() + new_content.len());
        samples.extend_from_slice(&self.overlap_tail);
        samples.extend_from_slice(&new_content);

        let overlap_ms = samples_to_ms(self.sample_rate, self.overlap_tail.len());
        let new_content_ms = samples_to_ms(self.sample_rate, new_content.len());
        let audio_duration_ms = samples_to_ms(self.sample_rate, samples.len());

        // Prepare the overlap prefix for the *next* chunk from the tail of
        // this one's new content -- never re-uses the current chunk's own
        // overlap prefix, which would grow monotonically instead of
        // sliding.
        self.overlap_tail = if force_final {
            Vec::new() // no next chunk after a final one
        } else {
            let tail_start = new_content.len().saturating_sub(self.overlap_samples);
            new_content[tail_start..].to_vec()
        };

        Some(EmittedChunk {
            samples,
            audio_duration_ms,
            overlap_ms,
            new_content_ms,
            is_final: force_final,
        })
    }
}

fn ms_to_samples(sample_rate: u32, ms: u32) -> usize {
    ((sample_rate as u64 * ms as u64) / 1000) as usize
}

fn samples_to_ms(sample_rate: u32, samples: usize) -> u32 {
    if sample_rate == 0 {
        0
    } else {
        ((samples as u64 * 1000) / sample_rate as u64) as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn silence(n: usize) -> Vec<i16> {
        vec![0i16; n]
    }

    #[test]
    fn the_first_chunk_has_no_overlap_prefix() {
        let mut chunker = Chunker::new(16_000, 1_000, 200); // 1s target, 200ms overlap
        chunker.push(&silence(16_000));
        let chunk = chunker.take_chunk(false).unwrap();
        assert_eq!(chunk.overlap_ms, 0);
        assert_eq!(chunk.new_content_ms, 1_000);
        assert_eq!(chunk.audio_duration_ms, 1_000);
        assert_eq!(chunk.samples.len(), 16_000);
    }

    #[test]
    fn the_second_chunk_prefixes_the_overlap_from_the_first() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        chunker.push(&silence(16_000));
        chunker.take_chunk(false).unwrap();

        chunker.push(&silence(16_000));
        let chunk = chunker.take_chunk(false).unwrap();
        assert_eq!(chunk.overlap_ms, 200);
        assert_eq!(chunk.new_content_ms, 1_000);
        // Full audio duration includes the overlap prefix.
        assert_eq!(chunk.audio_duration_ms, 1_200);
        assert_eq!(chunk.samples.len(), 16_000 + 3_200); // 200ms @ 16kHz = 3200 samples
    }

    #[test]
    fn new_content_ms_never_double_counts_overlap_across_many_chunks() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        let mut total_new_content_ms: u64 = 0;
        for _ in 0..10 {
            chunker.push(&silence(16_000));
            let chunk = chunker.take_chunk(false).unwrap();
            total_new_content_ms += chunk.new_content_ms as u64;
        }
        // 10 chunks of exactly 1s of genuinely new audio each -- the
        // timeline must advance by exactly 10s, not more (which double
        // counting the overlap would cause) and not less.
        assert_eq!(total_new_content_ms, 10_000);
    }

    #[test]
    fn a_forced_final_chunk_flushes_a_shorter_remainder() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        chunker.push(&silence(8_000)); // only 0.5s pending, below target
        assert!(chunker.take_chunk(false).is_none());
        let chunk = chunker.take_chunk(true).unwrap();
        assert!(chunk.is_final);
        assert_eq!(chunk.new_content_ms, 500);
    }

    #[test]
    fn a_forced_final_chunk_with_nothing_pending_emits_nothing() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        assert!(chunker.take_chunk(true).is_none());
    }

    #[test]
    fn no_chunk_is_emitted_before_the_target_is_reached() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        chunker.push(&silence(15_999));
        assert!(chunker.take_chunk(false).is_none());
    }

    #[test]
    fn overlap_samples_are_clamped_below_the_target_so_a_chunk_never_shrinks_to_nothing_new() {
        // A pathological overlap_ms >= target_ms must not be allowed to
        // consume the entire chunk.
        let chunker = Chunker::new(16_000, 1_000, 5_000);
        assert!(chunker.overlap_samples < chunker.target_samples);
    }

    #[test]
    fn a_final_chunk_never_produces_a_following_overlap_prefix() {
        let mut chunker = Chunker::new(16_000, 1_000, 200);
        chunker.push(&silence(16_000));
        chunker.take_chunk(false).unwrap();
        chunker.push(&silence(4_000));
        chunker.take_chunk(true).unwrap();
        assert!(chunker.overlap_tail.is_empty());
    }
}
