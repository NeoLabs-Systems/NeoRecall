package transcription

import "sort"

// Turn represents a diarized speaker turn within a chunk.
type Turn struct {
	StartMs   int
	EndMs     int
	Speaker   int
	Embedding []float32
	SpeechMs  int
}

func OverlapMs(aStart, aEnd, bStart, bEnd int) int {
	lo := max(aStart, bStart)
	hi := min(aEnd, bEnd)
	if hi <= lo {
		return 0
	}
	return hi - lo
}

// AlignSegments pairs ASR segments with the diarization turn having largest temporal overlap.
func AlignSegments(asrSegments []Segment, turns []Turn) []Segment {
	out := make([]Segment, len(asrSegments))
	for i, seg := range asrSegments {
		type hit struct {
			turn    Turn
			overlap int
		}
		var ranked []hit
		for _, t := range turns {
			if ov := OverlapMs(seg.StartMs, seg.EndMs, t.StartMs, t.EndMs); ov > 0 {
				ranked = append(ranked, hit{turn: t, overlap: ov})
			}
		}
		sort.SliceStable(ranked, func(a, b int) bool {
			return ranked[a].overlap > ranked[b].overlap
		})
		if len(ranked) > 0 {
			best := ranked[0]
			spk := best.turn.Speaker
			seg.DiarizationSpeaker = &spk
			seg.SpeakerEmbedding = best.turn.Embedding
			sm := best.turn.SpeechMs
			seg.SpeakerSpeechMs = &sm
			dur := max(1, seg.EndMs-seg.StartMs)
			conf := float64(best.overlap) / float64(dur)
			seg.SpeakerConfidence = &conf
			seg.OverlappingSpeech = len(ranked) > 1 && float64(ranked[1].overlap)/float64(dur) > 0.2
		}
		out[i] = seg
	}
	return out
}
