package usage

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

const (
	windowFourHour = 4 * time.Hour
	windowWeekly   = 7 * 24 * time.Hour
)

type Service struct {
	DB  *dbx.DB
	Cfg func() config.Config
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

type InstallDefaults struct {
	AITokens4h                 int `json:"aiTokens4h"`
	AITokensWeekly             int `json:"aiTokensWeekly"`
	TranscriptionSeconds4h     int `json:"transcriptionSeconds4h"`
	TranscriptionSecondsWeekly int `json:"transcriptionSecondsWeekly"`
}

type WindowMap struct {
	FourHour *int `json:"fourHour"`
	Weekly   *int `json:"weekly"`
}

type LimitsSnapshot struct {
	FourHour         *int `json:"fourHour"`
	Weekly           *int `json:"weekly"`
	FourHourIsCustom bool `json:"fourHourIsCustom"`
	WeeklyIsCustom   bool `json:"weeklyIsCustom"`
}

type UsageCounts struct {
	FourHour int `json:"fourHour"`
	Weekly   int `json:"weekly"`
}

type ReachedSnapshot struct {
	FourHour bool `json:"fourHour"`
	Weekly   bool `json:"weekly"`
	Any      bool `json:"any"`
}

type NextDecreaseSnapshot struct {
	FourHour *string `json:"fourHour"`
	Weekly   *string `json:"weekly"`
}

type MeterSnapshot struct {
	Limits         LimitsSnapshot       `json:"limits"`
	Usage          UsageCounts          `json:"usage"`
	Remaining      WindowMap            `json:"remaining"`
	Reached        ReachedSnapshot      `json:"reached"`
	NextDecreaseAt NextDecreaseSnapshot `json:"nextDecreaseAt"`
}

type Snapshot struct {
	AI            MeterSnapshot `json:"ai"`
	Transcription MeterSnapshot `json:"transcription"`
}

type LimitExceededError struct {
	HTTP    *httperr.Error
	RetryAt string
}

func (e *LimitExceededError) Error() string { return e.HTTP.Message }
func (e *LimitExceededError) Unwrap() error { return e.HTTP }

func finiteLimit(v int) *int {
	if v > 0 {
		cp := v
		return &cp
	}
	return nil
}

func resolveLimit(custom sql.NullInt64, inherited *int) *int {
	if !custom.Valid {
		return inherited
	}
	if custom.Int64 > 0 {
		v := int(custom.Int64)
		return &v
	}
	return nil
}

func (s *Service) readInstallOverrides(ctx context.Context) map[string]int {
	out := map[string]int{}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT key, value_json FROM app_settings`)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var k, raw string
		if rows.Scan(&k, &raw) != nil {
			continue
		}
		switch k {
		case "aiTokens4h", "aiTokensWeekly", "transcriptionSeconds4h", "transcriptionSecondsWeekly":
			var v int
			if json.Unmarshal([]byte(raw), &v) == nil && v >= 0 {
				out[k] = v
			}
		}
	}
	return out
}

func (s *Service) GetInstallDefaults(ctx context.Context) InstallDefaults {
	c := s.cfg()
	ov := s.readInstallOverrides(ctx)
	pick := func(k string, def int) int {
		if v, ok := ov[k]; ok {
			return v
		}
		return def
	}
	return InstallDefaults{
		AITokens4h:                 pick("aiTokens4h", c.AITokens4h),
		AITokensWeekly:             pick("aiTokensWeekly", c.AITokensWeekly),
		TranscriptionSeconds4h:     pick("transcriptionSeconds4h", c.TranscriptionSeconds4h),
		TranscriptionSecondsWeekly: pick("transcriptionSecondsWeekly", c.TranscriptionSecondsWeekly),
	}
}

func (s *Service) SetInstallDefaults(ctx context.Context, patch map[string]*int) (InstallDefaults, error) {
	allowed := map[string]bool{
		"aiTokens4h": true, "aiTokensWeekly": true,
		"transcriptionSeconds4h": true, "transcriptionSecondsWeekly": true,
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return InstallDefaults{}, err
	}
	defer tx.Rollback()
	for k, v := range patch {
		if !allowed[k] || v == nil {
			continue
		}
		if *v < 0 {
			return InstallDefaults{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", fmt.Sprintf("Usage limit %s must be an integer of 0 or more.", k))
		}
		b, _ := json.Marshal(*v)
		if _, err := tx.ExecContext(ctx, `INSERT INTO app_settings (key, value_json) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`, k, string(b)); err != nil {
			return InstallDefaults{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return InstallDefaults{}, err
	}
	return s.GetInstallDefaults(ctx), nil
}

type usageRow struct {
	Amount    int
	CreatedAt string
}

func (s *Service) usageRows(ctx context.Context, userID, meter string, d time.Duration) ([]usageRow, error) {
	cutoff := timeutil.FormatISO(time.Now().Add(-d))
	q := `SELECT CAST((duration_ms + 999) / 1000 AS INTEGER), created_at FROM transcription_usage WHERE user_id=? AND created_at>? ORDER BY created_at ASC`
	if meter == "ai" {
		q = `SELECT COALESCE(prompt_tokens, 0) + COALESCE(completion_tokens, 0), completed_at FROM ai_requests WHERE user_id=? AND state='succeeded' AND completed_at>? ORDER BY completed_at ASC`
	}
	rows, err := s.DB.R.QueryContext(ctx, q, userID, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []usageRow
	for rows.Next() {
		var r usageRow
		if rows.Scan(&r.Amount, &r.CreatedAt) == nil {
			out = append(out, r)
		}
	}
	return out, rows.Err()
}

func (s *Service) reservedAmount(ctx context.Context, userID, meter string) int {
	now := timeutil.NowISO()
	_, _ = s.DB.W.ExecContext(ctx, `DELETE FROM usage_reservations WHERE expires_at <= ?`, now)
	var tot int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COALESCE(SUM(amount), 0) FROM usage_reservations WHERE user_id=? AND meter=? AND expires_at>?`,
		userID, meter, now).Scan(&tot)
	return tot
}

func nextDecreaseAt(rows []usageRow, d time.Duration, used int, limit *int) *string {
	if limit == nil {
		return nil
	}
	reqExpiry := 1
	if used >= *limit {
		reqExpiry = used - *limit + 1
	}
	toExpire := 0
	for _, r := range rows {
		if r.Amount <= 0 {
			continue
		}
		toExpire += r.Amount
		if toExpire < reqExpiry {
			continue
		}
		if t, err := timeutil.ParseISO(r.CreatedAt); err == nil {
			res := timeutil.FormatISO(t.Add(d))
			return &res
		}
		return nil
	}
	return nil
}

func retryAtForMeter(m MeterSnapshot) string {
	var cands []string
	if m.Reached.FourHour && m.NextDecreaseAt.FourHour != nil {
		cands = append(cands, *m.NextDecreaseAt.FourHour)
	}
	if m.Reached.Weekly && m.NextDecreaseAt.Weekly != nil {
		cands = append(cands, *m.NextDecreaseAt.Weekly)
	}
	if len(cands) == 0 {
		return timeutil.FormatISO(time.Now().Add(time.Minute))
	}
	sort.Strings(cands)
	return cands[0]
}

func (s *Service) meterSnapshot(ctx context.Context, userID, meter string, includeReservations bool) (MeterSnapshot, error) {
	defs := s.GetInstallDefaults(ctx)
	var ai4h, aiW, tr4h, trW sql.NullInt64
	_ = s.DB.R.QueryRowContext(ctx, `SELECT ai_limit_4h, ai_limit_weekly, transcription_limit_4h, transcription_limit_weekly
		FROM users WHERE id=?`, userID).Scan(&ai4h, &aiW, &tr4h, &trW)

	var c4h, cW sql.NullInt64
	var d4h, dW *int
	if meter == "ai" {
		c4h, cW = ai4h, aiW
		d4h, dW = finiteLimit(defs.AITokens4h), finiteLimit(defs.AITokensWeekly)
	} else {
		c4h, cW = tr4h, trW
		d4h, dW = finiteLimit(defs.TranscriptionSeconds4h), finiteLimit(defs.TranscriptionSecondsWeekly)
	}
	lim4 := resolveLimit(c4h, d4h)
	limW := resolveLimit(cW, dW)

	reserved := 0
	if includeReservations {
		reserved = s.reservedAmount(ctx, userID, meter)
	}

	rows4, err := s.usageRows(ctx, userID, meter, windowFourHour)
	if err != nil {
		return MeterSnapshot{}, err
	}
	rowsW, err := s.usageRows(ctx, userID, meter, windowWeekly)
	if err != nil {
		return MeterSnapshot{}, err
	}
	sum := func(rr []usageRow) int {
		tot := reserved
		for _, r := range rr {
			tot += r.Amount
		}
		return tot
	}
	u4, uW := sum(rows4), sum(rowsW)
	rem := func(u int, lim *int) *int {
		if lim == nil {
			return nil
		}
		v := max(0, *lim-u)
		return &v
	}
	r4 := lim4 != nil && u4 >= *lim4
	rW := limW != nil && uW >= *limW
	return MeterSnapshot{
		Limits: LimitsSnapshot{
			FourHour: lim4, Weekly: limW,
			FourHourIsCustom: c4h.Valid, WeeklyIsCustom: cW.Valid,
		},
		Usage:          UsageCounts{FourHour: u4, Weekly: uW},
		Remaining:      WindowMap{FourHour: rem(u4, lim4), Weekly: rem(uW, limW)},
		Reached:        ReachedSnapshot{FourHour: r4, Weekly: rW, Any: r4 || rW},
		NextDecreaseAt: NextDecreaseSnapshot{FourHour: nextDecreaseAt(rows4, windowFourHour, u4, lim4), Weekly: nextDecreaseAt(rowsW, windowWeekly, uW, limW)},
	}, nil
}

func (s *Service) GetUsageSnapshot(ctx context.Context, userID string, includeReservations bool) (Snapshot, error) {
	aiSnap, err := s.meterSnapshot(ctx, userID, "ai", includeReservations)
	if err != nil {
		return Snapshot{}, err
	}
	trSnap, err := s.meterSnapshot(ctx, userID, "transcription", includeReservations)
	if err != nil {
		return Snapshot{}, err
	}
	return Snapshot{AI: aiSnap, Transcription: trSnap}, nil
}

func newLimitExceeded(meter, windowKey string, snap Snapshot) *LimitExceededError {
	ms := snap.Transcription
	noun := "transcription"
	if meter == "ai" {
		ms = snap.AI
		noun = "language-model usage"
	}
	label := "the last 7 days"
	usageVal := ms.Usage.Weekly
	var limitVal int
	if ms.Limits.Weekly != nil {
		limitVal = *ms.Limits.Weekly
	}
	if windowKey == "fourHour" {
		label = "the last 4 hours"
		usageVal = ms.Usage.FourHour
		if ms.Limits.FourHour != nil {
			limitVal = *ms.Limits.FourHour
		}
	}
	msg := fmt.Sprintf("The %s limit for %s has been reached (%d of %d).", noun, label, usageVal, limitVal)
	he := httperr.New(http.StatusTooManyRequests, "USAGE_LIMIT_EXCEEDED", msg, map[string]any{
		"meter": meter, "window": windowKey, "usage": snap,
	})
	return &LimitExceededError{HTTP: he, RetryAt: retryAtForMeter(ms)}
}

// Enforce checks quotas and reserves capacity for an active operation; callers
// must call release() in a defer.
func (s *Service) Enforce(ctx context.Context, userID, meter string, reserveOverride int) (Snapshot, func(), error) {
	if meter != "ai" && meter != "transcription" {
		return Snapshot{}, nil, fmt.Errorf("usage: unknown meter %q", meter)
	}
	snap, err := s.GetUsageSnapshot(ctx, userID, true)
	if err != nil {
		return Snapshot{}, nil, err
	}
	ms := snap.Transcription
	if meter == "ai" {
		ms = snap.AI
	}
	if ms.Reached.FourHour {
		return Snapshot{}, nil, newLimitExceeded(meter, "fourHour", snap)
	}
	if ms.Reached.Weekly {
		return Snapshot{}, nil, newLimitExceeded(meter, "weekly", snap)
	}
	if ms.Limits.FourHour == nil && ms.Limits.Weekly == nil {
		return snap, func() {}, nil
	}
	reserve := reserveOverride
	if reserve <= 0 {
		minLim := 0
		if ms.Limits.FourHour != nil && *ms.Limits.FourHour > 0 {
			minLim = *ms.Limits.FourHour
		}
		if ms.Limits.Weekly != nil && *ms.Limits.Weekly > 0 && (minLim == 0 || *ms.Limits.Weekly < minLim) {
			minLim = *ms.Limits.Weekly
		}
		maxRes := s.cfg().UsageMaxReservationTokens
		if maxRes <= 0 {
			maxRes = 100_000
		}
		if minLim == 0 {
			reserve = 1
		} else {
			reserve = min(maxRes, max(1, minLim/10))
		}
	}
	if ms.Limits.FourHour != nil && ms.Usage.FourHour+reserve > *ms.Limits.FourHour {
		return Snapshot{}, nil, newLimitExceeded(meter, "fourHour", snap)
	}
	if ms.Limits.Weekly != nil && ms.Usage.Weekly+reserve > *ms.Limits.Weekly {
		return Snapshot{}, nil, newLimitExceeded(meter, "weekly", snap)
	}
	ttlMs := s.cfg().UsageReservationTTLMs
	if ttlMs <= 0 {
		ttlMs = 15 * 60_000
	}
	resID := uuid.NewString()
	exp := timeutil.FormatISO(timeutil.AddMillis(time.Now(), ttlMs))
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO usage_reservations (id, user_id, meter, amount, expires_at)
		VALUES (?, ?, ?, ?, ?)`, resID, userID, meter, reserve, exp); err != nil {
		return Snapshot{}, nil, err
	}
	return snap, func() {
		_, _ = s.DB.W.ExecContext(context.Background(), `DELETE FROM usage_reservations WHERE id=?`, resID)
	}, nil
}

func (s *Service) RejectIfReached(ctx context.Context, userID, meter string) (Snapshot, error) {
	snap, err := s.GetUsageSnapshot(ctx, userID, true)
	if err != nil {
		return Snapshot{}, err
	}
	ms := snap.Transcription
	if meter == "ai" {
		ms = snap.AI
	}
	if ms.Reached.FourHour {
		return Snapshot{}, newLimitExceeded(meter, "fourHour", snap)
	}
	if ms.Reached.Weekly {
		return Snapshot{}, newLimitExceeded(meter, "weekly", snap)
	}
	return snap, nil
}

func (s *Service) RecordTranscription(ctx context.Context, userID, chunkID string, durationMs int) error {
	ms := max(1, durationMs)
	_, err := s.DB.W.ExecContext(ctx, `INSERT INTO transcription_usage (id, user_id, chunk_id, duration_ms)
		VALUES (?, ?, ?, ?) ON CONFLICT(chunk_id) DO NOTHING`, uuid.NewString(), userID, chunkID, ms)
	return err
}

func TranscriptionSecondsFor(durationMs int) int {
	return max(1, (max(0, durationMs)+999)/1000)
}

type UserLimitsView struct {
	UserID                   string          `json:"userId"`
	Username                 string          `json:"username"`
	AILimit4h                *int            `json:"aiLimit4h"`
	AILimitWeekly            *int            `json:"aiLimitWeekly"`
	TranscriptionLimit4h     *int            `json:"transcriptionLimit4h"`
	TranscriptionLimitWeekly *int            `json:"transcriptionLimitWeekly"`
	Defaults                 InstallDefaults `json:"defaults"`
	Usage                    Snapshot        `json:"usage"`
}

func (s *Service) GetUserLimits(ctx context.Context, userID string) (UserLimitsView, error) {
	var id, username string
	var a4, aw, t4, tw sql.NullInt64
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, ai_limit_4h, ai_limit_weekly, transcription_limit_4h, transcription_limit_weekly
		FROM users WHERE id=?`, userID).Scan(&id, &username, &a4, &aw, &t4, &tw)
	if errors.Is(err, sql.ErrNoRows) {
		return UserLimitsView{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "User not found.")
	}
	if err != nil {
		return UserLimitsView{}, err
	}
	toPtr := func(n sql.NullInt64) *int {
		if !n.Valid {
			return nil
		}
		v := int(n.Int64)
		return &v
	}
	snap, err := s.GetUsageSnapshot(ctx, userID, false)
	if err != nil {
		return UserLimitsView{}, err
	}
	return UserLimitsView{
		UserID: id, Username: username,
		AILimit4h: toPtr(a4), AILimitWeekly: toPtr(aw),
		TranscriptionLimit4h: toPtr(t4), TranscriptionLimitWeekly: toPtr(tw),
		Defaults: s.GetInstallDefaults(ctx),
		Usage:    snap,
	}, nil
}

type UserLimitsPatch struct {
	AILimit4h                OptionalInt
	AILimitWeekly            OptionalInt
	TranscriptionLimit4h     OptionalInt
	TranscriptionLimitWeekly OptionalInt
}

type OptionalInt struct {
	Set bool
	Val *int
}

func (o *OptionalInt) UnmarshalJSON(data []byte) error {
	o.Set = true
	if string(data) == "null" {
		o.Val = nil
		return nil
	}
	var v int
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	o.Val = &v
	return nil
}

func (s *Service) SetUserLimits(ctx context.Context, userID string, p UserLimitsPatch) (UserLimitsView, error) {
	cur, err := s.GetUserLimits(ctx, userID)
	if err != nil {
		return UserLimitsView{}, err
	}
	pick := func(o OptionalInt, fallback *int, name string) (sql.NullInt64, error) {
		chosen := fallback
		if o.Set {
			chosen = o.Val
		}
		if chosen == nil {
			return sql.NullInt64{}, nil
		}
		if *chosen < 0 {
			return sql.NullInt64{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", name+" must be null, 0 (unlimited), or a positive integer.")
		}
		return sql.NullInt64{Int64: int64(*chosen), Valid: true}, nil
	}
	a4, err := pick(p.AILimit4h, cur.AILimit4h, "aiLimit4h")
	if err != nil {
		return UserLimitsView{}, err
	}
	aw, err := pick(p.AILimitWeekly, cur.AILimitWeekly, "aiLimitWeekly")
	if err != nil {
		return UserLimitsView{}, err
	}
	t4, err := pick(p.TranscriptionLimit4h, cur.TranscriptionLimit4h, "transcriptionLimit4h")
	if err != nil {
		return UserLimitsView{}, err
	}
	tw, err := pick(p.TranscriptionLimitWeekly, cur.TranscriptionLimitWeekly, "transcriptionLimitWeekly")
	if err != nil {
		return UserLimitsView{}, err
	}
	res, err := s.DB.W.ExecContext(ctx, `UPDATE users SET ai_limit_4h=?, ai_limit_weekly=?, transcription_limit_4h=?, transcription_limit_weekly=? WHERE id=?`,
		a4, aw, t4, tw, userID)
	if err != nil {
		return UserLimitsView{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return UserLimitsView{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "User not found.")
	}
	return s.GetUserLimits(ctx, userID)
}
