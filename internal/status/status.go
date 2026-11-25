package status

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
)

type Service struct {
	DB                   *dbx.DB
	Cfg                  func() config.Config
	Usage                *usage.Service
	TranscriptionReadyFn func(ctx context.Context) bool
	AIReadyFn            func(ctx context.Context) bool
	Log                  *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func plural(count int, singular, many string) string {
	if count == 1 {
		return fmt.Sprintf("%d %s", count, singular)
	}
	if many != "" {
		return fmt.Sprintf("%d %s", count, many)
	}
	return fmt.Sprintf("%d %ss", count, singular)
}

func (s *Service) ForUser(ctx context.Context, userID string) (map[string]any, error) {
	byState := make(map[string]int)
	rows, err := s.DB.R.QueryContext(ctx, `SELECT state, COUNT(*) FROM audio_chunks WHERE user_id=? GROUP BY state`, userID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var st string
		var cnt int
		if rows.Scan(&st, &cnt) == nil {
			byState[st] = cnt
		}
	}
	rows.Close()

	inFlight := byState["uploaded"] + byState["processing"] + byState["persisted_cleanup_pending"]
	failing := byState["retryable_failed"]
	needsReupload := byState["reupload_required"]
	transcribed := byState["transcribed"] + byState["silent"]

	var unassigned, openConvs, quarantined, memCount int
	var oldestQueued sql.NullString
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL`, userID).Scan(&unassigned)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE user_id=? AND state='open'`, userID).Scan(&openConvs)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM conversations WHERE user_id=? AND quarantined_at IS NOT NULL`, userID).Scan(&quarantined)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM memories WHERE user_id=?`, userID).Scan(&memCount)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT MIN(created_at) FROM jobs WHERE user_id=? AND status='queued'`, userID).Scan(&oldestQueued)

	var lastHB sql.NullString
	_ = s.DB.R.QueryRowContext(ctx, `SELECT MAX(heartbeat_at) FROM worker_heartbeats`).Scan(&lastHB)
	alive := false
	c := s.cfg()
	if lastHB.Valid && lastHB.String != "" {
		if t, err := timeutil.ParseISO(lastHB.String); err == nil {
			alive = time.Since(t).Milliseconds() < c.ProcessingWorkerSilentMs
		}
	}

	trReady := s.TranscriptionReadyFn != nil && s.TranscriptionReadyFn(ctx)
	aiReady := s.AIReadyFn != nil && s.AIReadyFn(ctx)

	issues := []map[string]any{}
	if !trReady {
		issues = append(issues, map[string]any{
			"severity": "blocked", "code": "TRANSCRIPTION_NOT_CONFIGURED",
			"title":  "Recordings are being kept but not turned into text",
			"detail": "Your audio is safe and nothing has been deleted. Transcribing it needs a transcription service, and none is set up yet.",
			"action": "Someone with access to this server needs to finish setting it up. Nothing is being lost while you wait.",
		})
	} else if failing > 0 {
		issues = append(issues, map[string]any{
			"severity": "attention", "code": "TRANSCRIPTION_FAILING",
			"title":  plural(failing, "recording", "") + " could not be transcribed",
			"detail": "Your device is still holding that audio, so none of it is lost.",
			"action": "It keeps trying on its own. If this is still here tomorrow, let whoever runs this server know.",
		})
	}
	if needsReupload > 0 {
		issues = append(issues, map[string]any{
			"severity": "attention", "code": "AUDIO_NEEDS_RESENDING",
			"title":  plural(needsReupload, "recording", "") + " needs sending again",
			"detail": "Your device still has the original, so nothing is lost.",
			"action": "Keep the app open and connected; it sends them again on its own.",
		})
	}
	if !alive {
		issues = append(issues, map[string]any{
			"severity": "blocked", "code": "PROCESSING_STOPPED",
			"title":  "Processing is not running",
			"detail": "Recordings are still being received and kept, but nothing is being worked on. Your audio is safe in the meantime.",
			"action": "Someone with access to this server needs to look at it. Keep recording — nothing is being lost.",
		})
	} else if oldestQueued.Valid && oldestQueued.String != "" {
		if t, err := timeutil.ParseISO(oldestQueued.String); err == nil && time.Since(t).Milliseconds() > c.ProcessingStalledQueueMs {
			issues = append(issues, map[string]any{
				"severity": "attention", "code": "PROCESSING_BEHIND",
				"title":  "Processing is running behind",
				"detail": "Work has been waiting longer than expected. A large backlog or a slow transcription service will do this.",
				"action": "Nothing is lost and it should catch up on its own.",
			})
		}
	}

	if !aiReady {
		issues = append(issues, map[string]any{
			"severity": "blocked", "code": "LANGUAGE_MODEL_NOT_CONFIGURED",
			"title":  "Your recordings are saved, but nothing is being written up",
			"detail": "Transcripts are being kept safely. Turning them into memories needs a language model, and none is set up yet.",
			"action": "Someone with access to this server needs to finish setting it up. Your recordings keep arriving in the meantime.",
		})
	}
	if quarantined > 0 {
		issues = append(issues, map[string]any{
			"severity": "attention", "code": "CONVERSATIONS_SET_ASIDE",
			"title":  plural(quarantined, "conversation", "") + " could not be written up",
			"detail": "They are still recorded and searchable. Repeated attempts to summarise them did not succeed, so they were set aside to let everything else through.",
			"action": "They stay searchable. Someone with access to this server can put them back in the queue.",
		})
	}

	if s.Usage != nil {
		if snap, err := s.Usage.GetUsageSnapshot(ctx, userID, false); err == nil {
			if (snap.Transcription.Reached.FourHour || snap.Transcription.Reached.Weekly) && inFlight > 0 {
				issues = append(issues, map[string]any{
					"severity": "attention", "code": "USAGE_LIMIT_TRANSCRIPTION",
					"title":  "Turning recordings into text is paused for a while",
					"detail": "Your audio is still on this device and on the server. Nothing is being deleted.",
					"action": "Keep recording. Processing resumes on its own.",
				})
			}
			if snap.AI.Reached.FourHour || snap.AI.Reached.Weekly {
				issues = append(issues, map[string]any{
					"severity": "attention", "code": "USAGE_LIMIT_AI",
					"title":  "Writing up and answering questions is paused for a while",
					"detail": "Your recordings and transcripts are still saved.",
					"action": "Nothing is lost. Try again later.",
				})
			}
		}
	}

	summary := "Everything you have recorded has been processed."
	for _, iss := range issues {
		if iss["severity"] == "blocked" {
			summary = iss["title"].(string)
			break
		}
	}
	if summary == "Everything you have recorded has been processed." && len(issues) > 0 {
		summary = issues[0]["title"].(string)
	} else if len(issues) == 0 {
		if inFlight > 0 {
			summary = plural(inFlight, "recording", "") + " still being processed."
		} else if transcribed == 0 {
			summary = "Nothing recorded yet."
		}
	}

	return map[string]any{
		"summary": summary,
		"healthy": len(issues) == 0,
		"issues":  issues,
		"audio": map[string]any{
			"processing":        inFlight,
			"transcribed":       transcribed,
			"needsResending":    needsReupload,
			"failing":           failing,
			"stillOnYourDevice": inFlight + needsReupload + failing,
		},
		"memories": map[string]any{
			"total":     memCount,
			"setAside":  quarantined,
			"waitingOn": nil,
			"retryAt":   nil,
		},
		"conversations": map[string]any{
			"open":             openConvs,
			"awaitingGrouping": unassigned,
		},
		"providers": map[string]any{
			"transcription": trReady,
			"languageModel": aiReady,
		},
		"processingRunning": alive,
	}, nil
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	mux.Handle("GET /api/v1/processing-status", rt.Auth.RequireAuth(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a := auth.FromContext(r.Context())
		res, err := rt.Svc.ForUser(r.Context(), a.UserID)
		if err != nil {
			httperr.WriteError(w, r, rt.Log, err)
			return
		}
		httpx.WriteJSON(w, http.StatusOK, res)
	})))
}
