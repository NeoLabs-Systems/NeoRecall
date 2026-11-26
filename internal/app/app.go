// Package app constructs NeoRecall's database, domain services, background
// worker/scheduler, and cross-domain wiring.
package app

import (
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/admin"
	"github.com/NeoLabs-Systems/neorecall/internal/ai"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/backup"
	"github.com/NeoLabs-Systems/neorecall/internal/cloud"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/conversations"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/devices"
	"github.com/NeoLabs-Systems/neorecall/internal/diagnostics"
	"github.com/NeoLabs-Systems/neorecall/internal/embeddings"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/httpserver"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/mcp"
	"github.com/NeoLabs-Systems/neorecall/internal/memories"
	"github.com/NeoLabs-Systems/neorecall/internal/neorouter"
	"github.com/NeoLabs-Systems/neorecall/internal/oauth"
	"github.com/NeoLabs-Systems/neorecall/internal/processing"
	"github.com/NeoLabs-Systems/neorecall/internal/providers"
	"github.com/NeoLabs-Systems/neorecall/internal/recordings"
	"github.com/NeoLabs-Systems/neorecall/internal/scheduler"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/search"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/sources"
	"github.com/NeoLabs-Systems/neorecall/internal/speakers"
	"github.com/NeoLabs-Systems/neorecall/internal/status"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
	"github.com/NeoLabs-Systems/neorecall/internal/transcripts"
	"github.com/NeoLabs-Systems/neorecall/internal/updates"
	"github.com/NeoLabs-Systems/neorecall/internal/usage"
	"github.com/NeoLabs-Systems/neorecall/internal/worker"
)

type Options struct {
	ConfigLoader func() (config.Config, error)
	StaticConfig *config.Config
	Getenv       func(string) string
	Logger       *slog.Logger
	HTTPClient   *http.Client
	AppDir       string
	Version      string
}

type App struct {
	mu            sync.RWMutex
	cfg           config.Config
	loader        func() (config.Config, error)
	DB            *dbx.DB
	Log           *slog.Logger
	HTTPClient    *http.Client
	Auth          *auth.Service
	Authenticator *auth.Authenticator
	OAuth         *oauth.Service
	Devices       *devices.Service
	Jobs          *jobs.Service
	Usage         *usage.Service
	Processing    *processing.Service
	Settings      *settings.Service
	Events        *events.Service
	Diagnostics   *diagnostics.Service
	NeoRouter     *neorouter.Service
	Providers     *providers.Service
	AI            *ai.Engine
	LocalAnalyzer *transcription.LocalAnalyzer
	Embeddings    *embeddings.Service
	Speakers      *speakers.Service
	TempAudio     *ingest.TempAudio
	Receipts      *ingest.Receipts
	Ingest        *ingest.Service
	Imports       *ingest.ImportService
	Context       *nctx.Service
	Transcripts   *transcripts.Service
	Recordings    *recordings.Service
	Insights      *conversations.InsightService
	Conversations *conversations.Service
	Memories      *memories.Service
	Consolidation *memories.ConsolidationService
	Search        *search.Service
	Ask           *search.AskService
	Backups       *backup.Service
	Cloud         *cloud.Service
	Updates       *updates.Service
	Admin         *admin.Service
	Status        *status.Service
	MCP           *mcp.Server
	Runner        *worker.Runner
	Scheduler     *scheduler.Scheduler
	Handler       http.Handler
}

func Open(ctx context.Context, opts Options) (*App, error) {
	getenv := opts.Getenv
	if getenv == nil {
		getenv = os.Getenv
	}
	var initial config.Config
	var err error
	if opts.StaticConfig != nil {
		initial = *opts.StaticConfig
	} else if opts.ConfigLoader != nil {
		initial, err = opts.ConfigLoader()
		if err != nil {
			return nil, err
		}
	} else {
		userHome, _ := os.UserHomeDir()
		cwd, _ := os.Getwd()
		initial, err = config.Load(getenv, userHome, cwd)
		if err != nil {
			return nil, err
		}
	}
	if err := initial.Paths.Ensure(); err != nil {
		return nil, err
	}
	db, err := schema.Open(ctx, initial.Paths, initial.AppDir)
	if err != nil {
		return nil, err
	}
	if err := schema.Ensure(ctx, db.W); err != nil {
		_ = db.Close()
		return nil, err
	}

	log := opts.Logger
	if log == nil {
		log = slog.Default()
	}
	httpClient := opts.HTTPClient
	if httpClient == nil {
		httpClient = ssrf.NewClient(ssrf.Options{
			Timeout: 60 * time.Second,
		})
	}
	// Provider endpoints are configured by the operator and may run on a LAN.
	providerHTTP := opts.HTTPClient
	if providerHTTP == nil {
		// Each request carries its own deadline; this only has to outlast them.
		providerTimeout := time.Duration(max(initial.TranscriptionTimeoutMs, initial.AITimeoutMs)) * time.Millisecond
		providerHTTP = ssrf.NewClient(ssrf.Options{AllowPrivate: true, Timeout: providerTimeout})
	}
	version := opts.Version
	if version == "" {
		version = config.Version
	}
	appDir := opts.AppDir
	if appDir == "" {
		appDir = initial.AppDir
	}

	a := &App{
		cfg:        initial,
		loader:     opts.ConfigLoader,
		DB:         db,
		Log:        log,
		HTTPClient: httpClient,
	}
	cfgFn := func() config.Config { return a.Config() }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(a.Config().Paths.SecretKey) }

	a.Jobs = &jobs.Service{DB: db, Cfg: cfgFn}
	a.Usage = &usage.Service{DB: db, Cfg: cfgFn}
	a.Processing = &processing.Service{DB: db, Cfg: cfgFn}
	a.Events = &events.Service{DB: db, Cfg: cfgFn}
	a.Diagnostics = &diagnostics.Service{DB: db, Cfg: cfgFn, Version: version}
	a.Updates = &updates.Service{Cfg: cfgFn, AppDir: appDir, CurrentVersion: version}
	a.Backups = &backup.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn, Log: log}

	a.LocalAnalyzer = &transcription.LocalAnalyzer{
		Cfg:        cfgFn,
		FFmpegPath: transcription.ResolveFFmpegPath(),
		Log:        log,
	}
	a.Settings = &settings.Service{
		DB:                       db,
		Cfg:                      cfgFn,
		SpeakerIdentityAvailable: a.LocalAnalyzer.Available,
		Log:                      log,
	}

	a.NeoRouter = &neorouter.Service{
		DB:        db,
		Cfg:       cfgFn,
		MasterKey: keyFn,
		HTTP:      providerHTTP,
		Log:       log,
	}
	a.Providers = &providers.Service{
		DB:        db,
		Cfg:       cfgFn,
		MasterKey: keyFn,
		NeoRouter: a.NeoRouter,
		HTTP:      providerHTTP,
		Getenv:    getenv,
		ProbePath: filepath.Join(appDir, "test", "fixtures", "de_en_two_speakers.wav"),
		Log:       log,
	}
	a.NeoRouter.Workloads = a.Providers

	aiProv := &ai.ProviderClient{
		DB:        db,
		Cfg:       cfgFn,
		Providers: a.Providers,
		Usage:     a.Usage,
		HTTP:      providerHTTP,
		Log:       log,
	}
	a.AI = &ai.Engine{
		DB:       db,
		Cfg:      cfgFn,
		Provider: aiProv,
	}
	a.Providers.TestLLMFn = a.AI.TestLLM
	a.Providers.TestSpeakerIdentityFn = func() map[string]any {
		c := a.Config()
		if !c.DiarizationEnabled {
			return map[string]any{
				"ok":      true,
				"enabled": false,
				"status":  "disabled",
				"note":    "Local speaker identification is disabled.",
			}
		}
		if a.LocalAnalyzer.Available() {
			return map[string]any{
				"ok":            true,
				"enabled":       true,
				"modelsPresent": true,
				"provider":      "sherpa-onnx",
			}
		}
		return map[string]any{
			"ok":            false,
			"enabled":       true,
			"modelsPresent": false,
			"error":         "Not installed on this platform; transcripts will have no speaker labels. Run `neorecall setup`.",
		}
	}

	a.Embeddings = &embeddings.Service{
		DB:        db,
		Cfg:       cfgFn,
		NeoRouter: a.NeoRouter,
		Jobs:      a.Jobs,
		Log:       log,
	}
	a.NeoRouter.OnReindex = func(cctx context.Context) error {
		_, rerr := a.Embeddings.ReindexAll(cctx)
		return rerr
	}

	a.Auth = auth.NewService(db, cfgFn, keyFn)
	a.Auth.RemoveIndex = embeddings.RemoveForUserTx
	if _, err := a.Auth.ApplyEnvAdminGrants(ctx); err != nil {
		log.Warn("Admin role sync skipped", "error", err)
	}
	a.OAuth = &oauth.Service{
		DB:        db,
		Auth:      a.Auth,
		Cfg:       cfgFn,
		MasterKey: keyFn,
	}
	a.Authenticator = &auth.Authenticator{
		Service: a.Auth,
		OAuth:   a.OAuth.AuthenticateAccessToken,
		Log:     log,
	}

	a.Devices = &devices.Service{DB: db, Cfg: cfgFn, HTTP: httpClient, Log: log}
	a.Speakers = &speakers.Service{
		DB:         db,
		Cfg:        cfgFn,
		MasterKey:  keyFn,
		Proc:       a.Processing,
		Jobs:       a.Jobs,
		FFmpegPath: transcription.ResolveFFmpegPath(),
		Log:        log,
	}
	a.TempAudio = &ingest.TempAudio{DB: db, Cfg: cfgFn, MasterKey: keyFn, Log: log}
	a.Receipts = &ingest.Receipts{DB: db}
	a.Imports = &ingest.ImportService{DB: db, Cfg: cfgFn, MasterKey: keyFn, TempAudio: a.TempAudio}
	a.Ingest = &ingest.Service{
		DB:           db,
		Cfg:          cfgFn,
		MasterKey:    keyFn,
		TempAudio:    a.TempAudio,
		Receipts:     a.Receipts,
		ReconcileImp: func(cctx context.Context) { _, _ = a.Imports.ReconcileProcessing(cctx) },
	}

	a.Context = &nctx.Service{
		DB:        db,
		Cfg:       cfgFn,
		MasterKey: keyFn,
		AI:        a.AI,
		Jobs:      a.Jobs,
		Settings:  a.Settings,
		Usage:     a.Usage,
		Log:       log,
	}
	a.Transcripts = &transcripts.Service{DB: db}
	a.Recordings = &recordings.Service{
		DB:        db,
		MasterKey: keyFn,
		Speakers:  a.Speakers,
		RemoveSearchSources: func(cctx context.Context, tx *sql.Tx, userID string, refs []recordings.SearchSourceRef) error {
			embRefs := make([]embeddings.SearchSourceRef, len(refs))
			for i, r := range refs {
				embRefs[i] = embeddings.SearchSourceRef{Kind: r.Kind, SourceID: r.SourceID}
			}
			_, err := embeddings.RemoveBySourcesTx(cctx, tx, userID, embRefs)
			return err
		},
		Log: log,
	}
	a.Insights = &conversations.InsightService{
		DB:       db,
		Cfg:      cfgFn,
		Context:  a.Context,
		Jobs:     a.Jobs,
		Settings: a.Settings,
		Usage:    a.Usage,
		AI:       a.AI,
		Log:      log,
	}
	a.Context.OnSessionContextChanged = func(cctx context.Context, userID, sessionID string) {
		_ = a.Insights.EnqueueForSession(cctx, userID, sessionID)
	}

	a.Memories = &memories.Service{
		DB:      db,
		Cfg:     cfgFn,
		Context: a.Context,
		Jobs:    a.Jobs,
		AI:      a.AI,
		Log:     log,
	}
	a.Context.OnMemoryRewriteRequested = a.Memories.RewriteWithContext
	a.Consolidation = &memories.ConsolidationService{
		Memories: a.Memories,
		Settings: a.Settings,
		Usage:    a.Usage,
	}
	a.Conversations = &conversations.Service{
		DB:                     db,
		Cfg:                    cfgFn,
		Log:                    log,
		AIReadyFn:              a.AI.Ready,
		OnRequestConsolidation: a.Consolidation.Request,
	}

	a.Search = &search.Service{DB: db, Cfg: cfgFn, Embeddings: a.Embeddings, Log: log}
	a.Ask = &search.AskService{Search: a.Search, Usage: a.Usage, AI: a.AI}
	a.Cloud = &cloud.Service{
		DB:        db,
		Cfg:       cfgFn,
		MasterKey: keyFn,
		Jobs:      a.Jobs,
		Settings:  a.Settings,
		// Nil outside tests: cloud then uses its own client, which reaches LAN servers.
		HTTP: opts.HTTPClient,
		Log:  log,
	}
	a.Ingest.FinalizeSess = a.Cloud.FinalizeSession

	a.Admin = &admin.Service{
		DB:         db,
		Cfg:        cfgFn,
		Jobs:       a.Jobs,
		Embeddings: a.Embeddings,
		Speakers:   a.Speakers,
		Usage:      a.Usage,
		Backups:    a.Backups,
		Updates:    a.Updates,
		Version:    version,
		Log:        log,
	}
	a.Status = &status.Service{
		DB:    db,
		Cfg:   cfgFn,
		Usage: a.Usage,
		TranscriptionReadyFn: func(cctx context.Context) bool {
			p, perr := a.Providers.TranscriptionProvider(cctx)
			return perr == nil && p != nil && p.Ready()
		},
		AIReadyFn: a.AI.Ready,
		Log:       log,
	}
	a.MCP = &mcp.Server{
		Auth:          a.Authenticator,
		Search:        a.Search,
		Memories:      a.Memories,
		Conversations: a.Conversations,
		Log:           log,
		Version:       version,
	}

	a.Runner = &worker.Runner{
		DB:             db,
		Cfg:            cfgFn,
		MasterKey:      keyFn,
		Jobs:           a.Jobs,
		Providers:      a.Providers,
		Proc:           a.Processing,
		Settings:       a.Settings,
		Usage:          a.Usage,
		Speakers:       a.Speakers,
		Embeddings:     a.Embeddings,
		Context:        a.Context,
		Insights:       a.Insights,
		Memories:       a.Memories,
		Consolidations: a.Consolidation,
		Imports:        a.Imports,
		TempAudio:      a.TempAudio,
		Backups:        a.Backups,
		Cloud:          a.Cloud,
		LocalAnalyzer:  a.LocalAnalyzer,
		Log:            log,
	}
	a.Scheduler = &scheduler.Scheduler{
		DB:             db,
		Cfg:            cfgFn,
		Jobs:           a.Jobs,
		Insights:       a.Insights,
		Consolidations: a.Consolidation,
		Backups:        a.Backups,
		Cloud:          a.Cloud,
		Log:            log,
	}

	authRoutes := auth.NewRoutes(a.Auth, a.Authenticator, log)
	authRoutes.UsageFn = func(cctx context.Context, uid string) (any, error) { return a.Usage.GetUsageSnapshot(cctx, uid, true) }
	authRoutes.ExportFn = a.Cloud.BuildUserExport
	authRoutes.UnlinkFn = ingest.UnlinkStrict

	a.Handler = httpserver.New(httpserver.Deps{
		Config:   cfgFn,
		DB:       db,
		Log:      log,
		Version:  version,
		Getenv:   getenv,
		Auth:     a.Authenticator,
		Diag:     a.Diagnostics,
		AIReady:  a.AI.Ready,
		STTReady: a.Status.TranscriptionReadyFn,
		VecReady: a.Embeddings.VectorReady,
		Routes: []httpserver.Mountable{
			authRoutes,
			oauth.NewRoutes(a.OAuth, a.Authenticator, log),
			&devices.Routes{Svc: a.Devices, Auth: a.Authenticator, Log: log},
			&ingest.Routes{Svc: a.Ingest, Imp: a.Imports, Auth: a.Authenticator, Log: log},
			&nctx.Routes{Svc: a.Context, Auth: a.Authenticator, Log: log},
			&recordings.Routes{Svc: a.Recordings, Auth: a.Authenticator, Log: log},
			&transcripts.Routes{Svc: a.Transcripts, Auth: a.Authenticator, Log: log},
			&conversations.Routes{Svc: a.Conversations, Auth: a.Authenticator, Log: log},
			&speakers.Routes{Svc: a.Speakers, Auth: a.Authenticator, Log: log},
			&memories.Routes{Svc: a.Memories, Consolidations: a.Consolidation, Auth: a.Authenticator, Log: log},
			&search.Routes{Search: a.Search, Ask: a.Ask, Auth: a.Authenticator, Log: log},
			&settings.Routes{Svc: a.Settings, AuthSvc: a.Auth, Auth: a.Authenticator, Log: log},
			&events.Routes{Svc: a.Events, Auth: a.Authenticator},
			&diagnostics.Routes{Svc: a.Diagnostics, Auth: a.Authenticator, Log: log},
			&status.Routes{Svc: a.Status, Auth: a.Authenticator, Log: log},
			&sources.Routes{DB: db, Auth: a.Authenticator, Log: log},
			&cloud.Routes{Svc: a.Cloud, Auth: a.Authenticator, Log: log},
			&admin.Routes{Svc: a.Admin, Auth: a.Authenticator, Log: log},
			&providers.Routes{Svc: a.Providers, Auth: a.Authenticator, Log: log},
			&processing.Routes{Svc: a.Processing, DB: db, Auth: a.Authenticator, Log: log},
			&neorouter.Routes{Svc: a.NeoRouter, Auth: a.Authenticator, Log: log},
			a.MCP,
		},
	})
	return a, nil
}

func (a *App) Config() config.Config {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.cfg
}

func (a *App) ReloadConfig() error {
	if a.loader == nil {
		return nil
	}
	next, err := a.loader()
	if err != nil {
		return err
	}
	a.mu.Lock()
	a.cfg = next
	a.mu.Unlock()
	return nil
}

func (a *App) Close() error {
	if a.Scheduler != nil {
		a.Scheduler.Stop()
	}
	if a.LocalAnalyzer != nil {
		a.LocalAnalyzer.Close()
	}
	if a.Embeddings != nil {
		a.Embeddings.Close()
	}
	if a.DB != nil {
		return a.DB.Close()
	}
	return nil
}
