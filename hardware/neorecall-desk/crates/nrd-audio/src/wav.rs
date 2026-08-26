//! Canonical 44-byte-header PCM WAV serialization for mono S16LE chunk
//! audio. Deliberately duplicates the tiny header builder in
//! `nrd-ledger::wav_repair` rather than sharing it -- that copy exists only
//! to repair a crash-interrupted file from raw bytes, this one is the
//! primary encode path from freshly captured/decimated samples, and keeping
//! them independent means a bug in one cannot corrupt the other's contract.

pub const HEADER_LEN: usize = 44;

pub fn encode_mono_pcm16(sample_rate: u32, samples: &[i16]) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let byte_rate = sample_rate * 2;
    let mut out = Vec::with_capacity(HEADER_LEN + data_len as usize);

    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_a_valid_riff_wave_header_with_correct_sizes() {
        let samples = [1i16, -2, 3, -4];
        let bytes = encode_mono_pcm16(16_000, &samples);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(u32::from_le_bytes(bytes[4..8].try_into().unwrap()), 36 + 8);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 8);
        assert_eq!(bytes.len(), HEADER_LEN + 8);
    }

    #[test]
    fn samples_round_trip_as_little_endian_i16() {
        let samples = [1i16, -2, 3, -4];
        let bytes = encode_mono_pcm16(16_000, &samples);
        let payload = &bytes[HEADER_LEN..];
        for (i, expected) in samples.iter().enumerate() {
            let value = i16::from_le_bytes([payload[i * 2], payload[i * 2 + 1]]);
            assert_eq!(value, *expected);
        }
    }

    #[test]
    fn an_empty_sample_slice_still_produces_a_valid_header() {
        let bytes = encode_mono_pcm16(16_000, &[]);
        assert_eq!(bytes.len(), HEADER_LEN);
        assert_eq!(u32::from_le_bytes(bytes[40..44].try_into().unwrap()), 0);
    }
}
