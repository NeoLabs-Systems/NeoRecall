package transcription

import (
	"math"
	"strings"
)

// Segment is the normalized output unit produced by every transcription provider
// and aligned with speaker diarization before persistence.
type Segment struct {
	Text               string    `json:"text"`
	Language           string    `json:"language,omitempty"`
	StartMs            int       `json:"startMs"`
	EndMs              int       `json:"endMs"`
	SourceComponent    string    `json:"sourceComponent"`
	ASRConfidence      *float64  `json:"asrConfidence,omitempty"`
	DiarizationSpeaker *int      `json:"diarizationSpeaker,omitempty"`
	SpeakerEmbedding   []float32 `json:"speakerEmbedding,omitempty"`
	SpeakerSpeechMs    *int      `json:"speakerSpeechMs,omitempty"`
	SpeakerConfidence  *float64  `json:"speakerConfidence,omitempty"`
	OverlappingSpeech  bool      `json:"overlappingSpeech"`
}

// BuildSegments trims text, defaults absent SourceComponent/EndMs, and drops blank segments.
func BuildSegments(items []Segment) []Segment {
	out := make([]Segment, 0, len(items))
	for _, s := range items {
		s.Text = strings.TrimSpace(s.Text)
		if s.Text == "" {
			continue
		}
		if s.SourceComponent == "" {
			s.SourceComponent = "combined"
		}
		if s.EndMs < s.StartMs {
			s.EndMs = s.StartMs
		}
		out = append(out, s)
	}
	return out
}

func SecondsToMs(sec float64) int {
	if math.IsNaN(sec) || math.IsInf(sec, 0) {
		return 0
	}
	return int(math.Round(sec * 1000))
}
