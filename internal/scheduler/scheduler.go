package scheduler

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
)

type Scheduler struct {
	DB             *dbx.DB
	Cfg            func() config.Config
	Jobs           *jobs.Service
	Insights       *conversations.InsightService
	Consolidations *memories.ConsolidationService
	Backups        *backup.Service
	Cloud          *cloud.Service
	Log            *slog.Logger

	mu     sync.Mutex
	cancel context.CancelFunc
	done   chan struct{}
}

func (s *Scheduler) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Scheduler) Tick(ctx context.Context) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id FROM users WHERE disabled_at IS NULL`)
	if err != nil {
		return
	}
	var userIDs []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			userIDs = append(userIDs, id)
		}
	}
	rows.Close()

	for _, uid := range userIDs {
		var boundaryNeeded int
		_ = s.DB.R.QueryRowContext(ctx, `SELECT CASE WHEN EXISTS (
			SELECT 1 FROM transcript_segments WHERE user_id=? AND conversation_id IS NULL
		) OR EXISTS (
			SELECT 1 FROM conversations WHERE user_id=? AND state='open'
		) THEN 1 ELSE 0 END`, uid, uid).Scan(&boundaryNeeded)
		if boundaryNeeded == 1 && s.Jobs != nil {
			_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
				UserID: uid, ResourceType: "user", ResourceID: uid,
				Type: "detect_boundaries", Priority: 5,
			})
		}
		if s.Insights != nil {
			if _, err := s.Insights.Request(ctx, uid); err != nil && s.Log != nil {
				s.Log.Warn("Preview scheduling failed", "userId", uid, "error", err)
			}
		}
		if s.Consolidations != nil {
			if _, _, err := s.Consolidations.Request(ctx, uid, false); err != nil && s.Log != nil {
				s.Log.Warn("Consolidation scheduling failed", "userId", uid, "error", err)
			}
		}
	}

	bucket := time.Now().UTC().Format("2006-01-02T15")
	if s.Jobs != nil {
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			ResourceType: "maintenance_bucket", ResourceID: bucket, Type: "maintenance", Priority: -10,
		})
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			ResourceType: "maintenance_bucket", ResourceID: "events-" + bucket, Type: "prune_events", Priority: -20,
		})
		_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
			ResourceType: "maintenance_bucket", ResourceID: "audio-" + bucket, Type: "sweep_temp_audio", Priority: 100,
		})

		c := s.cfg()
		if c.BackupEnabled && s.Backups != nil && s.backupDue() {
			_, _ = s.Jobs.Enqueue(ctx, jobs.EnqueueInput{
				ResourceType: "maintenance_bucket", ResourceID: "backup-" + bucket, Type: "backup", Priority: -30,
			})
		}
	}
	if s.Cloud != nil {
		s.Cloud.ScheduleDueBackups(ctx)
		s.Cloud.EnqueuePendingPuts(ctx)
	}
}

func (s *Scheduler) backupDue() bool {
	st, err := s.Backups.Status()
	if err != nil {
		return false
	}
	items, _ := st["items"].([]backup.Artifact)
	if len(items) == 0 {
		return true
	}
	latest, err := time.Parse(time.RFC3339Nano, items[0].CreatedAt)
	if err != nil {
		return false
	}
	return time.Since(latest) >= time.Duration(max(1, s.cfg().BackupIntervalHours))*time.Hour
}

func (s *Scheduler) Start(ctx context.Context) {
	s.mu.Lock()
	if s.cancel != nil {
		s.mu.Unlock()
		return
	}
	cctx, cancel := context.WithCancel(ctx)
	s.cancel = cancel
	done := make(chan struct{})
	s.done = done
	s.mu.Unlock()

	iv := time.Duration(max(5_000, s.cfg().SchedulerIntervalMs)) * time.Millisecond
	go func() {
		defer close(done)
		s.Tick(cctx)
		t := time.NewTicker(iv)
		defer t.Stop()
		for {
			select {
			case <-cctx.Done():
				return
			case <-t.C:
				s.Tick(cctx)
			}
		}
	}()
}

func (s *Scheduler) Stop() {
	s.mu.Lock()
	cancel := s.cancel
	done := s.done
	s.cancel = nil
	s.done = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
		<-done
	}
}
