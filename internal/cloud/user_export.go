package cloud

import (
	"context"
	"io"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/account"
	"github.com/NeoLabs-Systems/neolabs-go/userid"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

// exportTables are the account's rows in a data export, in order, each read
// with the account id as its only argument. Only readable content is
// selected: no secrets, hashes or other accounts' rows.
var exportTables = []struct{ key, query string }{
	{"devices", `SELECT name, platform, kind, created_at, last_heartbeat_at FROM devices WHERE user_id=? AND revoked_at IS NULL`},
	{"sessions", `SELECT id, client_uuid, device_started_at, device_ended_at, timezone, status, created_at FROM recording_sessions WHERE user_id=?`},
	{"conversations", `SELECT id, started_at, ended_at, state, title_en, summary_en, topics_json, created_at FROM conversations WHERE user_id=?`},
	{"transcripts", `SELECT public_id, conversation_id, started_at, ended_at, text, language FROM transcript_segments WHERE user_id=? ORDER BY started_at`},
	{"memories", `SELECT public_id, type, title_en, summary_en, importance, started_at, ended_at, pinned, archived, created_at FROM memories WHERE user_id=?`},
	{"miniMemories", `SELECT public_id, kind, text_en, importance, confidence, created_at FROM mini_memories WHERE user_id=?`},
	{"dailySummaries", `SELECT local_date, timezone, summary_en, coverage_started_at, coverage_ended_at, state, created_at FROM daily_summaries WHERE user_id=?`},
	{"speakers", `SELECT id, display_name FROM voiceprints WHERE user_id=?`},
	{"entities", `SELECT kind, canonical_name_en, display_name, created_at FROM entities WHERE user_id=?`},
	{"context", `SELECT kind, captured_at, note_text, original_name, content_type, extracted_text, analysis_text, created_at FROM recording_context_items WHERE user_id=?`},
}

// Exporter builds an account's data zip: manifest.json with counts, and
// data.json with the account, its settings and its rows.
func (s *Service) Exporter() *account.Exporter {
	text := func(b []byte) any { return string(b) }
	sections := []account.Section{
		{Key: "account", Value: func(ctx context.Context, a account.Account) (any, error) {
			var createdAt string
			if err := s.DB.R.QueryRowContext(ctx, `SELECT created_at FROM users WHERE id=?`, string(a.ID)).Scan(&createdAt); err != nil {
				return nil, err
			}
			var email any
			if a.Email != "" {
				email = a.Email
			}
			return map[string]any{"id": string(a.ID), "username": a.Username, "email": email, "createdAt": createdAt}, nil
		}},
		{Key: "settings", Value: func(ctx context.Context, a account.Account) (any, error) {
			st := map[string]any{}
			if s.Settings != nil {
				got, err := s.Settings.Get(ctx, string(a.ID))
				if err != nil {
					return nil, err
				}
				st = got
			}
			return st, nil
		}},
	}
	for _, t := range exportTables {
		sections = append(sections, account.Section{Key: t.key, Value: func(_ context.Context, a account.Account) (any, error) {
			return account.Rows{DB: s.DB.R, Query: t.query, Args: []any{string(a.ID)}, Blob: text}, nil
		}})
	}
	return &account.Exporter{
		Format: account.Zip,
		Filename: func(a account.Account, now time.Time) string {
			return "neorecall-" + a.Username + "-" + now.UTC().Format("2006-01-02") + ".zip"
		},
		Head: func(ctx context.Context, a account.Account, now time.Time) ([]account.Field, error) {
			counts := make(map[string]int, len(exportTables))
			for _, t := range exportTables {
				var n int
				if err := s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM (`+t.query+`)`, string(a.ID)).Scan(&n); err != nil {
					return nil, err
				}
				counts[t.key] = n
			}
			return []account.Field{
				{Key: "version", Value: 1},
				{Key: "kind", Value: "neorecall-user-backup"},
				{Key: "exportedAt", Value: timeutil.FormatISO(now)},
				{Key: "userId", Value: string(a.ID)},
				{Key: "username", Value: a.Username},
				{Key: "counts", Value: counts},
			}, nil
		},
		Sections: sections,
	}
}

// writeUserExport writes the account's data zip.
func (s *Service) writeUserExport(ctx context.Context, w io.Writer, userID string) error {
	a, err := auth.Directory{DB: s.DB}.Account(ctx, userid.ID(userID))
	if err != nil {
		return err
	}
	return s.Exporter().WriteTo(ctx, w, a, time.Now())
}

func sanitizeKindSlug(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var out strings.Builder
	prevDash := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			out.WriteRune(r)
			prevDash = false
		} else if !prevDash && out.Len() > 0 {
			out.WriteByte('-')
			prevDash = true
		}
	}
	res := strings.Trim(out.String(), "-")
	if res == "" {
		return "audio"
	}
	return res
}
