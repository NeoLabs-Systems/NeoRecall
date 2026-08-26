//! Minimal canonical 44-byte PCM WAV header handling, used only to repair a
//! `.partial` file left behind by a crash mid-write (recovery boundary #3 in
//! the crash-recovery table: row `capturing`, `.partial` exists, rename not
//! done). This is deliberately not a general WAV codec — chunk audio is
//! always mono S16LE PCM at a single sample rate, written by `nrd-audio`'s
//! chunker.

pub const HEADER_LEN: usize = 44;

/// Builds a canonical 44-byte PCM WAV header for `data_len` bytes of mono
/// S16LE audio at `sample_rate`.
pub fn build_header(sample_rate: u32, data_len: u32) -> [u8; HEADER_LEN] {
    let mut header = [0u8; HEADER_LEN];
    let byte_rate = sample_rate * 2; // mono, 16-bit
    let riff_size = 36 + data_len;

    header[0..4].copy_from_slice(b"RIFF");
    header[4..8].copy_from_slice(&riff_size.to_le_bytes());
    header[8..12].copy_from_slice(b"WAVE");
    header[12..16].copy_from_slice(b"fmt ");
    header[16..20].copy_from_slice(&16u32.to_le_bytes()); // fmt chunk size
    header[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM
    header[22..24].copy_from_slice(&1u16.to_le_bytes()); // mono
    header[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    header[28..32].copy_from_slice(&byte_rate.to_le_bytes());
    header[32..34].copy_from_slice(&2u16.to_le_bytes()); // block align
    header[34..36].copy_from_slice(&16u16.to_le_bytes()); // bits per sample
    header[36..40].copy_from_slice(b"data");
    header[40..44].copy_from_slice(&data_len.to_le_bytes());
    header
}

/// Repairs bytes from an interrupted write: truncates the PCM payload to a
/// whole number of 16-bit frames (a torn last sample is discarded, not
/// zero-padded — padding would fabricate audio that was never captured) and
/// rewrites the RIFF/data chunk sizes to match the truncated length,
/// regardless of what the original (possibly zeroed or stale) header said.
///
/// Returns `None` if there isn't even a complete header plus one full frame
/// — nothing worth recovering.
pub fn recover_truncated(raw: &[u8], sample_rate: u32) -> Option<Vec<u8>> {
    if raw.len() < HEADER_LEN + 2 {
        return None;
    }
    let payload = &raw[HEADER_LEN..];
    let whole_frames = payload.len() / 2;
    let truncated_len = whole_frames * 2;
    if truncated_len == 0 {
        return None;
    }
    let mut out = Vec::with_capacity(HEADER_LEN + truncated_len);
    out.extend_from_slice(&build_header(sample_rate, truncated_len as u32));
    out.extend_from_slice(&payload[..truncated_len]);
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_clean_file_round_trips_with_the_same_audio_bytes() {
        let header = build_header(16_000, 4);
        let mut raw = header.to_vec();
        raw.extend_from_slice(&[1, 2, 3, 4]);
        let recovered = recover_truncated(&raw, 16_000).unwrap();
        assert_eq!(&recovered[HEADER_LEN..], &[1, 2, 3, 4]);
        assert_eq!(&recovered[40..44], &4u32.to_le_bytes());
    }

    #[test]
    fn a_torn_final_sample_is_discarded_not_zero_padded() {
        let header = build_header(16_000, 5);
        let mut raw = header.to_vec();
        raw.extend_from_slice(&[1, 2, 3, 4, 9]); // 2 whole frames + 1 stray byte
        let recovered = recover_truncated(&raw, 16_000).unwrap();
        assert_eq!(&recovered[HEADER_LEN..], &[1, 2, 3, 4]);
        assert_eq!(&recovered[40..44], &4u32.to_le_bytes());
    }

    #[test]
    fn the_riff_size_field_matches_the_truncated_length_even_if_the_original_header_lied() {
        // Header claims far more data than actually exists (a crash before
        // the final header rewrite that normally happens at chunk close).
        let mut raw = build_header(16_000, 1_000_000).to_vec();
        raw.extend_from_slice(&[5, 6, 7, 8]);
        let recovered = recover_truncated(&raw, 16_000).unwrap();
        assert_eq!(&recovered[4..8], &(36u32 + 4).to_le_bytes());
        assert_eq!(&recovered[40..44], &4u32.to_le_bytes());
    }

    #[test]
    fn a_file_with_no_complete_frame_is_not_recoverable() {
        let mut raw = build_header(16_000, 0).to_vec();
        raw.push(1); // one stray byte, not even a full sample
        assert!(recover_truncated(&raw, 16_000).is_none());
    }

    #[test]
    fn a_file_shorter_than_the_header_is_not_recoverable() {
        assert!(recover_truncated(&[0u8; 10], 16_000).is_none());
    }
}
