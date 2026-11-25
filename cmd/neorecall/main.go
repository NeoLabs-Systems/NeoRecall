// Command neorecall runs the NeoRecall backend server (`neorecall serve`)
// and manages the local installation (`neorecall help`).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/runtimecfg"
	"github.com/NeoLabs-Systems/neorecall/internal/app"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httpserver"
	"github.com/NeoLabs-Systems/neorecall/internal/manager"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && (args[0] == "serve" || (args[0] == "start" && len(args) > 1 && args[1] == "--foreground")) {
		log := slog.New(slog.NewTextHandler(os.Stderr, nil))
		if err := serve(log); err != nil {
			log.Error("neorecall stopped", "error", err)
			os.Exit(1)
		}
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if len(args) > 0 && args[0] == "healthcheck" {
		if err := manager.Healthcheck(ctx, os.Getenv); err != nil {
			os.Exit(1)
		}
		return
	}
	if err := manager.Run(ctx, args, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err)
		os.Exit(1)
	}
}

func loadConfig() (config.Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return config.Config{}, fmt.Errorf("find home directory: %w", err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return config.Config{}, err
	}
	prelim := config.ResolvePaths(os.Getenv, home)
	if err := runtimecfg.LoadEnvFile(prelim.EnvFile, os.LookupEnv, os.Setenv); err != nil {
		return config.Config{}, fmt.Errorf("load %s: %w", prelim.EnvFile, err)
	}
	return config.Load(os.Getenv, home, cwd)
}

func serve(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	a, err := app.Open(ctx, app.Options{
		ConfigLoader: loadConfig,
		Getenv:       os.Getenv,
		Logger:       log,
		Version:      config.Version,
	})
	if err != nil {
		return err
	}
	defer a.Close()

	cfg := a.Config()
	if cfg.Paths.PIDFile != "" {
		_ = os.WriteFile(cfg.Paths.PIDFile, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o600)
		defer os.Remove(cfg.Paths.PIDFile)
	}

	// Watch SIGHUP for live config reload.
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	defer signal.Stop(hup)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-hup:
				if rerr := a.ReloadConfig(); rerr != nil {
					log.Warn("SIGHUP config reload failed", "error", rerr)
				} else {
					log.Info("Reloaded configuration on SIGHUP")
				}
			}
		}
	}()

	role := strings.ToLower(strings.TrimSpace(cfg.Role))
	switch role {
	case "", "combined", "all", "http", "worker":
	default:
		return fmt.Errorf("unknown NEORECALL_ROLE: %s", cfg.Role)
	}

	var wg sync.WaitGroup
	runWorker := role == "" || role == "combined" || role == "all" || role == "worker"
	runHTTP := role == "" || role == "combined" || role == "all" || role == "http"

	if runWorker {
		wg.Add(1)
		go func() {
			defer wg.Done()
			a.Runner.Start(ctx)
		}()
	}

	var srv *http.Server
	var stopSampler func()
	errc := make(chan error, 1)
	if runHTTP {
		a.Scheduler.Start(ctx)
		stopSampler = httpserver.StartStatusSampler(ctx, httpserver.Deps{
			Config:   func() config.Config { return a.Config() },
			DB:       a.DB,
			Log:      log,
			AIReady:  a.AI.Ready,
			STTReady: a.Status.TranscriptionReadyFn,
			VecReady: a.Embeddings.VectorReady,
		})

		addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
		if cfg.Host == "" {
			addr = ":" + strconv.Itoa(cfg.Port)
		}
		srv = httpserver.NewHTTPServer(addr, a.Handler, log)
		go func() {
			url := cfg.PublicURL
			if url == "" {
				host := cfg.Host
				if host == "" || host == "0.0.0.0" {
					host = "127.0.0.1"
				}
				url = fmt.Sprintf("http://%s:%d", host, cfg.Port)
			}
			log.Info("NeoRecall listening",
				"url", url,
				"role", role,
				"version", config.Version,
				"ffmpeg", transcription.ResolveFFmpegPath() != "",
				"models", a.LocalAnalyzer.ModelsPresent(),
			)
			errc <- srv.ListenAndServe()
		}()
	}

	if !runHTTP {
		log.Info("NeoRecall worker running", "version", config.Version)
		<-ctx.Done()
		wg.Wait()
		return nil
	}

	select {
	case err := <-errc:
		stop()
		if stopSampler != nil {
			stopSampler()
		}
		wg.Wait()
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		if stopSampler != nil {
			stopSampler()
		}
		shutCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		_ = srv.Shutdown(shutCtx)
		cancel()
		wg.Wait()
	}
	return nil
}
