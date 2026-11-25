package transcription

import (
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

type wordSpan struct {
	text       string
	byteStart  int
	comparable string
}

func isWordRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsMark(r)
}

func extractWordSpans(value string) []wordSpan {
	text := norm.NFKC.String(value)
	var items []wordSpan
	inWord := false
	start := 0
	for i, r := range text {
		if isWordRune(r) {
			if !inWord {
				inWord = true
				start = i
			}
		} else if inWord {
			w := text[start:i]
			items = append(items, wordSpan{
				text:       w,
				byteStart:  start,
				comparable: comparableToken(w),
			})
			inWord = false
		}
	}
	if inWord {
		w := text[start:]
		items = append(items, wordSpan{
			text:       w,
			byteStart:  start,
			comparable: comparableToken(w),
		})
	}
	return items
}

func comparableToken(w string) string {
	allDigits := w != ""
	for _, r := range w {
		if !unicode.IsNumber(r) {
			allDigits = false
			break
		}
	}
	if allDigits {
		return "<number>"
	}
	return strings.ToLower(w)
}

type QualityOptions struct {
	MinimumRepeats        int
	MaximumPatternWords   int
	MinimumCoverage       float64
	MaximumWordsPerSecond float64
}

type repetitionRun struct {
	start        int
	repeats      int
	patternWords int
	runWords     int
}

func dominantRepeatedRun(items []wordSpan, opts QualityOptions) *repetitionRun {
	var best *repetitionRun
	maxPat := min(opts.MaximumPatternWords, len(items)/max(1, opts.MinimumRepeats))
	for pat := 1; pat <= maxPat; pat++ {
		for start := 0; start+(pat*opts.MinimumRepeats) <= len(items); start++ {
			repeats := 1
			for start+((repeats+1)*pat) <= len(items) {
				same := true
				for off := range pat {
					if items[start+off].comparable != items[start+repeats*pat+off].comparable {
						same = false
						break
					}
				}
				if !same {
					break
				}
				repeats++
			}
			if repeats < opts.MinimumRepeats {
				continue
			}
			runWords := repeats * pat
			cov := float64(runWords) / float64(len(items))
			if cov < opts.MinimumCoverage {
				continue
			}
			if best == nil || runWords > best.runWords || (runWords == best.runWords && pat < best.patternWords) {
				best = &repetitionRun{start: start, repeats: repeats, patternWords: pat, runWords: runWords}
			}
		}
	}
	return best
}

type QualityResult struct {
	Segments        []Segment
	ChangedSegments int
	RemovedWords    int
}

func CompactSegments(segments []Segment, opts QualityOptions) QualityResult {
	out := make([]Segment, len(segments))
	var changed, removedWords int
	for i, seg := range segments {
		text := norm.NFKC.String(seg.Text)
		items := extractWordSpans(text)
		durSec := float64(seg.EndMs-seg.StartMs) / 1000.0
		if len(items) == 0 || durSec <= 0 || float64(len(items))/durSec <= opts.MaximumWordsPerSecond {
			out[i] = seg
			continue
		}
		run := dominantRepeatedRun(items, opts)
		if run == nil {
			out[i] = seg
			continue
		}
		repStart := items[run.start].byteStart
		secondStart := items[run.start+run.patternWords].byteStart
		runEndIdx := run.start + run.runWords
		repEnd := len(text)
		if runEndIdx < len(items) {
			repEnd = items[runEndIdx].byteStart
		}
		firstOcc := text[repStart:secondStart]
		seg.Text = strings.TrimSpace(text[:repStart] + firstOcc + text[repEnd:])
		out[i] = seg
		changed++
		removedWords += run.runWords - run.patternWords
	}
	return QualityResult{Segments: out, ChangedSegments: changed, RemovedWords: removedWords}
}
