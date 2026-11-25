package devices

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

var allowedKinds = map[string]bool{
	"browser":   true,
	"desktop":   true,
	"mobile":    true,
	"import":    true,
	"wearable":  true,
	"appliance": true,
}

type Device struct {
	ID                     string         `json:"id"`
	UserID                 string         `json:"user_id"`
	ClientUUID             string         `json:"client_uuid"`
	Name                   string         `json:"name"`
	Platform               string         `json:"platform"`
	Kind                   string         `json:"kind"`
	Capabilities           map[string]any `json:"capabilities"`
	ClockOffsetMs          *float64       `json:"clock_offset_ms"`
	ClockRttMs             *float64       `json:"clock_rtt_ms"`
	LastHeartbeatAt        *string        `json:"last_heartbeat_at"`
	RevokedAt              *string        `json:"revoked_at"`
	CreatedAt              string         `json:"created_at"`
	ActiveSessionID        *string        `json:"active_session_id,omitempty"`
	ActiveSessionStartedAt *string        `json:"active_session_started_at,omitempty"`
}

type Service struct {
	DB   *dbx.DB
	Cfg  func() config.Config
	HTTP *http.Client
	Log  *slog.Logger

	plaudMu      sync.Mutex
	partnerToken string
	partnerExp   time.Time
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) httpClient() *http.Client {
	if s.HTTP != nil {
		return s.HTTP
	}
	return ssrf.NewClient(ssrf.Options{Timeout: 20 * time.Second})
}

func nullPtr(v sql.NullString) *string {
	if !v.Valid {
		return nil
	}
	cp := v.String
	return &cp
}

func scanDevice(row interface{ Scan(...any) error }, withActive bool) (Device, error) {
	var d Device
	var capsJSON string
	var off, rtt sql.NullFloat64
	var hb, rev, actID, actStart sql.NullString
	var err error
	if withActive {
		err = row.Scan(&d.ID, &d.UserID, &d.ClientUUID, &d.Name, &d.Platform, &d.Kind, &capsJSON,
			&off, &rtt, &hb, &rev, &d.CreatedAt, &actID, &actStart)
	} else {
		err = row.Scan(&d.ID, &d.UserID, &d.ClientUUID, &d.Name, &d.Platform, &d.Kind, &capsJSON,
			&off, &rtt, &hb, &rev, &d.CreatedAt)
	}
	if err != nil {
		return Device{}, err
	}
	if off.Valid {
		v := off.Float64
		d.ClockOffsetMs = &v
	}
	if rtt.Valid {
		v := rtt.Float64
		d.ClockRttMs = &v
	}
	d.LastHeartbeatAt = nullPtr(hb)
	d.RevokedAt = nullPtr(rev)
	if withActive {
		d.ActiveSessionID = nullPtr(actID)
		d.ActiveSessionStartedAt = nullPtr(actStart)
	}
	if err := json.Unmarshal([]byte(capsJSON), &d.Capabilities); err != nil || d.Capabilities == nil {
		d.Capabilities = map[string]any{}
	}
	return d, nil
}

const deviceCols = `id, user_id, client_uuid, name, platform, kind, capabilities_json, clock_offset_ms, clock_rtt_ms, last_heartbeat_at, revoked_at, created_at`

func (s *Service) Register(ctx context.Context, userID, id, clientUUID, name, platform, kind string, caps map[string]any) (Device, error) {
	if !allowedKinds[kind] {
		return Device{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid device kind.")
	}
	if len(clientUUID) < 8 || len(clientUUID) > 128 || len(strings.TrimSpace(name)) == 0 || len(name) > 100 || len(platform) == 0 || len(platform) > 40 {
		return Device{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid device registration payload.")
	}
	if caps == nil {
		caps = map[string]any{}
	}
	capsB, _ := json.Marshal(caps)

	existing, err := scanDevice(s.DB.R.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM devices WHERE user_id=? AND client_uuid=?`, userID, clientUUID), false)
	if err == nil {
		if existing.RevokedAt != nil {
			return Device{}, httperr.New(http.StatusForbidden, "DEVICE_REVOKED", "This device has been revoked.")
		}
		if _, err := s.DB.W.ExecContext(ctx, `UPDATE devices SET name=?, platform=?, kind=?, capabilities_json=? WHERE id=?`,
			name, platform, kind, string(capsB), existing.ID); err != nil {
			return Device{}, err
		}
		return s.Get(ctx, userID, existing.ID)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return Device{}, err
	}

	if id == "" {
		id = uuid.NewString()
	}
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO devices (id, user_id, client_uuid, name, platform, kind, capabilities_json)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, id, userID, clientUUID, name, platform, kind, string(capsB)); err != nil {
		return Device{}, err
	}
	return s.Get(ctx, userID, id)
}

func (s *Service) List(ctx context.Context, userID string) ([]Device, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT d.id, d.user_id, d.client_uuid, d.name, d.platform, d.kind, d.capabilities_json,
		d.clock_offset_ms, d.clock_rtt_ms, d.last_heartbeat_at, d.revoked_at, d.created_at,
		(SELECT s.id FROM recording_sessions s WHERE s.device_id=d.id AND s.user_id=d.user_id AND s.status='active' ORDER BY s.corrected_started_at DESC LIMIT 1),
		(SELECT s.corrected_started_at FROM recording_sessions s WHERE s.device_id=d.id AND s.user_id=d.user_id AND s.status='active' ORDER BY s.corrected_started_at DESC LIMIT 1)
		FROM devices d WHERE d.user_id=? ORDER BY d.created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		d, err := scanDevice(rows, true)
		if err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Service) Get(ctx context.Context, userID, id string) (Device, error) {
	d, err := scanDevice(s.DB.R.QueryRowContext(ctx, `SELECT `+deviceCols+` FROM devices WHERE id=? AND user_id=?`, id, userID), false)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Device not found.")
	}
	return d, err
}

func (s *Service) Rename(ctx context.Context, userID, id, name string) (Device, error) {
	if len(strings.TrimSpace(name)) == 0 || len(name) > 100 {
		return Device{}, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid device name.")
	}
	res, err := s.DB.W.ExecContext(ctx, `UPDATE devices SET name=? WHERE id=? AND user_id=? AND revoked_at IS NULL`, name, id, userID)
	if err != nil {
		return Device{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return Device{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Device not found.")
	}
	return s.Get(ctx, userID, id)
}

func (s *Service) Revoke(ctx context.Context, userID, id string) error {
	res, err := s.DB.W.ExecContext(ctx, `UPDATE devices SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=? AND revoked_at IS NULL`, id, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httperr.New(http.StatusNotFound, "NOT_FOUND", "Device not found.")
	}
	return nil
}

func (s *Service) Heartbeat(ctx context.Context, userID, id string, clockOffsetMs *int64, clockRttMs *float64) (map[string]string, error) {
	serverReceived := timeutil.NowISO()
	if _, err := s.Get(ctx, userID, id); err != nil {
		return nil, err
	}
	var off sql.NullInt64
	if clockOffsetMs != nil {
		off = sql.NullInt64{Int64: *clockOffsetMs, Valid: true}
	}
	var rtt sql.NullFloat64
	if clockRttMs != nil {
		rtt = sql.NullFloat64{Float64: *clockRttMs, Valid: true}
	}
	if _, err := s.DB.W.ExecContext(ctx, `UPDATE devices SET last_heartbeat_at=?, clock_offset_ms=COALESCE(?, clock_offset_ms), clock_rtt_ms=COALESCE(?, clock_rtt_ms)
		WHERE id=? AND user_id=?`, serverReceived, off, rtt, id, userID); err != nil {
		return nil, err
	}
	return map[string]string{"serverReceivedAt": serverReceived, "serverSentAt": timeutil.NowISO()}, nil
}

// MintPlaudSession issues a short-lived Plaud Embedded SDK user token (no audio ever sent to Plaud).
func (s *Service) MintPlaudSession(ctx context.Context, userID string) (map[string]any, error) {
	c := s.cfg()
	if c.PlaudClientID == "" || c.PlaudClientSecret == "" {
		return nil, nil
	}
	apiRoot := "https://" + c.PlaudAPIHost + "/developer/api"
	partner, err := s.plaudPartnerToken(ctx, apiRoot, c.PlaudClientID, c.PlaudClientSecret)
	if err != nil {
		return nil, err
	}
	compactUID := strings.ReplaceAll(userID, "-", "")
	if len(compactUID) > 120 {
		compactUID = compactUID[:120]
	} else if len(compactUID) < 6 {
		if len(userID) > 120 {
			compactUID = userID[:120]
		} else {
			compactUID = userID
		}
	}
	payload, _ := json.Marshal(map[string]any{"user_id": compactUID, "expires_in": 86_400})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, apiRoot+"/open/partner/users/access-token", bytes.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+partner)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var parsed map[string]any
	_ = json.Unmarshal(raw, &parsed)
	tok, _ := parsed["access_token"].(string)
	if res.StatusCode < 200 || res.StatusCode >= 300 || tok == "" {
		return nil, httperr.New(res.StatusCode, "PLAUD_TOKEN_FAILED", fmt.Sprintf("Plaud user token failed (%d).", res.StatusCode))
	}
	exp := 86_400
	if f, ok := parsed["expires_in"].(float64); ok && f > 0 {
		exp = int(f)
	}
	return map[string]any{
		"accessToken":  tok,
		"expiresIn":    exp,
		"customDomain": c.PlaudAPIHost,
		"userId":       compactUID,
	}, nil
}

func (s *Service) plaudPartnerToken(ctx context.Context, apiRoot, id, secret string) (string, error) {
	s.plaudMu.Lock()
	if s.partnerToken != "" && time.Now().Add(60*time.Second).Before(s.partnerExp) {
		tok := s.partnerToken
		s.plaudMu.Unlock()
		return tok, nil
	}
	s.plaudMu.Unlock()

	creds := base64.StdEncoding.EncodeToString([]byte(id + ":" + secret))
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, apiRoot+"/oauth/partner/access-token", strings.NewReader("grant_type=client_credentials"))
	req.Header.Set("Authorization", "Basic "+creds)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var parsed map[string]any
	_ = json.Unmarshal(raw, &parsed)
	tok, _ := parsed["access_token"].(string)
	if res.StatusCode < 200 || res.StatusCode >= 300 || tok == "" {
		return "", httperr.New(res.StatusCode, "PLAUD_PARTNER_FAILED", fmt.Sprintf("Plaud partner token failed (%d).", res.StatusCode))
	}
	expSec := 3600
	if f, ok := parsed["expires_in"].(float64); ok && f > 0 {
		expSec = int(f)
	}
	s.plaudMu.Lock()
	s.partnerToken = tok
	s.partnerExp = time.Now().Add(time.Duration(expSec) * time.Second)
	s.plaudMu.Unlock()
	return tok, nil
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

func (rt *Routes) Mount(mux *http.ServeMux) {
	wrap := func(scope string, h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireScope(scope, h))
	}
	wrapAny := func(scopes []string, h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAnyScope(scopes, h))
	}

	mux.Handle("POST /api/v1/devices/plaud/session", wrapAny([]string{"devices:write", "ingest:write"}, rt.handlePlaud))
	mux.Handle("GET /api/v1/devices", wrap("devices:read", rt.handleList))
	mux.Handle("GET /api/v1/devices/", wrap("devices:read", rt.handleList))
	mux.Handle("POST /api/v1/devices", wrapAny([]string{"devices:write", "ingest:write"}, rt.handleRegister))
	mux.Handle("POST /api/v1/devices/", wrapAny([]string{"devices:write", "ingest:write"}, rt.handleRegister))
	mux.Handle("GET /api/v1/devices/{id}", wrap("devices:read", rt.handleGet))
	mux.Handle("PATCH /api/v1/devices/{id}", wrap("devices:write", rt.handleRename))
	mux.Handle("DELETE /api/v1/devices/{id}", wrap("devices:write", rt.handleRevoke))
	mux.Handle("POST /api/v1/devices/{id}/heartbeat", wrapAny([]string{"devices:write", "ingest:write"}, rt.handleHeartbeat))
}

func (rt *Routes) handlePlaud(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	sess, err := rt.Svc.MintPlaudSession(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if sess == nil {
		httpx.WriteJSON(w, http.StatusNotFound, map[string]string{"error": "Plaud devices are not configured on this server."})
		return
	}
	httpx.WriteJSON(w, http.StatusOK, sess)
}

func (rt *Routes) handleList(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	list, err := rt.Svc.List(r.Context(), a.UserID)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"devices": list})
}

func (rt *Routes) handleRegister(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ID           string         `json:"id"`
		ClientUUID   string         `json:"clientUuid"`
		Name         string         `json:"name"`
		Platform     string         `json:"platform"`
		Kind         string         `json:"kind"`
		Capabilities map[string]any `json:"capabilities"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if body.ID != "" {
		if _, err := uuid.Parse(body.ID); err != nil {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "id must be a UUID."))
			return
		}
	}
	dev, err := rt.Svc.Register(r.Context(), a.UserID, body.ID, body.ClientUUID, body.Name, body.Platform, body.Kind, body.Capabilities)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, dev)
}

func (rt *Routes) handleGet(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	dev, err := rt.Svc.Get(r.Context(), a.UserID, r.PathValue("id"))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, dev)
}

func (rt *Routes) handleRename(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Name string `json:"name"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	dev, err := rt.Svc.Rename(r.Context(), a.UserID, r.PathValue("id"), body.Name)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, dev)
}

func (rt *Routes) handleRevoke(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	if err := rt.Svc.Revoke(r.Context(), a.UserID, r.PathValue("id")); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (rt *Routes) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		ClientSentAt  string   `json:"clientSentAt"`
		ClockOffsetMs *int64   `json:"clockOffsetMs"`
		ClockRttMs    *float64 `json:"clockRttMs"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if _, err := timeutil.ParseISO(body.ClientSentAt); err != nil {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "clientSentAt must be ISO-8601."))
		return
	}
	if body.ClockRttMs != nil && *body.ClockRttMs < 0 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "clockRttMs must be non-negative."))
		return
	}
	res, err := rt.Svc.Heartbeat(r.Context(), a.UserID, r.PathValue("id"), body.ClockOffsetMs, body.ClockRttMs)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}
