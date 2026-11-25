package speakers

import (
	"sort"

	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

// ClusterItem holds one session speaker cluster and its sampled per-chunk embeddings.
type ClusterItem struct {
	ID         string
	Embeddings [][]float32
}

// ClusterGroup represents a merged cluster group; ID is the surviving first member ID.
type ClusterGroup struct {
	ID        string
	MemberIDs []string
}

type pairTotals struct {
	sum   float64
	count int
}

func pairKey(a, b string) string {
	if a < b {
		return a + " " + b
	}
	return b + " " + a
}

// CrossSimilarity returns the total sum and pair count across two sets of embeddings.
func CrossSimilarity(left, right [][]float32) (sum float64, count int) {
	for _, a := range left {
		for _, b := range right {
			sum += transcription.Cosine(a, b)
			count++
		}
	}
	return sum, count
}

func similarityOf(pairs map[string]pairTotals, a, b string) (float64, bool) {
	t, ok := pairs[pairKey(a, b)]
	if !ok || t.count == 0 {
		return 0, false
	}
	return t.sum / float64(t.count), true
}

func bestRival(pairs map[string]pairTotals, groups map[string][]string, first, second string) float64 {
	best := -1.0
	for other := range groups {
		if other == first || other == second {
			continue
		}
		for _, side := range [2]string{first, second} {
			if sc, ok := similarityOf(pairs, side, other); ok && sc > best {
				best = sc
			}
		}
	}
	return best
}

// Cluster groups session speaker clusters via average-linkage agglomerative clustering
// subject to cannot-link constraints and ambiguity margin checks.
func Cluster(items []ClusterItem, threshold, margin float64, forbidden func(a, b string) bool) []ClusterGroup {
	if forbidden == nil {
		forbidden = func(_, _ string) bool { return false }
	}
	type normItem struct {
		id         string
		embeddings [][]float32
	}
	var usable []ClusterItem
	var normalized []normItem
	order := make(map[string]int, len(items))
	groups := make(map[string][]string)

	for _, it := range items {
		if len(it.Embeddings) == 0 {
			continue
		}
		order[it.ID] = len(usable)
		usable = append(usable, it)
		groups[it.ID] = []string{it.ID}
		ne := make([][]float32, len(it.Embeddings))
		for i, e := range it.Embeddings {
			ne[i] = transcription.NormalizeVector(e)
		}
		normalized = append(normalized, normItem{id: it.ID, embeddings: ne})
	}

	pairs := make(map[string]pairTotals)
	for i := 0; i < len(normalized); i++ {
		for j := i + 1; j < len(normalized); j++ {
			sum, cnt := CrossSimilarity(normalized[i].embeddings, normalized[j].embeddings)
			if cnt > 0 {
				pairs[pairKey(normalized[i].id, normalized[j].id)] = pairTotals{sum: sum, count: cnt}
			}
		}
	}

	blocked := func(first, second string) bool {
		for _, l := range groups[first] {
			for _, r := range groups[second] {
				if forbidden(l, r) {
					return true
				}
			}
		}
		return false
	}

	groupIDsOrdered := func() []string {
		ids := make([]string, 0, len(groups))
		for id := range groups {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(i, j int) bool { return order[ids[i]] < order[ids[j]] })
		return ids
	}

	for len(groups) > 1 {
		ids := groupIDsOrdered()
		type cand struct {
			score         float64
			first, second string
		}
		var cands []cand
		for i := 0; i < len(ids); i++ {
			for j := i + 1; j < len(ids); j++ {
				sc, ok := similarityOf(pairs, ids[i], ids[j])
				if !ok || sc < threshold || blocked(ids[i], ids[j]) {
					continue
				}
				cands = append(cands, cand{score: sc, first: ids[i], second: ids[j]})
			}
		}
		sort.SliceStable(cands, func(i, j int) bool { return cands[i].score > cands[j].score })
		var chosen *cand
		for i := range cands {
			rival := bestRival(pairs, groups, cands[i].first, cands[i].second)
			if rival >= threshold || cands[i].score-rival >= margin {
				chosen = &cands[i]
				break
			}
		}
		if chosen == nil {
			break
		}
		target, source := chosen.first, chosen.second
		if order[chosen.second] < order[chosen.first] {
			target, source = chosen.second, chosen.first
		}
		groups[target] = append(groups[target], groups[source]...)
		delete(groups, source)
		for other := range groups {
			if other == target {
				continue
			}
			fromSource, okS := pairs[pairKey(source, other)]
			if !okS {
				continue
			}
			fromTarget, okT := pairs[pairKey(target, other)]
			if okT {
				pairs[pairKey(target, other)] = pairTotals{
					sum:   fromTarget.sum + fromSource.sum,
					count: fromTarget.count + fromSource.count,
				}
			} else {
				pairs[pairKey(target, other)] = fromSource
			}
		}
	}

	var result []ClusterGroup
	clustered := make(map[string]bool)
	for _, id := range groupIDsOrdered() {
		members := groups[id]
		result = append(result, ClusterGroup{ID: id, MemberIDs: members})
		for _, m := range members {
			clustered[m] = true
		}
	}
	for _, it := range items {
		if !clustered[it.ID] {
			result = append(result, ClusterGroup{ID: it.ID, MemberIDs: []string{it.ID}})
		}
	}
	return result
}
