package transcription_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

func TestVocabularyCorrectionAndAmbiguity(t *testing.T) {
	opts := transcription.VocabOptions{
		MinimumLength:       4,
		MaximumDistance:     2,
		SimilarityThreshold: 0.72,
		AmbiguityMargin:     0.15,
	}
	got := transcription.CorrectText("Welcome to NeoRecal meeting about Kubernetis.", []string{"NeoRecall", "Kubernetes"}, opts)
	if got != "Welcome to NeoRecall meeting about Kubernetes." {
		t.Fatalf("unexpected vocabulary correction: %q", got)
	}
	// Ambiguous close pair should not guess.
	amb := transcription.CorrectText("Compare Moller today.", []string{"Miller", "Muller"}, opts)
	if amb != "Compare Moller today." {
		t.Fatalf("expected ambiguous term left unchanged, got %q", amb)
	}
}

func TestTranscriptQualityCompactsRepetition(t *testing.T) {
	opts := transcription.QualityOptions{
		MinimumRepeats:        4,
		MaximumPatternWords:   4,
		MinimumCoverage:       0.6,
		MaximumWordsPerSecond: 6.0,
	}
	segs := []transcription.Segment{{
		Text:    "yes sir yes sir yes sir yes sir yes sir yes sir",
		StartMs: 0,
		EndMs:   1000,
	}}
	res := transcription.CompactSegments(segs, opts)
	if res.ChangedSegments != 1 || res.RemovedWords != 10 {
		t.Fatalf("unexpected compaction result: %+v", res)
	}
	if res.Segments[0].Text != "yes sir" {
		t.Fatalf("expected compacted text 'yes sir', got %q", res.Segments[0].Text)
	}
}

func TestDedupeAndAlignSegments(t *testing.T) {
	lo := -0.8
	hi := -0.1
	prev := []transcription.Segment{{Text: "Hello everyone", StartMs: 100, EndMs: 900}}
	curr := []transcription.Segment{
		{Text: "hello, everyone!", StartMs: 120, EndMs: 880},
		{Text: "Next agenda item", StartMs: 1000, EndMs: 2500, ASRConfidence: &lo},
		{Text: "Next agenda item", StartMs: 1010, EndMs: 2490, ASRConfidence: &hi},
	}
	out := transcription.Dedupe(curr, prev, 0.85, 200)
	if len(out) != 1 || out[0].ASRConfidence == nil || *out[0].ASRConfidence != hi {
		t.Fatalf("unexpected dedupe output: %+v", out)
	}

	// Exact cross-stream suppression
	leftOnly := transcription.DedupeExactCrossStream(
		[]transcription.Segment{{Text: "We should ship today", StartMs: 500, EndMs: 2000}},
		[]transcription.Segment{{Text: "We should ship today!", StartMs: 550, EndMs: 1950}},
		200, 2,
	)
	if len(leftOnly) != 0 {
		t.Fatalf("expected cross-stream exact duplicate removed")
	}

	turns := []transcription.Turn{
		{StartMs: 0, EndMs: 3000, Speaker: 0, Embedding: []float32{1, 0}, SpeechMs: 3000},
		{StartMs: 1000, EndMs: 2000, Speaker: 1, Embedding: []float32{0, 1}, SpeechMs: 1000},
	}
	aligned := transcription.AlignSegments([]transcription.Segment{{Text: "Overlap test", StartMs: 500, EndMs: 2000}}, turns)
	if aligned[0].DiarizationSpeaker == nil || *aligned[0].DiarizationSpeaker != 0 || !aligned[0].OverlappingSpeech {
		t.Fatalf("unexpected alignment result: %+v", aligned[0])
	}
}

func TestPreprocessFilterChainAndDecodeIfFFmpegPresent(t *testing.T) {
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	applied, chain := transcription.BuildPreprocessFilters(cfg, nil, nil)
	if len(applied) == 0 || len(chain) != len(applied) {
		t.Fatalf("expected non-empty filter chain, got %v %v", applied, chain)
	}

	ff := transcription.ResolveFFmpegPath()
	wavPath := filepath.Join("..", "..", "test", "fixtures", "de_en_two_speakers.wav")
	if ff != "" {
		if _, err := os.Stat(wavPath); err == nil {
			prep := transcription.PreparePreprocess(context.Background(), ff, cfg, wavPath, "mono", 18000, nil)
			defer prep.Cleanup()
			if prep.FellBack {
				t.Fatalf("expected ffmpeg preprocess to succeed on wav fixture")
			}
			chans, err := transcription.DecodeAudio(context.Background(), ff, prep.Filename, "mono")
			if err != nil || len(chans) != 1 || len(chans[0].Samples) < 16000 {
				t.Fatalf("DecodeAudio failed: err=%v chans=%d", err, len(chans))
			}
		}
	}
}
