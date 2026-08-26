//! 48 kHz stereo -> 16 kHz mono, via a fixed integer-ratio (3:1) windowed-
//! sinc FIR decimator. A fixed integer ratio is deliberate (see
//! `nrd-config::AudioConfig::is_integer_decimation_ratio`, which the config
//! loader validates against): it is exact for this one hardware pair and
//! needs no fractional resampling library. Downmixing stereo to mono
//! happens first (a plain average, not a rate change, so it cannot
//! introduce aliasing), then the mono stream is low-pass filtered and
//! decimated -- naively dropping every third sample without filtering would
//! alias energy above the new 8 kHz Nyquist back into the audible band.

pub fn downmix_stereo_to_mono(interleaved: &[i16]) -> Vec<i16> {
    interleaved
        .as_chunks::<2>()
        .0
        .iter()
        .map(|frame| {
            let sum = frame[0] as i32 + frame[1] as i32;
            // Round to nearest rather than truncate.
            (if sum >= 0 {
                (sum + 1) / 2
            } else {
                (sum - 1) / 2
            }) as i16
        })
        .collect()
}

/// A windowed-sinc lowpass FIR designed for decimation by `ratio`, applied
/// as a streaming filter via a persistent sliding window: a chunk boundary
/// never resets or misaligns the decimation phase, regardless of how input
/// is split across `process` calls.
pub struct Decimator {
    ratio: usize,
    taps: Vec<f64>,
    /// A sliding window of not-yet-fully-consumed samples, pre-filled with
    /// `taps.len() - 1` leading zeros at construction to represent the
    /// filter's startup transient consistently (as if audio had been
    /// silent immediately before capture started). The oldest `ratio`
    /// samples are popped after every output, so the window's front always
    /// holds the next center position.
    window: std::collections::VecDeque<f64>,
}

impl Decimator {
    pub fn new(ratio: usize, num_taps: usize) -> Self {
        assert!(ratio >= 1, "decimation ratio must be at least 1");
        assert!(num_taps >= 2, "a decimation filter needs at least 2 taps");
        let taps = design_lowpass(ratio, num_taps);
        let mut window = std::collections::VecDeque::with_capacity(num_taps * 2);
        window.extend(std::iter::repeat_n(0.0, num_taps - 1));
        Decimator {
            ratio,
            taps,
            window,
        }
    }

    /// Consumes `input` (mono samples at the pre-decimation rate) and
    /// returns as many fully-filtered output samples as are now available.
    /// Splitting the same input across multiple calls (in any chunk sizes)
    /// produces bit-identical output to one large call, since the sliding
    /// window carries the exact decimation phase forward.
    pub fn process(&mut self, input: &[i16]) -> Vec<i16> {
        self.window.extend(input.iter().map(|&s| s as f64));

        let taps_len = self.taps.len();
        let mut output = Vec::new();
        while self.window.len() >= taps_len {
            // The taps are a symmetric (linear-phase) Hamming-windowed
            // sinc, so front-to-back alignment against the window needs no
            // reversal.
            let filtered: f64 = self
                .window
                .iter()
                .take(taps_len)
                .zip(self.taps.iter())
                .map(|(x, h)| x * h)
                .sum();
            output.push(filtered.round().clamp(i16::MIN as f64, i16::MAX as f64) as i16);
            for _ in 0..self.ratio.min(self.window.len()) {
                self.window.pop_front();
            }
        }
        output
    }
}

fn design_lowpass(ratio: usize, num_taps: usize) -> Vec<f64> {
    use std::f64::consts::PI;
    let cutoff = 0.5 / ratio as f64; // normalized cycles/sample; new Nyquist
    let n = num_taps as f64;
    let mut taps: Vec<f64> = (0..num_taps)
        .map(|i| {
            let x = i as f64 - (n - 1.0) / 2.0;
            let sinc = if x.abs() < 1e-12 {
                2.0 * cutoff
            } else {
                (2.0 * PI * cutoff * x).sin() / (PI * x)
            };
            // Hamming window.
            let window = 0.54 - 0.46 * (2.0 * PI * i as f64 / (n - 1.0)).cos();
            sinc * window
        })
        .collect();
    let sum: f64 = taps.iter().sum();
    for t in &mut taps {
        *t /= sum; // unity DC gain
    }
    taps
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_left_and_right_with_correct_rounding() {
        let interleaved = [10i16, 20, -10, -20, 5, 4];
        let mono = downmix_stereo_to_mono(&interleaved);
        assert_eq!(mono, vec![15, -15, 5]); // (5+4)/2 rounds to 5 (round-half-away-from-zero via +1)
    }

    #[test]
    fn downmix_output_length_is_half_the_input() {
        let interleaved = vec![0i16; 2000];
        assert_eq!(downmix_stereo_to_mono(&interleaved).len(), 1000);
    }

    #[test]
    fn filter_taps_sum_to_unity_for_dc_gain() {
        let taps = design_lowpass(3, 64);
        let sum: f64 = taps.iter().sum();
        assert!((sum - 1.0).abs() < 1e-9);
    }

    #[test]
    fn decimation_reduces_sample_count_by_the_ratio_in_steady_state() {
        let mut dec = Decimator::new(3, 64);
        let input = vec![0i16; 3000];
        let output = dec.process(&input);
        // Some samples are held back as filter history between calls; over
        // a long steady run the count converges to input/ratio.
        assert!(
            (output.len() as i64 - 1000).abs() <= 1,
            "expected ~1000 output samples, got {}",
            output.len()
        );
    }

    #[test]
    fn a_constant_dc_signal_passes_through_at_unity_gain_in_steady_state() {
        let mut dec = Decimator::new(3, 64);
        let input = vec![1000i16; 3000];
        let output = dec.process(&input);
        // Skip the filter's initial transient (leading zeros in history);
        // steady-state output should sit at the same DC level.
        let steady = &output[output.len() - 100..];
        for &sample in steady {
            assert!(
                (sample as i32 - 1000).abs() <= 1,
                "expected ~1000, got {sample}"
            );
        }
    }

    #[test]
    fn a_high_frequency_tone_above_the_new_nyquist_is_significantly_attenuated() {
        // 48 kHz input, a 12 kHz tone -- well above the 8 kHz Nyquist that
        // survives decimation by 3 to 16 kHz. Naive sample-dropping would
        // alias this tone into the passband; a proper lowpass must not.
        let sample_rate = 48_000.0;
        let freq = 12_000.0;
        let n = 4800;
        let input: Vec<i16> = (0..n)
            .map(|i| {
                (10_000.0 * (2.0 * std::f64::consts::PI * freq * i as f64 / sample_rate).sin())
                    as i16
            })
            .collect();

        let input_rms = rms(&input);
        let mut dec = Decimator::new(3, 64);
        let output = dec.process(&input);
        let steady = &output[200..]; // skip transient
        let output_rms = rms(steady);

        assert!(
            output_rms < input_rms * 0.15,
            "expected strong attenuation: input_rms={input_rms}, output_rms={output_rms}"
        );
    }

    #[test]
    fn a_low_frequency_tone_well_within_the_new_nyquist_survives_with_similar_amplitude() {
        let sample_rate = 48_000.0;
        let freq = 1_000.0; // well under 8 kHz
        let n = 4800;
        let input: Vec<i16> = (0..n)
            .map(|i| {
                (10_000.0 * (2.0 * std::f64::consts::PI * freq * i as f64 / sample_rate).sin())
                    as i16
            })
            .collect();

        let input_rms = rms(&input);
        let mut dec = Decimator::new(3, 64);
        let output = dec.process(&input);
        let steady = &output[200..];
        let output_rms = rms(steady);

        assert!(
            output_rms > input_rms * 0.8,
            "expected the passband tone to survive: input_rms={input_rms}, output_rms={output_rms}"
        );
    }

    #[test]
    fn streaming_across_multiple_small_calls_matches_one_large_call() {
        let sample_rate = 48_000.0;
        let freq = 1_000.0;
        let n = 3000;
        let input: Vec<i16> = (0..n)
            .map(|i| {
                (5_000.0 * (2.0 * std::f64::consts::PI * freq * i as f64 / sample_rate).sin())
                    as i16
            })
            .collect();

        let mut whole = Decimator::new(3, 64);
        let whole_output = whole.process(&input);

        let mut streamed = Decimator::new(3, 64);
        let mut streamed_output = Vec::new();
        for chunk in input.chunks(97) {
            // an awkward, non-ratio-aligned chunk size on purpose
            streamed_output.extend(streamed.process(chunk));
        }

        assert_eq!(
            whole_output, streamed_output,
            "streaming in arbitrary chunk sizes must produce identical output to one large call"
        );
    }

    fn rms(samples: &[i16]) -> f64 {
        let sum_sq: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
        (sum_sq / samples.len() as f64).sqrt()
    }
}
