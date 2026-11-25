package embeddings

import (
	"encoding/json"
	"math"
	"os"
	"sort"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

const (
	clsToken = "<s>"
	sepToken = "</s>"
	unkToken = "<unk>"
	padToken = "<pad>"
)

type Tokenizer struct {
	vocab   map[string]int32
	scores  map[string]float64
	unkID   int32
	clsID   int32
	sepID   int32
	padID   int32
	maxLen  int
	sortedK []string
	maxRune int
}

type hfTokenizerJSON struct {
	Model struct {
		Type  string  `json:"type"`
		UnkID int     `json:"unk_id"`
		Vocab [][]any `json:"vocab"`
	} `json:"model"`
	AddedTokens []struct {
		ID      int32  `json:"id"`
		Content string `json:"content"`
	} `json:"added_tokens"`
}

func LoadTokenizer(path string) (*Tokenizer, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var parsed hfTokenizerJSON
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}
	t := &Tokenizer{
		vocab:  make(map[string]int32, len(parsed.Model.Vocab)+16),
		scores: make(map[string]float64, len(parsed.Model.Vocab)),
		maxLen: 512,
	}
	for i, entry := range parsed.Model.Vocab {
		if len(entry) < 2 {
			continue
		}
		tok, _ := entry[0].(string)
		sc, _ := entry[1].(float64)
		t.vocab[tok] = int32(i)
		t.scores[tok] = sc
		if l := len([]rune(tok)); l > t.maxRune {
			t.maxRune = l
		}
	}
	for _, at := range parsed.AddedTokens {
		t.vocab[at.Content] = at.ID
	}
	if id, ok := t.vocab[unkToken]; ok {
		t.unkID = id
	} else {
		t.unkID = int32(parsed.Model.UnkID)
	}
	if id, ok := t.vocab[clsToken]; ok {
		t.clsID = id
	}
	if id, ok := t.vocab[sepToken]; ok {
		t.sepID = id
	} else {
		t.sepID = 2
	}
	if id, ok := t.vocab[padToken]; ok {
		t.padID = id
	} else {
		t.padID = 1
	}
	if t.maxRune > 32 {
		t.maxRune = 32
	}
	return t, nil
}

// Encode converts text into XLM-R / E5 Unigram input_ids and attention_mask, capped at max_length=512.
func (t *Tokenizer) Encode(text string) (inputIDs, attentionMask []int64) {
	normalized := preprocessForSentencePiece(text)
	pieces := t.viterbiEncode(normalized)

	capTokens := t.maxLen - 2
	if len(pieces) > capTokens {
		pieces = pieces[:capTokens]
	}
	n := len(pieces) + 2
	inputIDs = make([]int64, n)
	attentionMask = make([]int64, n)
	inputIDs[0] = int64(t.clsID)
	attentionMask[0] = 1
	for i, id := range pieces {
		inputIDs[i+1] = int64(id)
		attentionMask[i+1] = 1
	}
	inputIDs[n-1] = int64(t.sepID)
	attentionMask[n-1] = 1
	return inputIDs, attentionMask
}

func preprocessForSentencePiece(text string) string {
	nfkc := norm.NFKC.String(text)
	var b strings.Builder
	b.Grow(len(nfkc) + 8)
	prevSpace := true
	for _, r := range nfkc {
		if unicode.IsSpace(r) {
			if !prevSpace {
				b.WriteString("▁")
				prevSpace = true
			}
			continue
		}
		if prevSpace {
			if b.Len() == 0 {
				b.WriteString("▁")
			}
			prevSpace = false
		}
		b.WriteRune(r)
	}
	out := b.String()
	if strings.HasSuffix(out, "▁") && len(out) > len("▁") {
		out = strings.TrimSuffix(out, "▁")
	}
	return out
}

func (t *Tokenizer) viterbiEncode(text string) []int32 {
	runes := []rune(text)
	n := len(runes)
	if n == 0 {
		return nil
	}
	type dpNode struct {
		score float64
		prev  int
		id    int32
	}
	dp := make([]dpNode, n+1)
	for i := 1; i <= n; i++ {
		dp[i].score = math.Inf(-1)
	}

	const unkPenalty = -10.0
	for i := 0; i < n; i++ {
		if math.IsInf(dp[i].score, -1) {
			continue
		}
		// Always allow single rune fallback as UNK if no piece matched.
		maxEnd := min(n, i+t.maxRune)
		matchedSingle := false
		for j := i + 1; j <= maxEnd; j++ {
			sub := string(runes[i:j])
			if id, ok := t.vocab[sub]; ok {
				if j == i+1 {
					matchedSingle = true
				}
				sc := dp[i].score + t.scores[sub]
				if sc > dp[j].score {
					dp[j] = dpNode{score: sc, prev: i, id: id}
				}
			}
		}
		if !matchedSingle {
			sc := dp[i].score + unkPenalty
			if sc > dp[i+1].score {
				dp[i+1] = dpNode{score: sc, prev: i, id: t.unkID}
			}
		}
	}

	var ids []int32
	for pos := n; pos > 0; pos = dp[pos].prev {
		ids = append(ids, dp[pos].id)
	}
	sort.SliceStable(ids, func(i, j int) bool { return false }) // reverse below
	for l, r := 0, len(ids)-1; l < r; l, r = l+1, r-1 {
		ids[l], ids[r] = ids[r], ids[l]
	}
	return ids
}
