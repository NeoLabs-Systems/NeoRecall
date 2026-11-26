package context_test

import (
	"archive/zip"
	"bytes"
	"compress/zlib"
	"context"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	nctx "github.com/NeoLabs-Systems/neorecall/internal/context"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
)

type stubContextAI struct{}

func (s *stubContextAI) Ready(_ context.Context) bool { return true }
func (s *stubContextAI) AnalyzeContextText(_ context.Context, _, name, content string) (string, string, error) {
	return "Analyzed " + name + ": " + content, "req-txt-1", nil
}
func (s *stubContextAI) AnalyzeContextImage(_ context.Context, _, name, mediaType, _ string) (string, string, error) {
	return "Image " + name + " (" + mediaType + ")", "req-img-1", nil
}

func makeMinimalDOCX(t *testing.T, body string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create("word/document.xml")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w.Write([]byte(`<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>` + body + `</w:t></w:r></w:p></w:body></w:document>`))
	_ = zw.Close()
	return buf.Bytes()
}

func makeMinimalPDF(text string) []byte {
	var z bytes.Buffer
	zw := zlib.NewWriter(&z)
	_, _ = zw.Write([]byte("BT\n/F1 12 Tf\n(" + text + ") Tj\nET\n"))
	_ = zw.Close()
	var pdf bytes.Buffer
	pdf.WriteString("%PDF-1.4\n1 0 obj << /Length 100 /Filter /FlateDecode >>\nstream\n")
	pdf.Write(z.Bytes())
	pdf.WriteString("\nendstream\nendobj\n%%EOF\n")
	return pdf.Bytes()
}

func TestExtractSealAnalyzeAndRoutes(t *testing.T) {
	ctx := context.Background()
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
	_ = cfg.Paths.Ensure()

	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}

	// Verify PDF and DOCX extractors directly.
	if got := nctx.ClassifyAndExtract("a.docx", "", makeMinimalDOCX(t, "Quarterly Roadmap"), 1000); got.Kind != "document" || got.Extracted != "Quarterly Roadmap" {
		t.Fatalf("unexpected docx classify: %+v", got)
	}
	if got := nctx.ClassifyAndExtract("b.pdf", "", makeMinimalPDF("Architecture Spec"), 1000); got.Kind != "document" || got.Extracted != "Architecture Spec" {
		t.Fatalf("unexpected pdf classify: %+v", got)
	}

	uid := "00000000-0000-0000-0000-000000000031"
	sessID := "00000000-0000-0000-0000-000000000032"
	devID := "00000000-0000-0000-0000-000000000033"
	_, err = db.W.ExecContext(ctx, `INSERT INTO users (id, username, email, password_hash, role) VALUES (?, 'ctxu', 'c@x.io', 'h', 'user')`, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind) VALUES (?, ?, 'dev-cu', 'Phone', 'ios', 'mobile')`, devID, uid)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.W.ExecContext(ctx, `INSERT INTO recording_sessions (id, user_id, device_id, client_uuid, device_started_at, corrected_started_at, timezone, consent_attested_at, status)
		VALUES (?, ?, ?, 'cu1', '2026-04-01T10:00:00.000Z', '2026-04-01T10:00:00.000Z', 'UTC', '2026-04-01T10:00:00.000Z', 'active')`, sessID, uid, devID)
	if err != nil {
		t.Fatal(err)
	}

	cfgFn := func() config.Config { return cfg }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	changedCalls := 0
	svc := &nctx.Service{
		DB:        db,
		Cfg:       cfgFn,
		MasterKey: keyFn,
		AI:        &stubContextAI{},
		Jobs:      &jobs.Service{DB: db},
		Settings:  &settings.Service{DB: db, Cfg: cfgFn},
		Log:       log,
		OnSessionContextChanged: func(_ context.Context, _, _ string) {
			changedCalls++
		},
	}

	authSvc := &auth.Service{DB: db, Cfg: cfgFn}
	key, err := authSvc.CreateAPIKey(ctx, uid, "ctx-key", []string{"recordings:read", "ingest:write", "memories:read", "memories:write"}, nil)
	if err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	(&nctx.Routes{Svc: svc, Auth: &auth.Authenticator{Service: authSvc, Log: log}, Log: log}).Mount(mux)

	// Multipart PDF upload to session.
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	fw, _ := mw.CreateFormFile("file", "spec.pdf")
	_, _ = fw.Write(makeMinimalPDF("Project Phoenix"))
	_ = mw.Close()

	req := httptest.NewRequest(http.MethodPut, "/api/v1/ingest/sessions/"+sessID+"/context/00000000-0000-0000-0000-000000000034", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+key.Token)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload context failed status=%d body=%s", rec.Code, rec.Body.String())
	}

	items, err := svc.ListForSession(ctx, uid, sessID)
	if err != nil || len(items) != 1 || items[0].AnalysisState != "pending" {
		t.Fatalf("expected 1 pending item, got %+v err=%v", items, err)
	}

	// Verify file on disk is sealed with NRF1 magic header (never plaintext PDF).
	sealedBytes, err := os.ReadFile(home + "/context/" + uid + "/" + items[0].ID + ".bin")
	if err != nil || !bytes.HasPrefix(sealedBytes, []byte("NRF1")) {
		t.Fatalf("expected NRF1 sealed file on disk, err=%v", err)
	}

	// Analyze item synchronously.
	if err := svc.AnalyzeItem(ctx, uid, items[0].ID); err != nil {
		t.Fatal(err)
	}
	if changedCalls != 1 {
		t.Fatalf("expected OnSessionContextChanged called once, got %d", changedCalls)
	}

	// Download original verifies transparent decryption.
	dlReq := httptest.NewRequest(http.MethodGet, "/api/v1/ingest/sessions/"+sessID+"/context/"+items[0].ID+"/original", nil)
	dlReq.Header.Set("Authorization", "Bearer "+key.Token)
	dlRec := httptest.NewRecorder()
	mux.ServeHTTP(dlRec, dlReq)
	if dlRec.Code != http.StatusOK || !bytes.HasPrefix(dlRec.Body.Bytes(), []byte("%PDF-")) {
		t.Fatalf("download failed status=%d len=%d", dlRec.Code, dlRec.Body.Len())
	}
}
