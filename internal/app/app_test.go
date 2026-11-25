package app_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NeoLabs-Systems/neorecall/internal/app"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
)

func TestConfiguredProviderCanReachLoopback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[{"id":"local-model"}]}`))
	}))
	defer srv.Close()
	home := t.TempDir()
	cfg, err := config.Load(func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}, home, home)
	if err != nil {
		t.Fatal(err)
	}
	a, err := app.Open(context.Background(), app.Options{StaticConfig: &cfg})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	got, err := a.Providers.DiscoverModels(context.Background(), "llm", "openai_compatible", srv.URL+"/v1", "")
	if err != nil {
		t.Fatalf("local provider: %v", err)
	}
	models := got["models"].([]string)
	if len(models) != 1 || models[0] != "local-model" {
		t.Fatalf("models: %v", models)
	}
	if _, err := a.HTTPClient.Get(srv.URL); err == nil {
		t.Fatal("general HTTP client unexpectedly permits loopback")
	}
}
