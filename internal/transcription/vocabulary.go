package transcription

import (
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

var (
	vocabWordRe      = regexp.MustCompile(`[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*`)
	vocabWholeWordRe = regexp.MustCompile(`^[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*$`)
)

type VocabOptions struct {
	MinimumLength       int
	MaximumDistance     int
	SimilarityThreshold float64
	AmbiguityMargin     float64
}

func normalizeWord(s string) string {
	return strings.ToLower(norm.NFKC.String(s))
}

func EditDistance(left, right []rune) int {
	if string(left) == string(right) {
		return 0
	}
	prev := make([]int, len(right)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(left); i++ {
		cur := make([]int, len(right)+1)
		cur[0] = i
		for j := 1; j <= len(right); j++ {
			sub := 0
			if left[i-1] != right[j-1] {
				sub = 1
			}
			cur[j] = min(cur[j-1]+1, prev[j]+1, prev[j-1]+sub)
		}
		prev = cur
	}
	return prev[len(right)]
}

type vocabCandidate struct {
	term       string
	normalized string
	runes      []rune
}

func buildVocabCandidates(vocab []string, minimumLength int) []vocabCandidate {
	var out []vocabCandidate
	for _, t := range vocab {
		if !vocabWholeWordRe.MatchString(t) {
			continue
		}
		n := normalizeWord(t)
		r := []rune(n)
		if len(r) >= minimumLength {
			out = append(out, vocabCandidate{term: t, normalized: n, runes: r})
		}
	}
	return out
}

func CorrectText(text string, vocab []string, opts VocabOptions) string {
	entries := buildVocabCandidates(vocab, opts.MinimumLength)
	if len(entries) == 0 {
		return text
	}
	exactSet := make(map[string]bool, len(entries))
	for _, e := range entries {
		exactSet[e.normalized] = true
	}

	return vocabWordRe.ReplaceAllStringFunc(text, func(word string) string {
		src := normalizeWord(word)
		srcRunes := []rune(src)
		if len(srcRunes) < opts.MinimumLength || exactSet[src] {
			return word
		}
		firstSrc, _ := utf8.DecodeRuneInString(src)
		type match struct {
			term       string
			distance   int
			similarity float64
		}
		var ranked []match
		for _, e := range entries {
			if len(e.runes) == 0 || e.runes[0] != firstSrc {
				continue
			}
			diffLen := len(e.runes) - len(srcRunes)
			if diffLen < 0 {
				diffLen = -diffLen
			}
			if diffLen > opts.MaximumDistance {
				continue
			}
			dist := EditDistance(srcRunes, e.runes)
			sim := 1.0 - float64(dist)/float64(max(len(srcRunes), len(e.runes)))
			if dist <= opts.MaximumDistance && sim >= opts.SimilarityThreshold {
				ranked = append(ranked, match{term: e.term, distance: dist, similarity: sim})
			}
		}
		if len(ranked) == 0 {
			return word
		}
		sort.Slice(ranked, func(i, j int) bool {
			if ranked[i].similarity != ranked[j].similarity {
				return ranked[i].similarity > ranked[j].similarity
			}
			return ranked[i].distance < ranked[j].distance
		})
		best := ranked[0]
		if len(ranked) > 1 && best.similarity-ranked[1].similarity < opts.AmbiguityMargin {
			return word
		}
		return best.term
	})
}

func CorrectSegments(segments []Segment, vocab []string, opts VocabOptions) []Segment {
	if len(vocab) == 0 {
		return segments
	}
	out := make([]Segment, len(segments))
	for i, s := range segments {
		s.Text = CorrectText(s.Text, vocab, opts)
		out[i] = s
	}
	return out
}
