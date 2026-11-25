package search

import (
	"context"
	"database/sql"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/neorouter"
)

var DocumentKinds = []string{"segment", "memory", "mini_memory", "daily_summary"}

var AllowedKindsMap = map[string]bool{
	"segment":       true,
	"memory":        true,
	"mini_memory":   true,
	"daily_summary": true,
}

func placeholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat("?,", n-1) + "?"
}

// FTSExpression extracts word-like tokens and quotes them for FTS5 MATCH ... OR ...
func FTSExpression(query string, maxTerms int) string {
	if maxTerms <= 0 {
		maxTerms = 16
	}
	var terms []string
	inWord := false
	start := 0
	for i, r := range query {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsMark(r) {
			if !inWord {
				inWord = true
				start = i
			}
		} else if inWord {
			terms = append(terms, query[start:i])
			inWord = false
		}
	}
	if inWord {
		terms = append(terms, query[start:])
	}
	if len(terms) > maxTerms {
		terms = terms[:maxTerms]
	}
	quoted := make([]string, len(terms))
	for i, t := range terms {
		quoted[i] = `"` + strings.ReplaceAll(t, `"`, `""`) + `"`
	}
	return strings.Join(quoted, " OR ")
}

type SearchResult struct {
	ID         int64          `json:"id"`
	UserID     string         `json:"user_id"`
	Kind       string         `json:"kind"`
	SourceID   string         `json:"source_id"`
	Title      *string        `json:"title"`
	Body       string         `json:"body"`
	OccurredAt string         `json:"occurred_at"`
	Importance int            `json:"importance"`
	TextHash   string         `json:"text_hash"`
	Relevance  float64        `json:"relevance"`
	Similarity *float64       `json:"similarity"`
	Score      float64        `json:"score"`
	Branches   map[string]int `json:"branches"`
}

type SearchOptions struct {
	Limit       int
	Kinds       []string
	From        string
	To          string
	WholeWindow bool
}

type SearchResponse struct {
	Results   []SearchResult `json:"results"`
	WeakCount int            `json:"weakCount"`
}

type Service struct {
	DB         *dbx.DB
	Cfg        func() config.Config
	Embeddings *embeddings.Service
	Log        *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) Search(ctx context.Context, userID, query string, opts SearchOptions) (SearchResponse, error) {
	c := s.cfg()
	reqLimit := opts.Limit
	if reqLimit <= 0 {
		reqLimit = 20
	}
	if reqLimit > 100 {
		reqLimit = 100
	}
	candLimit := max(50, reqLimit*4)

	kindClause := ""
	var filterArgs []any
	if len(opts.Kinds) > 0 {
		kindClause = " AND d.kind IN (" + placeholders(len(opts.Kinds)) + ")"
		for _, k := range opts.Kinds {
			filterArgs = append(filterArgs, k)
		}
	}
	winClause := ""
	if opts.From != "" {
		winClause += " AND d.occurred_at>=?"
		filterArgs = append(filterArgs, opts.From)
	}
	if opts.To != "" {
		winClause += " AND d.occurred_at<?"
		filterArgs = append(filterArgs, opts.To)
	}

	var kwIDs []int64
	if expr := FTSExpression(query, c.FTSMaxTerms); expr != "" {
		args := append([]any{expr, userID}, filterArgs...)
		args = append(args, candLimit)
		rows, err := s.DB.R.QueryContext(ctx, `SELECT d.id FROM search_fts
			JOIN search_documents d ON d.id=search_fts.rowid
			WHERE search_fts MATCH ? AND d.user_id=?`+kindClause+winClause+` ORDER BY bm25(search_fts) LIMIT ?`, args...)
		if err != nil {
			return SearchResponse{}, err
		}
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				kwIDs = append(kwIDs, id)
			}
		}
		rows.Close()
	}

	var queryVec []float32
	if s.Embeddings != nil && s.Embeddings.VectorReady() {
		vec, err := s.Embeddings.Embed(ctx, query, "query")
		if err != nil {
			var re *neorouter.RouterError
			if !errors.As(err, &re) {
				return SearchResponse{}, err
			}
			if s.Log != nil {
				s.Log.Warn("Semantic search skipped; NeoRouter embed failed", "code", re.Code, "reason", re.Message)
			}
		} else {
			queryVec = vec
		}
	}

	type semHit struct {
		id  int64
		sim float64
	}
	var semIDs []int64
	simByID := make(map[int64]float64)
	weakCount := 0
	if len(queryVec) > 0 {
		matches, err := s.Embeddings.SearchVector(ctx, userID, opts.Kinds, queryVec, candLimit)
		if err != nil {
			return SearchResponse{}, err
		}
		for _, m := range matches {
			if m.Similarity >= c.SemanticSimilarityFloor {
				semIDs = append(semIDs, m.DocumentID)
				simByID[m.DocumentID] = m.Similarity
			} else {
				weakCount++
			}
		}
	}

	var winIDs []int64
	if opts.WholeWindow && (opts.From != "" || opts.To != "") {
		args := append([]any{userID}, filterArgs...)
		args = append(args, max(1, c.AskTimeWindowLimit))
		rows, err := s.DB.R.QueryContext(ctx, `SELECT d.id FROM search_documents d
			WHERE d.user_id=?`+kindClause+winClause+` ORDER BY d.occurred_at DESC LIMIT ?`, args...)
		if err != nil {
			return SearchResponse{}, err
		}
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil {
				winIDs = append(winIDs, id)
			}
		}
		rows.Close()
	}

	rrfK := max(1, c.RRFK)
	type fusedItem struct {
		id        int64
		relevance float64
		branches  map[string]int
	}
	fused := make(map[int64]*fusedItem)
	addBranch := func(branch string, ids []int64) {
		for idx, id := range ids {
			it, ok := fused[id]
			if !ok {
				it = &fusedItem{id: id, branches: make(map[string]int)}
				fused[id] = it
			}
			it.relevance += 1.0 / float64(rrfK+idx+1)
			it.branches[branch] = idx + 1
		}
	}
	addBranch("keyword", kwIDs)
	addBranch("semantic", semIDs)
	addBranch("window", winIDs)

	branchCount := 1
	if len(queryVec) > 0 {
		branchCount++
	}
	if len(winIDs) > 0 {
		branchCount++
	}
	maxRRF := float64(branchCount) / float64(rrfK+1)

	allIDs := make([]int64, 0, len(fused))
	for id := range fused {
		allIDs = append(allIDs, id)
	}
	docs := make(map[int64]SearchResult, len(allIDs))
	kindSet := make(map[string]bool, len(opts.Kinds))
	for _, k := range opts.Kinds {
		kindSet[k] = true
	}
	for off := 0; off < len(allIDs); off += 400 {
		end := min(len(allIDs), off+400)
		args := []any{userID}
		for _, id := range allIDs[off:end] {
			args = append(args, id)
		}
		rows, err := s.DB.R.QueryContext(ctx, `SELECT id, user_id, kind, source_id, title, body, occurred_at, importance, text_hash
			FROM search_documents WHERE user_id=? AND id IN (`+placeholders(end-off)+`)`, args...)
		if err != nil {
			return SearchResponse{}, err
		}
		for rows.Next() {
			var sr SearchResult
			var title sql.NullString
			if rows.Scan(&sr.ID, &sr.UserID, &sr.Kind, &sr.SourceID, &title, &sr.Body, &sr.OccurredAt, &sr.Importance, &sr.TextHash) == nil {
				if title.Valid {
					v := title.String
					sr.Title = &v
				}
				docs[sr.ID] = sr
			}
		}
		rows.Close()
	}

	now := time.Now().UTC()
	var results []SearchResult
	for id, it := range fused {
		doc, ok := docs[id]
		if !ok {
			continue
		}
		if len(kindSet) > 0 && !kindSet[doc.Kind] {
			continue
		}
		if opts.From != "" && doc.OccurredAt < opts.From {
			continue
		}
		if opts.To != "" && doc.OccurredAt >= opts.To {
			continue
		}
		rel := min(1.0, it.relevance/maxRRF)
		doc.Relevance = rel
		doc.Branches = it.branches
		if sim, ok := simByID[id]; ok {
			v := sim
			doc.Similarity = &v
		}
		doc.Score = Score(rel, doc.OccurredAt, doc.Importance, c.SearchWeights, c.SearchHalfLifeDays, now)
		results = append(results, doc)
	}
	sort.SliceStable(results, func(i, j int) bool {
		return results[i].Score > results[j].Score
	})
	if len(results) > reqLimit {
		results = results[:reqLimit]
	}
	if results == nil {
		results = []SearchResult{}
	}
	return SearchResponse{Results: results, WeakCount: weakCount}, nil
}

type LatestActivityRow struct {
	Kind       string  `json:"kind"`
	Title      *string `json:"title"`
	OccurredAt string  `json:"occurred_at"`
}

func (s *Service) LatestActivity(ctx context.Context, userID string, kinds []string) *LatestActivityRow {
	clause := ""
	args := []any{userID}
	if len(kinds) > 0 {
		clause = " AND kind IN (" + placeholders(len(kinds)) + ")"
		for _, k := range kinds {
			args = append(args, k)
		}
	}
	var out LatestActivityRow
	var t sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT kind, title, occurred_at FROM search_documents
		WHERE user_id=?`+clause+` ORDER BY occurred_at DESC LIMIT 1`, args...).Scan(&out.Kind, &t, &out.OccurredAt)
	if err != nil {
		return nil
	}
	if t.Valid {
		v := t.String
		out.Title = &v
	}
	return &out
}
