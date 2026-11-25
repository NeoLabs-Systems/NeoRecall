package ingest_test

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/devices"
	"github.com/NeoLabs-Systems/neorecall/internal/events"
	"github.com/NeoLabs-Systems/neorecall/internal/ingest"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/schema"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

type testStack struct {
	mux     *http.ServeMux
	db      *dbx.DB
	cfg     *config.Config
	keyFn   func() ([]byte, error)
	authSvc *auth.Service
	devSvc  *devices.Service
	evSvc   *events.Service
	jobSvc  *jobs.Service
	ingSvc  *ingest.Service
}

func newTestStack(t *testing.T, maxUploadBytes int64) *testStack {
	t.Helper()
	ctx := context.Background()
	home := t.TempDir()
	env := func(k string) string {
		if k == "NEORECALL_HOME" {
			return home
		}
		return ""
	}
	cfg, err := config.Load(env, home, home)
	if err != nil {
		t.Fatal(err)
	}
	if maxUploadBytes > 0 {
		cfg.MaxUploadBytes = maxUploadBytes
	}
	cfg.ChunkMinMs = 100
	cfg.EventOutboxKeepaliveMs = 50
	if err := cfg.Paths.Ensure(); err != nil {
		t.Fatal(err)
	}
	db, err := dbx.Open(ctx, cfg.Paths.Database, dbx.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if err := schema.Ensure(ctx, db.W); err != nil {
		t.Fatal(err)
	}
	cfgFn := func() config.Config { return cfg }
	keyFn := func() ([]byte, error) { return crypto.MasterKey(cfg.Paths.SecretKey) }
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	authSvc := &auth.Service{DB: db, Cfg: cfgFn, MasterKey: keyFn}
	authn := &auth.Authenticator{Service: authSvc, Log: log}
	devSvc := &devices.Service{DB: db, Cfg: cfgFn, Log: log}
	evSvc := &events.Service{DB: db, Cfg: cfgFn}
	jobSvc := &jobs.Service{DB: db, Cfg: cfgFn}
	ta := &ingest.TempAudio{DB: db, Cfg: cfgFn, MasterKey: keyFn, Log: log}
	rec := &ingest.Receipts{DB: db}
	ingSvc := &ingest.Service{
		DB: db, Cfg: cfgFn, MasterKey: keyFn, TempAudio: ta, Receipts: rec,
	}
	impSvc := &ingest.ImportService{DB: db, Cfg: cfgFn, TempAudio: ta}

	mux := http.NewServeMux()
	auth.NewRoutes(authSvc, authn, log).Mount(mux)
	(&devices.Routes{Svc: devSvc, Auth: authn, Log: log}).Mount(mux)
	(&events.Routes{Svc: evSvc, Auth: authn}).Mount(mux)
	(&ingest.Routes{Svc: ingSvc, Imp: impSvc, Auth: authn, Log: log}).Mount(mux)

	return &testStack{
		mux: mux, db: db, cfg: &cfg, keyFn: keyFn,
		authSvc: authSvc, devSvc: devSvc, evSvc: evSvc, jobSvc: jobSvc, ingSvc: ingSvc,
	}
}

func registerUserAndDevice(t *testing.T, baseURL string) (token, userID, deviceID string) {
	t.Helper()
	res, err := http.Post(baseURL+"/api/v1/auth/register", "application/json",
		strings.NewReader(`{"username":"ingester","email":"ing@example.com","password":"very-long-password-123"}`))
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("register failed: %v %v", err, res)
	}
	var reg struct {
		User    auth.User         `json:"user"`
		Session auth.SessionToken `json:"session"`
	}
	_ = json.NewDecoder(res.Body).Decode(&reg)
	res.Body.Close()

	req, _ := http.NewRequest("POST", baseURL+"/api/v1/devices",
		strings.NewReader(`{"clientUuid":"dev-client-123456","name":"Laptop","platform":"macos","kind":"desktop"}`))
	req.Header.Set("Authorization", "Bearer "+reg.Session.Token)
	req.Header.Set("Content-Type", "application/json")
	res, err = http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("device register failed: %v %v", err, res)
	}
	var dev devices.Device
	_ = json.NewDecoder(res.Body).Decode(&dev)
	res.Body.Close()
	return reg.Session.Token, reg.User.ID, dev.ID
}

func createSession(t *testing.T, baseURL, token, deviceID string) (sessID, srcID string) {
	t.Helper()
	body := `{"deviceId":"` + deviceID + `","clientUuid":"sess-client-123456","startedAt":"2026-01-01T10:00:00Z","timezone":"UTC","consentAttestedAt":"2026-01-01T10:00:00Z","sources":[{"clientUuid":"src-client-123456","kind":"microphone","channelLayout":"mono","sampleRate":16000,"sampleFormat":"pcm_s16le"}]}`
	req, _ := http.NewRequest("POST", baseURL+"/api/v1/ingest/sessions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil || res.StatusCode != 201 {
		t.Fatalf("create session failed: %v %v", err, res)
	}
	var out struct {
		Session ingest.SessionRow  `json:"session"`
		Sources []ingest.SourceRow `json:"sources"`
	}
	_ = json.NewDecoder(res.Body).Decode(&out)
	res.Body.Close()
	if len(out.Sources) != 1 {
		t.Fatalf("expected 1 source, got %d", len(out.Sources))
	}
	return out.Session.ID, out.Sources[0].ID
}

func uploadChunk(t *testing.T, baseURL, token, sessID, srcID string, seq int, idemp, shaHex string, payload []byte, contentEncoding string) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, _ := mw.CreateFormFile("audio", "chunk.wav")
	_, _ = fw.Write(payload)
	mw.Close()

	url := baseURL + "/api/v1/ingest/sessions/" + sessID + "/sources/" + srcID + "/chunks/" + string(rune('0'+seq))
	if seq >= 10 {
		t.Fatal("seq >= 10 helper unsupported")
	}
	req, _ := http.NewRequest("PUT", url, &buf)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Idempotency-Key", idemp)
	req.Header.Set("X-Chunk-Sha256", shaHex)
	req.Header.Set("X-Audio-Container", "wav")
	req.Header.Set("X-Audio-Codec", "pcm_s16le")
	req.Header.Set("X-Chunk-Duration-Ms", "5000")
	req.Header.Set("X-Chunk-Overlap-Ms", "0")
	req.Header.Set("X-Monotonic-Offset-Ms", "0")
	req.Header.Set("X-Device-Started-At", "2026-01-01T10:00:00Z")
	req.Header.Set("X-Channel-Layout", "mono")
	if contentEncoding != "" {
		req.Header.Set("X-Audio-Content-Encoding", contentEncoding)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func sha256HexBytes(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func TestIngestChunkIdempotencyHashGzipAndTerminalInvariant(t *testing.T) {
	st := newTestStack(t, 4096)
	srv := httptest.NewServer(st.mux)
	defer srv.Close()

	token, userID, devID := registerUserAndDevice(t, srv.URL)
	sessID, srcID := createSession(t, srv.URL, token, devID)

	rawAudio := bytes.Repeat([]byte("AB"), 512) // 1024 bytes
	rawHash := sha256HexBytes(rawAudio)

	// 1. Wrong hash rejected with 422 HASH_MISMATCH.
	wrongHash := strings.Repeat("0", 64)
	status, errBody := uploadChunk(t, srv.URL, token, sessID, srcID, 0, "idemp-0000-wrong", wrongHash, rawAudio, "identity")
	if status != 422 {
		t.Fatalf("expected 422 for hash mismatch, got %d (%v)", status, errBody)
	}

	// 2. First upload succeeds with 202 and seals temporary file on disk with NRF1.
	status, out := uploadChunk(t, srv.URL, token, sessID, srcID, 0, "idemp-0000-valid", rawHash, rawAudio, "identity")
	if status != 202 {
		t.Fatalf("expected 202 for new chunk, got %d (%v)", status, out)
	}
	recMap := out["receipt"].(map[string]any)
	chunkID := recMap["chunkId"].(string)
	if recMap["state"] != "uploaded" {
		t.Fatalf("expected uploaded state, got %v", recMap["state"])
	}

	var tmpPath string
	if err := st.db.R.QueryRow(`SELECT temporary_path FROM audio_chunks WHERE id=?`, chunkID).Scan(&tmpPath); err != nil {
		t.Fatal(err)
	}
	key, err := st.keyFn()
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := crypto.ReadSealedFile(key, tmpPath)
	if err != nil {
		t.Fatalf("expected NRF1 sealed file at %s: %v", tmpPath, err)
	}
	if !bytes.Equal(recovered, rawAudio) {
		t.Fatalf("sealed audio plaintext mismatch")
	}

	// 3. Replay identical chunk & idempotency key -> 200 duplicate receipt.
	status, dupOut := uploadChunk(t, srv.URL, token, sessID, srcID, 0, "idemp-0000-valid", rawHash, rawAudio, "identity")
	if status != 200 {
		t.Fatalf("expected 200 for idempotent replay, got %d (%v)", status, dupOut)
	}

	// 4. Replay same sequence with different content -> 409 IDEMPOTENCY_CONFLICT.
	other := bytes.Repeat([]byte("CD"), 512)
	status, conflictOut := uploadChunk(t, srv.URL, token, sessID, srcID, 0, "idemp-0000-valid", sha256HexBytes(other), other, "identity")
	if status != 409 {
		t.Fatalf("expected 409 for idempotency conflict, got %d (%v)", status, conflictOut)
	}

	// 5. Valid gzip upload restores and verifies hash over decompressed bytes.
	gzPayloadRaw := bytes.Repeat([]byte("GZ"), 600) // 1200 bytes <= 4096
	var gzBuf bytes.Buffer
	zw := gzip.NewWriter(&gzBuf)
	_, _ = zw.Write(gzPayloadRaw)
	_ = zw.Close()
	status, gzOut := uploadChunk(t, srv.URL, token, sessID, srcID, 1, "idemp-0001-gzip", sha256HexBytes(gzPayloadRaw), gzBuf.Bytes(), "gzip")
	if status != 202 {
		t.Fatalf("expected 202 for valid gzip upload, got %d (%v)", status, gzOut)
	}

	// 6. Gzip bomb exceeding MaxUploadBytes rejected with 413 AUDIO_TOO_LARGE.
	bombRaw := bytes.Repeat([]byte{0x41}, 5000) // > 4096
	var bombBuf bytes.Buffer
	bw := gzip.NewWriter(&bombBuf)
	_, _ = bw.Write(bombRaw)
	_ = bw.Close()
	status, bombOut := uploadChunk(t, srv.URL, token, sessID, srcID, 2, "idemp-0002-bomb", sha256HexBytes(bombRaw), bombBuf.Bytes(), "gzip")
	if status != 413 {
		t.Fatalf("expected 413 AUDIO_TOO_LARGE for gzip bomb, got %d (%v)", status, bombOut)
	}

	// 7. CompleteTerminalTx invariant checks.
	ctx := context.Background()
	failComplete := func(desc string) {
		t.Helper()
		tx, err := st.db.W.BeginTx(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		_, cerr := ingest.CompleteTerminalTx(ctx, tx, chunkID, "transcribed", "")
		_ = tx.Rollback()
		if cerr == nil {
			t.Fatalf("expected CompleteTerminalTx error for %s, got nil", desc)
		}
	}
	failComplete("uploaded state with temp path")

	now := timeutil.NowISO()
	if _, err := st.db.W.Exec(`UPDATE audio_chunks SET state='persisted_cleanup_pending', persisted_at=? WHERE id=?`, now, chunkID); err != nil {
		t.Fatal(err)
	}
	failComplete("persisted_cleanup_pending while temporary_path still set")

	_ = ingest.UnlinkStrict(tmpPath)
	if _, err := st.db.W.Exec(`UPDATE audio_chunks SET temporary_path=NULL WHERE id=?`, chunkID); err != nil {
		t.Fatal(err)
	}
	tx, err := st.db.W.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	termRec, err := ingest.CompleteTerminalTx(ctx, tx, chunkID, "transcribed", "")
	if err != nil {
		_ = tx.Rollback()
		t.Fatalf("CompleteTerminalTx failed after persist+unlink: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if termRec.State != "transcribed" || termRec.ServerAudioDeletedAt == nil {
		t.Fatalf("unexpected terminal receipt: %+v", termRec)
	}
	_ = userID
}

func TestJobsClaimNextSequenceOrderingAndSSEOutbox(t *testing.T) {
	st := newTestStack(t, 0)
	srv := httptest.NewServer(st.mux)
	defer srv.Close()

	token, userID, devID := registerUserAndDevice(t, srv.URL)
	sessID, srcID := createSession(t, srv.URL, token, devID)
	ctx := context.Background()

	// Insert chunk 0 (uploaded), chunk 1 (uploaded), chunk 3 (uploaded) with a gap covering seq 2.
	insertChunk := func(id string, seq int) {
		t.Helper()
		if _, err := st.db.W.Exec(`INSERT INTO audio_chunks
			(id, user_id, session_id, source_id, sequence, idempotency_key, sha256, byte_size, container, codec, channel_layout, device_started_at, duration_ms, overlap_ms, monotonic_offset_ms, state)
			VALUES (?, ?, ?, ?, ?, ?, ?, 100, 'wav', 'pcm_s16le', 'mono', '2026-01-01T10:00:00Z', 1000, 0, 0, 'uploaded')`,
			id, userID, sessID, srcID, seq, "k-"+id, strings.Repeat("a", 64)); err != nil {
			t.Fatal(err)
		}
	}
	c0, c1, c3 := uuid.NewString(), uuid.NewString(), uuid.NewString()
	insertChunk(c0, 0)
	insertChunk(c1, 1)
	insertChunk(c3, 3)

	// Enqueue seq 3 first, then seq 1, then seq 0 (no gap covering seq 2 yet).
	for _, cid := range []string{c3, c1, c0} {
		if _, err := st.jobSvc.Enqueue(ctx, jobs.EnqueueInput{
			UserID: userID, ResourceType: "audio_chunk", ResourceID: cid, Type: "transcribe_chunk",
		}); err != nil {
			t.Fatal(err)
		}
	}

	// ClaimNext with canTranscribe=false skips transcribe_chunk.
	j, err := st.jobSvc.ClaimNext(ctx, "w1", 0, false)
	if err != nil || j != nil {
		t.Fatalf("expected nil job when canTranscribe=false, got j=%v err=%v", j, err)
	}

	// First claimable transcribe_chunk MUST be c0 (seq 1 & 3 blocked).
	j0, err := st.jobSvc.ClaimNext(ctx, "w1", 0, true)
	if err != nil || j0 == nil || j0.ResourceID != c0 {
		t.Fatalf("expected c0 first, got %+v err=%v", j0, err)
	}

	// While c0 is still leased/uploaded, c1 and c3 are blocked.
	jBlocked, err := st.jobSvc.ClaimNext(ctx, "w1", 0, true)
	if err != nil || jBlocked != nil {
		t.Fatalf("expected c1/c3 blocked before c0 terminal, got %+v err=%v", jBlocked, err)
	}

	// Mark c0 transcribed & complete j0 -> now c1 is eligible.
	_, _ = st.db.W.Exec(`UPDATE audio_chunks SET state='transcribed' WHERE id=?`, c0)
	if !st.jobSvc.Complete(ctx, j0.ID, "w1") {
		t.Fatal("complete j0 failed")
	}
	j1, err := st.jobSvc.ClaimNext(ctx, "w1", 0, true)
	if err != nil || j1 == nil || j1.ResourceID != c1 {
		t.Fatalf("expected c1 after c0 terminal, got %+v err=%v", j1, err)
	}

	// Mark c1 silent & complete j1 -> without a gap covering seq 2, c3 is still blocked.
	_, _ = st.db.W.Exec(`UPDATE audio_chunks SET state='silent' WHERE id=?`, c1)
	if !st.jobSvc.Complete(ctx, j1.ID, "w1") {
		t.Fatal("complete j1 failed")
	}
	jBlocked3, err := st.jobSvc.ClaimNext(ctx, "w1", 0, true)
	if err != nil || jBlocked3 != nil {
		t.Fatalf("expected c3 blocked while seq 2 missing without gap, got %+v err=%v", jBlocked3, err)
	}

	// Recording a gap covering seq 2 unblocks c3!
	if _, err := st.db.W.Exec(`INSERT INTO recording_gaps
		(id, session_id, source_id, start_offset_ms, end_offset_ms, start_sequence, end_sequence, reason)
		VALUES (?, ?, ?, 2000, 3000, 2, 2, 'user_paused')`, uuid.NewString(), sessID, srcID); err != nil {
		t.Fatal(err)
	}
	j3, err := st.jobSvc.ClaimNext(ctx, "w1", 0, true)
	if err != nil || j3 == nil || j3.ResourceID != c3 {
		t.Fatalf("expected c3 across gap at seq 2, got %+v err=%v", j3, err)
	}

	// Test SSE /api/v1/events delivery.
	if err := events.EmitExec(ctx, st.db.W, userID, "chunk.updated", "audio_chunk", c0, map[string]any{"chunkId": c0, "state": "transcribed"}); err != nil {
		t.Fatal(err)
	}
	sseCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(sseCtx, "GET", srv.URL+"/api/v1/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatalf("SSE status %d", res.StatusCode)
	}
	sc := bufio.NewScanner(res.Body)
	var lines []string
	for sc.Scan() {
		line := sc.Text()
		lines = append(lines, line)
		if strings.HasPrefix(line, "data: ") && strings.Contains(line, c0) {
			cancel()
			break
		}
	}
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "event: chunk.updated") || !strings.Contains(joined, c0) {
		t.Fatalf("expected SSE event for %s, got:\n%s", c0, joined)
	}
}
