package ingest

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

var (
	sha256HexRe    = regexp.MustCompile(`^[a-fA-F0-9]{64}$`)
	contentRangeRe = regexp.MustCompile(`^bytes (\d+)-(\d+)/(\d+)$`)
	allowedSourceK = map[string]bool{"microphone": true, "system": true, "combined": true, "import": true, "wearable": true}
	allowedGapRsn  = map[string]bool{"sleep": true, "permission_lost": true, "storage_full": true, "capture_error": true, "user_paused": true, "device_shutdown": true}
)

type Routes struct {
	Svc  *Service
	Imp  *ImportService
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	wrap := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope("ingest:write", h))
	}

	mux.Handle("POST /api/v1/ingest/sessions", wrap(rt.handleCreateSession))
	mux.Handle("GET /api/v1/ingest/sessions/{id}/sync-state", wrap(rt.handleSyncState))
	mux.Handle("PATCH /api/v1/ingest/sessions/{id}", wrap(rt.handleCloseSession))
	mux.Handle("POST /api/v1/ingest/sessions/{id}/sources", wrap(rt.handleAddSource))
	mux.Handle("PATCH /api/v1/ingest/sessions/{id}/sources/{sourceId}", wrap(rt.handleCloseSource))
	mux.Handle("POST /api/v1/ingest/sessions/{id}/gaps", wrap(rt.handleAddGaps))
	mux.Handle("PUT /api/v1/ingest/sessions/{id}/sources/{sourceId}/chunks/{sequence}", wrap(rt.handlePutChunk))
	mux.Handle("POST /api/v1/ingest/chunks/status", wrap(rt.handleChunkStatus))
	mux.Handle("POST /api/v1/ingest/chunks/released", wrap(rt.handleChunkReleased))
	mux.Handle("GET /api/v1/ingest/stream", wrap(func(w http.ResponseWriter, r *http.Request) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusNotImplemented, "FEATURE_NOT_ENABLED", "Wearable streaming is not enabled in v1."))
	}))

	mux.Handle("POST /api/v1/imports", wrap(rt.handleDeclareImport))
	mux.Handle("POST /api/v1/imports/", wrap(rt.handleDeclareImport))
	mux.Handle("GET /api/v1/imports/{id}", wrap(rt.handleGetImport))
	mux.Handle("PUT /api/v1/imports/{id}/parts/{part}", wrap(rt.handlePutImportPart))
	mux.Handle("POST /api/v1/imports/{id}/complete", wrap(rt.handleCompleteImport))
	mux.Handle("DELETE /api/v1/imports/{id}", wrap(rt.handleCancelImport))
}

func validUUID(s string) bool {
	_, err := uuid.Parse(s)
	return err == nil
}

func validateSource(in SourceInput) error {
	if in.ID != "" && !validUUID(in.ID) {
		return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid source id.")
	}
	if len(in.ClientUUID) < 8 || len(in.ClientUUID) > 128 || !allowedSourceK[in.Kind] ||
		in.ChannelLayout == "" || len(in.ChannelLayout) > 80 || in.SampleRate <= 0 || in.SampleRate > 384000 ||
		in.SampleFormat == "" || len(in.SampleFormat) > 40 {
		return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid recording source.")
	}
	if in.Metadata != nil {
		if rawSpk, exists := in.Metadata["speaker"]; exists && rawSpk != nil {
			m, ok := rawSpk.(map[string]any)
			if !ok {
				return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid source speaker metadata.")
			}
			k, _ := m["key"].(string)
			if k == "" || len(k) > 200 {
				return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid source speaker metadata key.")
			}
			if rawName, hasName := m["name"]; hasName && rawName != nil {
				n, ok := rawName.(string)
				if !ok || len(n) == 0 || len(n) > 120 {
					return httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid source speaker metadata name.")
				}
			}
		}
	}
	return nil
}

func (rt *Routes) handleCreateSession(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ID                string        `json:"id"`
		DeviceID          string        `json:"deviceId"`
		ClientUUID        string        `json:"clientUuid"`
		StartedAt         string        `json:"startedAt"`
		Timezone          string        `json:"timezone"`
		ClockOffsetMs     *int64        `json:"clockOffsetMs"`
		ConsentAttestedAt string        `json:"consentAttestedAt"`
		Sources           []SourceInput `json:"sources"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if (body.ID != "" && !validUUID(body.ID)) || !validUUID(body.DeviceID) ||
		len(body.ClientUUID) < 8 || len(body.ClientUUID) > 128 ||
		!timeutil.IsIANATimezone(body.Timezone) || len(body.Timezone) > 100 ||
		len(body.Sources) == 0 || len(body.Sources) > 8 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "The request is invalid."))
		return
	}
	if _, err := timeutil.ParseISO(body.StartedAt); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "startedAt must be an ISO-8601 datetime."))
		return
	}
	if _, err := timeutil.ParseISO(body.ConsentAttestedAt); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "consentAttestedAt must be an ISO-8601 datetime."))
		return
	}
	for _, s := range body.Sources {
		if err := validateSource(s); err != nil {
			httperr.WriteError(w, r, rt.Log, err)
			return
		}
	}
	sess, srcs, err := rt.Svc.CreateSession(r.Context(), a.UserID, CreateSessionInput{
		ID: body.ID, DeviceID: body.DeviceID, ClientUUID: body.ClientUUID,
		StartedAt: body.StartedAt, Timezone: body.Timezone, ClockOffsetMs: body.ClockOffsetMs,
		ConsentAttestedAt: body.ConsentAttestedAt, Sources: body.Sources,
	})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"session": sess, "sources": srcs})
}

func (rt *Routes) handleSyncState(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	st, err := rt.Svc.SyncState(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (rt *Routes) handleCloseSession(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		EndedAt string            `json:"endedAt"`
		Status  string            `json:"status"`
		Sources []CloseSourceSpec `json:"sources"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if _, err := timeutil.ParseISO(body.EndedAt); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "endedAt must be an ISO-8601 datetime."))
		return
	}
	if body.Status != "" && body.Status != "ended" && body.Status != "interrupted" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid session status."))
		return
	}
	for _, s := range body.Sources {
		if !validUUID(s.ID) || s.FinalSequence < -1 {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid close source payload."))
			return
		}
	}
	sess, err := rt.Svc.CloseSession(r.Context(), a.UserID, r.PathValue("id"), body.EndedAt, body.Status, body.Sources)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, sess)
}

func (rt *Routes) handleAddSource(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body SourceInput
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if err := validateSource(body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	src, err := rt.Svc.AddSource(r.Context(), a.UserID, r.PathValue("id"), body)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, src)
}

func (rt *Routes) handleCloseSource(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		FinalSequence *int `json:"finalSequence"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.FinalSequence == nil || *body.FinalSequence < -1 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "finalSequence is required."))
		return
	}
	st, err := rt.Svc.CloseSource(r.Context(), a.UserID, r.PathValue("id"), r.PathValue("sourceId"), *body.FinalSequence)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, st)
}

func (rt *Routes) handleAddGaps(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Gaps []GapInput `json:"gaps"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.Gaps) == 0 || len(body.Gaps) > 1000 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "gaps must contain 1–1000 items."))
		return
	}
	for _, g := range body.Gaps {
		if (g.ID != "" && !validUUID(g.ID)) || !validUUID(g.SourceID) || g.StartOffsetMs < 0 ||
			g.EndOffsetMs <= g.StartOffsetMs || !allowedGapRsn[g.Reason] ||
			(g.StartSequence == nil) != (g.EndSequence == nil) ||
			(g.StartSequence != nil && (*g.StartSequence < 0 || *g.EndSequence < *g.StartSequence)) {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Gap sequence coverage must be a complete, ordered range."))
			return
		}
	}
	if err := rt.Svc.AddGaps(r.Context(), a.UserID, r.PathValue("id"), body.Gaps); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// saveMultipartFile extracts a single named multipart file onto dstPath bounded by maxBytes.
func saveMultipartFile(r *http.Request, fieldName, dstPath string, maxBytes int64) (mimeType string, err error) {
	if maxBytes > 0 {
		r.Body = http.MaxBytesReader(nil, r.Body, maxBytes+256*1024)
	}
	mr, err := r.MultipartReader()
	if err != nil {
		return "", httperr.New(http.StatusBadRequest, "INVALID_MULTIPART", "Expected multipart form data.")
	}
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			var maxErr *http.MaxBytesError
			if errors.As(err, &maxErr) {
				return "", httperr.New(http.StatusRequestEntityTooLarge, "LIMIT_FILE_SIZE", "File too large.")
			}
			return "", httperr.New(http.StatusBadRequest, "INVALID_MULTIPART", "Malformed multipart stream.")
		}
		if part.FormName() != fieldName {
			part.Close()
			continue
		}
		if err := os.MkdirAll(filepath.Dir(dstPath), 0o700); err != nil {
			part.Close()
			return "", err
		}
		out, err := os.OpenFile(dstPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			part.Close()
			return "", err
		}
		n, cerr := io.Copy(out, io.LimitReader(part, maxBytes+1))
		_ = out.Close()
		part.Close()
		if cerr != nil {
			_ = os.Remove(dstPath)
			return "", httperr.New(http.StatusBadRequest, "INVALID_MULTIPART", "Could not read uploaded file.")
		}
		if n > maxBytes {
			_ = os.Remove(dstPath)
			return "", httperr.New(http.StatusRequestEntityTooLarge, "LIMIT_FILE_SIZE", "Uploaded file exceeds limit.")
		}
		return part.Header.Get("Content-Type"), nil
	}
	return "", nil
}

func (rt *Routes) handlePutChunk(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	seq, err := strconv.Atoi(r.PathValue("sequence"))
	if err != nil || seq < 0 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_SEQUENCE", "Chunk sequence must be a non-negative integer."))
		return
	}
	idemp := r.Header.Get("Idempotency-Key")
	if idemp == "" || len(idemp) > 200 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key is required."))
		return
	}
	hashHdr := r.Header.Get("X-Chunk-Sha256")
	if !sha256HexRe.MatchString(hashHdr) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_HASH", "X-Chunk-Sha256 must be a hexadecimal SHA-256 digest."))
		return
	}

	tmp := rt.Svc.TempAudio.IncomingPath()
	mime, mErr := saveMultipartFile(r, "audio", tmp, rt.Svc.cfg().MaxUploadBytes)
	if mErr != nil {
		httperr.WriteError(w, r, rt.Log, mErr)
		return
	}
	if _, statErr := os.Stat(tmp); statErr != nil {
		tmp = ""
	} else {
		defer os.Remove(tmp)
	}

	container := strings.TrimSpace(r.Header.Get("X-Audio-Container"))
	if container == "" {
		if parts := strings.SplitN(mime, "/", 2); len(parts) == 2 {
			container = strings.TrimSpace(strings.SplitN(parts[1], ";", 2)[0])
		}
	}
	if container == "" {
		container = "bin"
	}

	durMs, durErr := strconv.Atoi(strings.TrimSpace(r.Header.Get("X-Chunk-Duration-Ms")))
	ovRaw := strings.TrimSpace(r.Header.Get("X-Chunk-Overlap-Ms"))
	ovMs := 0
	var ovErr error
	if ovRaw != "" {
		ovMs, ovErr = strconv.Atoi(ovRaw)
	}
	monoOff, monoErr := strconv.ParseInt(strings.TrimSpace(r.Header.Get("X-Monotonic-Offset-Ms")), 10, 64)
	devStarted := strings.TrimSpace(r.Header.Get("X-Device-Started-At"))
	chLayout := strings.TrimSpace(r.Header.Get("X-Channel-Layout"))
	if chLayout == "" {
		chLayout = "mono"
	}
	codec := strings.TrimSpace(r.Header.Get("X-Audio-Codec"))
	if codec == "" {
		codec = "pcm_s16le"
	}
	cEnc := strings.TrimSpace(r.Header.Get("X-Audio-Content-Encoding"))
	if cEnc == "" {
		cEnc = "identity"
	}
	if cEnc != "identity" && cEnc != "gzip" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_AUDIO_ENCODING", "Unsupported audio content encoding."))
		return
	}
	if durErr != nil || ovErr != nil || monoErr != nil || devStarted == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_CHUNK_METADATA", "Chunk timing headers are invalid or incomplete."))
		return
	}

	rec, err := rt.Svc.AcceptChunk(r.Context(), a.UserID, r.PathValue("id"), r.PathValue("sourceId"), seq, ChunkInput{
		IdempotencyKey: idemp, SHA256: strings.ToLower(hashHdr),
		DurationMs: durMs, OverlapMs: ovMs, ChannelLayout: chLayout,
		MonotonicOffsetMs: monoOff, DeviceStartedAt: devStarted,
		Container: container, Codec: codec, ContentEncoding: cEnc,
		IsFinal: strings.EqualFold(r.Header.Get("X-Final-Chunk"), "true"),
	}, tmp)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	st := http.StatusOK
	if rec.State == "uploaded" && !rec.Duplicate {
		st = http.StatusAccepted
	}
	httpx.WriteJSON(w, st, map[string]any{"receipt": rec})
}

func (rt *Routes) handleChunkStatus(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ChunkIDs []string `json:"chunkIds"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.ChunkIDs) == 0 || len(body.ChunkIDs) > config.ChunkReceiptBatchLimit {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid chunkIds list."))
		return
	}
	for _, cid := range body.ChunkIDs {
		if !validUUID(cid) {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "chunkIds must be UUIDs."))
			return
		}
	}
	list, err := rt.Svc.Status(r.Context(), a.UserID, body.ChunkIDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"receipts": list})
}

func (rt *Routes) handleChunkReleased(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ChunkIDs []string `json:"chunkIds"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if len(body.ChunkIDs) == 0 || len(body.ChunkIDs) > config.ChunkReceiptBatchLimit {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid chunkIds list."))
		return
	}
	for _, cid := range body.ChunkIDs {
		if !validUUID(cid) {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "chunkIds must be UUIDs."))
			return
		}
	}
	cnt, err := rt.Svc.Released(r.Context(), a.UserID, body.ChunkIDs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"released": cnt})
}

func (rt *Routes) handleDeclareImport(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ID           string `json:"id"`
		DeviceID     string `json:"deviceId"`
		OriginalName string `json:"originalName"`
		ContentType  string `json:"contentType"`
		TotalSize    int64  `json:"totalSize"`
		SHA256       string `json:"sha256"`
		PartSize     int64  `json:"partSize"`
		CaptureTime  string `json:"captureTime"`
		Timezone     string `json:"timezone"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if (body.ID != "" && !validUUID(body.ID)) || (body.DeviceID != "" && !validUUID(body.DeviceID)) ||
		body.OriginalName == "" || len(body.OriginalName) > 512 ||
		body.ContentType == "" || len(body.ContentType) > 120 ||
		body.TotalSize <= 0 || !sha256HexRe.MatchString(body.SHA256) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid import declaration."))
		return
	}
	if body.CaptureTime != "" {
		if _, err := timeutil.ParseISO(body.CaptureTime); err != nil {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid captureTime."))
			return
		}
	}
	if body.Timezone != "" && (!timeutil.IsIANATimezone(body.Timezone) || len(body.Timezone) > 100) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid IANA timezone."))
		return
	}
	view, err := rt.Imp.Declare(r.Context(), a.UserID, DeclareImportInput{
		ID: body.ID, DeviceID: body.DeviceID, OriginalName: body.OriginalName, ContentType: body.ContentType,
		TotalSize: body.TotalSize, SHA256: strings.ToLower(body.SHA256), PartSize: body.PartSize,
		CaptureTime: body.CaptureTime, Timezone: body.Timezone,
	})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, view)
}

func (rt *Routes) handleGetImport(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	view, err := rt.Imp.Get(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

func (rt *Routes) handlePutImportPart(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	partNum, err := strconv.Atoi(r.PathValue("part"))
	if err != nil || partNum < 0 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_PART", "Part number is invalid."))
		return
	}
	m := contentRangeRe.FindStringSubmatch(r.Header.Get("Content-Range"))
	digest := r.Header.Get("X-Part-Sha256")
	if m == nil || !sha256HexRe.MatchString(digest) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "INVALID_PART_METADATA", "Content-Range and X-Part-Sha256 are required."))
		return
	}
	rStart, _ := strconv.ParseInt(m[1], 10, 64)
	rEnd, _ := strconv.ParseInt(m[2], 10, 64)
	rTotal, _ := strconv.ParseInt(m[3], 10, 64)

	tmp := filepath.Join(rt.Imp.cfg().Paths.ImportTmp, "incoming-"+uuid.NewString()+".part")
	_, mErr := saveMultipartFile(r, "part", tmp, rt.Imp.cfg().ImportPartBytes+1)
	if mErr != nil {
		httperr.WriteError(w, r, rt.Log, mErr)
		return
	}
	if _, statErr := os.Stat(tmp); statErr != nil {
		tmp = ""
	} else {
		defer os.Remove(tmp)
	}
	view, err := rt.Imp.AcceptPart(r.Context(), a.UserID, r.PathValue("id"), partNum, rStart, rEnd, rTotal, strings.ToLower(digest), tmp)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, view)
}

func (rt *Routes) handleCompleteImport(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	view, err := rt.Imp.Complete(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusAccepted, view)
}

func (rt *Routes) handleCancelImport(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Imp.Cancel(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
