package search

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

type AskCitation struct {
	SourceID  string  `json:"sourceId"`
	Kind      string  `json:"kind"`
	Timestamp string  `json:"timestamp"`
	Title     *string `json:"title"`
	Excerpt   string  `json:"excerpt"`
	Relevance float64 `json:"relevance"`
	Link      string  `json:"link"`
}

type AskResponse struct {
	Answer    string         `json:"answer"`
	Citations []AskCitation  `json:"citations"`
	Retrieval map[string]any `json:"retrieval"`
}

type QueryPlan struct {
	SearchQueries []string `json:"searchQueries"`
	FromLocal     *string  `json:"fromLocal"`
	ToLocal       *string  `json:"toLocal"`
	Kinds         []string `json:"kinds"`
	WholePeriod   bool     `json:"wholePeriod"`
}

type AskAI interface {
	PlanQuery(ctx context.Context, userID, question, nowLocal, timezone string) (QueryPlan, error)
	Answer(ctx context.Context, userID, question string, contextItems []map[string]any, beforeAttempt func() error, frame map[string]any) (answerText string, citationIDs []string, err error)
}

type AskService struct {
	Search *Service
	Usage  *usage.Service
	AI     AskAI
}

func (a *AskService) reserveAttempt(ctx context.Context, userID string) error {
	c := a.Search.cfg()
	winMs := c.AskQuotaWindowMs
	if winMs <= 0 {
		winMs = 3_600_000
	}
	tx, err := a.Search.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	cutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now(), -winMs))
	var cnt int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM ask_quota_events WHERE user_id=? AND attempted_at>=?`, userID, cutoff).Scan(&cnt); err != nil {
		return err
	}
	if cnt >= c.AskMaxPerHour {
		var firstAt string
		_ = tx.QueryRowContext(ctx, `SELECT attempted_at FROM ask_quota_events WHERE user_id=? AND attempted_at>=? ORDER BY attempted_at LIMIT 1`, userID, cutoff).Scan(&firstAt)
		retrySec := 60
		if t, err := timeutil.ParseISO(firstAt); err == nil {
			rem := float64(t.UnixMilli()+winMs-time.Now().UnixMilli()) / 1000.0
			retrySec = max(1, int(math.Ceil(rem)))
		}
		return httperr.New(http.StatusTooManyRequests, "ASK_RATE_LIMITED", "The hourly Ask limit has been reached.", map[string]any{"retryAfterSeconds": retrySec})
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO ask_quota_events (user_id) VALUES (?)`, userID); err != nil {
		return err
	}
	return tx.Commit()
}

func (a *AskService) userTimezone(ctx context.Context, userID string) string {
	var raw string
	if err := a.Search.DB.R.QueryRowContext(ctx, `SELECT value_json FROM user_settings WHERE user_id=? AND key='timezone'`, userID).Scan(&raw); err == nil && raw != "" {
		var tz string
		if json.Unmarshal([]byte(raw), &tz) == nil && tz != "" {
			return tz
		}
	}
	return "UTC"
}

func windowFor(plan QueryPlan, timezone string) (fromUTC, toUTC string) {
	if plan.FromLocal == nil && plan.ToLocal == nil {
		return "", ""
	}
	if plan.FromLocal != nil && *plan.FromLocal != "" {
		iso, err := timeutil.LocalDateTimeToUTC(*plan.FromLocal, timezone)
		if err != nil {
			return "", ""
		}
		fromUTC = iso
	}
	if plan.ToLocal != nil && *plan.ToLocal != "" {
		iso, err := timeutil.LocalDateTimeToUTC(*plan.ToLocal, timezone)
		if err != nil {
			return "", ""
		}
		toUTC = iso
	}
	return fromUTC, toUTC
}

func (a *AskService) retrieveLayer(ctx context.Context, userID string, plan QueryPlan, fromUTC, toUTC string, kinds []string, limit int) (SearchResponse, error) {
	if limit <= 0 {
		return SearchResponse{Results: []SearchResult{}}, nil
	}
	c := a.Search.cfg()
	maxQ := max(1, c.AskMaxSearchQueries)
	queries := plan.SearchQueries
	if len(queries) > maxQ {
		queries = queries[:maxQ]
	}
	best := make(map[int64]SearchResult)
	weakCount := 0
	for _, q := range queries {
		found, err := a.Search.Search(ctx, userID, q, SearchOptions{
			Limit:       limit,
			Kinds:       kinds,
			From:        fromUTC,
			To:          toUTC,
			WholeWindow: plan.WholePeriod,
		})
		if err != nil {
			return SearchResponse{}, err
		}
		if found.WeakCount > weakCount {
			weakCount = found.WeakCount
		}
		for _, r := range found.Results {
			if cur, ok := best[r.ID]; !ok || r.Score > cur.Score {
				best[r.ID] = r
			}
		}
	}
	var results []SearchResult
	for _, r := range best {
		results = append(results, r)
	}
	// Sort descending by Score.
	for i := 0; i < len(results); i++ {
		for j := i + 1; j < len(results); j++ {
			if results[j].Score > results[i].Score {
				results[i], results[j] = results[j], results[i]
			}
		}
	}
	if len(results) > limit {
		results = results[:limit]
	}
	return SearchResponse{Results: results, WeakCount: weakCount}, nil
}

func (a *AskService) citationHref(ctx context.Context, userID, kind, sourceID string) string {
	id := sourceID
	if idx := strings.IndexByte(sourceID, ':'); idx >= 0 {
		id = sourceID[idx+1:]
	}
	switch kind {
	case "memory":
		var pub string
		if a.Search.DB.R.QueryRowContext(ctx, `SELECT public_id FROM memories WHERE id=? AND user_id=?`, id, userID).Scan(&pub) == nil {
			return "/memories/" + pub
		}
		return "/memories/" + id
	case "mini_memory":
		var pub string
		if a.Search.DB.R.QueryRowContext(ctx, `SELECT m.public_id FROM mini_memories mm JOIN memories m ON m.id=mm.memory_id WHERE mm.id=? AND mm.user_id=?`, id, userID).Scan(&pub) == nil {
			return "/memories/" + pub
		}
		return "/memories/" + id
	case "daily_summary":
		return "/daily-summaries/" + id
	case "segment":
		var pub string
		if a.Search.DB.R.QueryRowContext(ctx, `SELECT public_id FROM transcript_segments WHERE id=? AND user_id=?`, id, userID).Scan(&pub) == nil {
			return "/timeline?segment=" + pub
		}
		return "/timeline?segment=" + id
	default:
		return "/memories/" + id
	}
}

func (a *AskService) Ask(ctx context.Context, userID, question string) (AskResponse, error) {
	if a.Usage != nil {
		if _, err := a.Usage.RejectIfReached(ctx, userID, "ai"); err != nil {
			return AskResponse{}, err
		}
	}
	if a.AI == nil {
		return AskResponse{}, httperr.New(http.StatusServiceUnavailable, "AI_NOT_CONFIGURED", "AI engine is not configured.")
	}
	tz := a.userTimezone(ctx, userID)
	nowLocal, _ := timeutil.LocalDateTimeNow(tz, time.Now())
	plan, err := a.AI.PlanQuery(ctx, userID, question, nowLocal, tz)
	if err != nil {
		plan = QueryPlan{SearchQueries: []string{question}}
	}
	fromUTC, toUTC := windowFor(plan, tz)
	wholePeriod := plan.WholePeriod && (fromUTC != "" || toUTC != "")
	plan.WholePeriod = wholePeriod

	c := a.Search.cfg()
	total := c.AskMemoryContextLimit + c.AskTranscriptContextLimit
	var retrieved SearchResponse
	if len(plan.Kinds) > 0 {
		chosen, err := a.retrieveLayer(ctx, userID, plan, fromUTC, toUTC, plan.Kinds, total)
		if err != nil {
			return AskResponse{}, err
		}
		if len(chosen.Results) > 0 {
			retrieved = chosen
		} else {
			retrieved, err = a.retrieveLayer(ctx, userID, plan, fromUTC, toUTC, nil, total)
			if err != nil {
				return AskResponse{}, err
			}
		}
	} else {
		written, err := a.retrieveLayer(ctx, userID, plan, fromUTC, toUTC, []string{"memory", "mini_memory", "daily_summary"}, c.AskMemoryContextLimit)
		if err != nil {
			return AskResponse{}, err
		}
		spoken, err := a.retrieveLayer(ctx, userID, plan, fromUTC, toUTC, []string{"segment"}, c.AskTranscriptContextLimit)
		if err != nil {
			return AskResponse{}, err
		}
		retrieved = SearchResponse{
			Results:   append(written.Results, spoken.Results...),
			WeakCount: max(written.WeakCount, spoken.WeakCount),
		}
	}

	contextItems := make([]map[string]any, 0, len(retrieved.Results))
	allowed := make(map[string]SearchResult, len(retrieved.Results))
	for _, r := range retrieved.Results {
		sid := fmt.Sprintf("%s:%s", r.Kind, r.SourceID)
		allowed[sid] = r
		contextItems = append(contextItems, map[string]any{
			"sourceId":  sid,
			"kind":      r.Kind,
			"timestamp": r.OccurredAt,
			"title":     r.Title,
			"text":      r.Body,
		})
	}
	var period any
	if plan.FromLocal != nil || plan.ToLocal != nil {
		period = map[string]any{"fromLocal": plan.FromLocal, "toLocal": plan.ToLocal}
	}
	frame := map[string]any{"nowLocal": nowLocal, "timezone": tz, "period": period}
	if len(retrieved.Results) == 0 {
		latest := a.Search.LatestActivity(ctx, userID, nil)
		if latest != nil {
			frame["archive"] = map[string]any{
				"holdsNothingForThePeriod": true,
				"latestActivityAt":         latest.OccurredAt,
				"latestActivityTitle":      latest.Title,
			}
		} else {
			frame["archive"] = map[string]any{
				"holdsNothingForThePeriod": true,
				"empty":                    true,
			}
		}
	}

	answerText, citationIDs, err := a.AI.Answer(ctx, userID, question, contextItems, func() error {
		return a.reserveAttempt(ctx, userID)
	}, frame)
	if err != nil {
		return AskResponse{}, err
	}
	excerptChars := max(50, c.AskCitationExcerptChars)
	citations := []AskCitation{}
	seenCit := make(map[string]bool)
	for _, sid := range citationIDs {
		if seenCit[sid] {
			continue
		}
		r, ok := allowed[sid]
		if !ok {
			continue
		}
		seenCit[sid] = true
		excerpt := r.Body
		if len([]rune(excerpt)) > excerptChars {
			excerpt = string([]rune(excerpt)[:excerptChars])
		}
		citations = append(citations, AskCitation{
			SourceID:  sid,
			Kind:      r.Kind,
			Timestamp: r.OccurredAt,
			Title:     r.Title,
			Excerpt:   excerpt,
			Relevance: r.Relevance,
			Link:      a.citationHref(ctx, userID, r.Kind, sid),
		})
	}
	return AskResponse{
		Answer:    answerText,
		Citations: citations,
		Retrieval: map[string]any{
			"considered":  len(retrieved.Results),
			"weakCount":   retrieved.WeakCount,
			"period":      period,
			"timezone":    tz,
			"wholePeriod": wholePeriod,
		},
	}, nil
}

type Routes struct {
	Search *Service
	Ask    *AskService
	Auth   *auth.Authenticator
	Log    *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	c := rt.Search.cfg()
	burstLimit := max(1, c.AskBurstPerMinute)
	askLimiter := httperr.NewSlidingLimiter(time.Minute, burstLimit, "ASK_BURST_LIMITED", func(r *http.Request) string {
		if a := auth.FromContext(r.Context()); a.UserID != "" {
			return a.UserID
		}
		return httperr.ClientIP(r, c.TrustProxy)
	})

	searchH := rt.Auth.RequireAuth(rt.Auth.RequireScope("search:read", http.HandlerFunc(rt.handleSearch)))
	mux.Handle("GET /api/v1/search", searchH)
	mux.Handle("GET /api/v1/search/", searchH)

	askH := rt.Auth.RequireAuth(rt.Auth.RequireScope("search:ask", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !askLimiter.Allow(w, r, rt.Log) {
			return
		}
		rt.handleAsk(w, r)
	})))
	mux.Handle("POST /api/v1/search/ask", askH)
}

func (rt *Routes) handleSearch(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "QUERY_REQUIRED", "Search query is required."))
		return
	}
	limit := 20
	if rawLim := strings.TrimSpace(r.URL.Query().Get("limit")); rawLim != "" {
		var n int
		if _, err := fmt.Sscanf(rawLim, "%d", &n); err != nil || n < 1 || n > 100 {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "limit must be between 1 and 100."))
			return
		}
		limit = n
	}
	var kinds []string
	if rawK := strings.TrimSpace(r.URL.Query().Get("kinds")); rawK != "" {
		for _, part := range strings.Split(rawK, ",") {
			p := strings.TrimSpace(part)
			if p == "" {
				continue
			}
			if !AllowedKindsMap[p] {
				httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid document kind: "+p))
				return
			}
			kinds = append(kinds, p)
		}
	}
	res, err := rt.Search.Search(r.Context(), a.UserID, q, SearchOptions{Limit: limit, Kinds: kinds})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleAsk(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Question string `json:"question"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024)).Decode(&body); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_JSON", "Invalid request body."))
		return
	}
	if len(body.Question) == 0 || len(body.Question) > 4000 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "question must be 1–4000 characters."))
		return
	}
	res, err := rt.Ask.Ask(r.Context(), a.UserID, body.Question)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
