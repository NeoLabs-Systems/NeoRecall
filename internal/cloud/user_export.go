package cloud

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

func (s *Service) BuildUserExport(ctx context.Context, userID string) ([]byte, error) {
	var uID, username, createdAt string
	var email sql.NullString
	if err := s.DB.R.QueryRowContext(ctx, `SELECT id, username, email, created_at FROM users WHERE id=?`, userID).
		Scan(&uID, &username, &email, &createdAt); err != nil {
		return nil, fmt.Errorf("user not found: %w", err)
	}
	var st map[string]any
	if s.Settings != nil {
		st, _ = s.Settings.Get(ctx, userID)
	}
	if st == nil {
		st = map[string]any{}
	}

	queryRows := func(q string) []map[string]any {
		rows, err := s.DB.R.QueryContext(ctx, q, userID)
		if err != nil {
			return []map[string]any{}
		}
		defer rows.Close()
		cols, _ := rows.Columns()
		out := []map[string]any{}
		for rows.Next() {
			vals := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range vals {
				ptrs[i] = &vals[i]
			}
			if rows.Scan(ptrs...) == nil {
				m := make(map[string]any, len(cols))
				for i, c := range cols {
					if b, ok := vals[i].([]byte); ok {
						m[c] = string(b)
					} else {
						m[c] = vals[i]
					}
				}
				out = append(out, m)
			}
		}
		return out
	}

	devices := queryRows(`SELECT name, platform, kind, created_at, last_heartbeat_at FROM devices WHERE user_id=? AND revoked_at IS NULL`)
	sessions := queryRows(`SELECT id, client_uuid, device_started_at, device_ended_at, timezone, status, created_at FROM recording_sessions WHERE user_id=?`)
	convs := queryRows(`SELECT id, started_at, ended_at, state, title_en, summary_en, topics_json, created_at FROM conversations WHERE user_id=?`)
	transcripts := queryRows(`SELECT public_id, conversation_id, started_at, ended_at, text, language FROM transcript_segments WHERE user_id=? ORDER BY started_at`)
	mems := queryRows(`SELECT public_id, type, title_en, summary_en, importance, started_at, ended_at, pinned, archived, created_at FROM memories WHERE user_id=?`)
	minis := queryRows(`SELECT public_id, kind, text_en, importance, confidence, created_at FROM mini_memories WHERE user_id=?`)
	daily := queryRows(`SELECT local_date, timezone, summary_en, coverage_started_at, coverage_ended_at, state, created_at FROM daily_summaries WHERE user_id=?`)
	speakers := queryRows(`SELECT id, display_name FROM voiceprints WHERE user_id=?`)
	entities := queryRows(`SELECT kind, canonical_name_en, display_name, created_at FROM entities WHERE user_id=?`)
	ctxItems := queryRows(`SELECT kind, captured_at, note_text, original_name, content_type, extracted_text, analysis_text, created_at FROM recording_context_items WHERE user_id=?`)

	var emailVal any
	if email.Valid {
		emailVal = email.String
	}
	payload := map[string]any{
		"account":        map[string]any{"id": uID, "username": username, "email": emailVal, "createdAt": createdAt},
		"settings":       st,
		"devices":        devices,
		"sessions":       sessions,
		"conversations":  convs,
		"transcripts":    transcripts,
		"memories":       mems,
		"miniMemories":   minis,
		"dailySummaries": daily,
		"speakers":       speakers,
		"entities":       entities,
		"context":        ctxItems,
	}
	manifest := map[string]any{
		"version":    1,
		"kind":       "neorecall-user-backup",
		"exportedAt": timeutil.NowISO(),
		"userId":     uID,
		"username":   username,
		"counts": map[string]int{
			"devices":        len(devices),
			"sessions":       len(sessions),
			"conversations":  len(convs),
			"transcripts":    len(transcripts),
			"memories":       len(mems),
			"miniMemories":   len(minis),
			"dailySummaries": len(daily),
			"speakers":       len(speakers),
			"entities":       len(entities),
			"context":        len(ctxItems),
		},
	}
	mb, _ := json.MarshalIndent(manifest, "", "  ")
	pb, _ := json.Marshal(payload)

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, entry := range []struct {
		name string
		data []byte
	}{
		{"manifest.json", append(mb, '\n')},
		{"data.json", append(pb, '\n')},
	} {
		if f, err := zw.Create(entry.name); err == nil {
			_, _ = f.Write(entry.data)
		}
	}
	_ = zw.Close()
	return buf.Bytes(), nil
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
