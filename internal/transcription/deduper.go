package transcription

import (
	"math"
	"sort"
	"strings"
)

// Tokens normalizes input with NFKC, lowercases it, and splits into word-like tokens.
func Tokens(value string) []string {
	spans := extractWordSpans(value)
	out := make([]string, len(spans))
	for i, sp := range spans {
		out[i] = strings.ToLower(sp.text)
	}
	return out
}

func reportedConfidence(v *float64) float64 {
	if v == nil || math.IsNaN(*v) || math.IsInf(*v, 0) {
		return math.Inf(-1)
	}
	return *v
}

func Similarity(left, right string) float64 {
	a := Tokens(left)
	b := Tokens(right)
	if len(a) == 0 || len(b) == 0 {
		return 0
	}
	prev := make([]int, len(b)+1)
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		for j := 1; j <= len(b); j++ {
			if a[i-1] == b[j-1] {
				cur[j] = prev[j-1] + 1
			} else {
				cur[j] = max(prev[j], cur[j-1])
			}
		}
		prev = cur
	}
	return float64(prev[len(b)]) / float64(max(len(a), len(b)))
}

func ExactSameUtterance(left, right string, minimumWords int) bool {
	if minimumWords < 2 {
		minimumWords = 2
	}
	a := Tokens(left)
	b := Tokens(right)
	if len(a) < minimumWords || len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func DedupeExactCrossStream(segments, candidates []Segment, timeToleranceMs, minimumWords int) []Segment {
	if minimumWords < 2 {
		minimumWords = 2
	}
	out := make([]Segment, 0, len(segments))
	for _, seg := range segments {
		dup := false
		for _, cand := range candidates {
			overlaps := seg.StartMs < cand.EndMs && cand.StartMs < seg.EndMs
			if !overlaps {
				continue
			}
			dStart := cand.StartMs - seg.StartMs
			if dStart < 0 {
				dStart = -dStart
			}
			dEnd := cand.EndMs - seg.EndMs
			if dEnd < 0 {
				dEnd = -dEnd
			}
			if dStart <= timeToleranceMs && dEnd <= timeToleranceMs && ExactSameUtterance(cand.Text, seg.Text, minimumWords) {
				dup = true
				break
			}
		}
		if !dup {
			out = append(out, seg)
		}
	}
	return out
}

func Dedupe(segments, previousSegments []Segment, similarityThreshold float64, timeToleranceMs int) []Segment {
	sorted := make([]Segment, len(segments))
	copy(sorted, segments)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].StartMs < sorted[j].StartMs
	})
	var accepted []Segment
	matches := func(cand, seg Segment) bool {
		dS := cand.StartMs - seg.StartMs
		if dS < 0 {
			dS = -dS
		}
		dE := cand.EndMs - seg.EndMs
		if dE < 0 {
			dE = -dE
		}
		return dS <= timeToleranceMs && dE <= timeToleranceMs && Similarity(cand.Text, seg.Text) >= similarityThreshold
	}
	for _, seg := range sorted {
		foundInPrev := false
		for _, cand := range previousSegments {
			if matches(cand, seg) {
				foundInPrev = true
				break
			}
		}
		if foundInPrev {
			continue
		}
		dupIdx := -1
		for idx, cand := range accepted {
			if matches(cand, seg) {
				dupIdx = idx
				break
			}
		}
		if dupIdx < 0 {
			accepted = append(accepted, seg)
		} else if reportedConfidence(seg.ASRConfidence) > reportedConfidence(accepted[dupIdx].ASRConfidence) {
			accepted[dupIdx] = seg
		}
	}
	return accepted
}
