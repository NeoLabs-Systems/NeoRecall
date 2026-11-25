package neorouter

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/audit"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

const (
	ProviderID = "neorouter"
	ClientID   = "neorecall"
	Scopes     = "chat transcription embedding"

	keyConnection = "neorouter.connection"
	keyAPIKey     = "neorouter.api_key"
)

var (
	AllRoles  = []string{"llm", "transcription", "embeddings"}
	RoleTypes = map[string]string{"llm": "chat", "transcription": "transcription", "embeddings": "embedding"}
	autoRe    = regexp.MustCompile(`^auto(-(free|plan|paid))?(:|$)`)
)

func IsAutoModel(id string) bool {
	return autoRe.MatchString(id)
}

type Connection struct {
	APIBase    string `json:"apiBase"`
	Origin     string `json:"origin"`
	APIKey     string `json:"-"`
	Embeddings bool   `json:"embeddings"`
}

func APIBaseFor(address string) string {
	raw := strings.TrimSpace(address)
	if raw == "" {
		return ""
	}
	if !regexp.MustCompile(`(?i)^https?://`).MatchString(raw) {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme == "" || u.Host == "" || u.User != nil {
		return ""
	}
	return u.Scheme + "://" + u.Host + "/v1"
}

type WorkloadAdapter interface {
	IsNeoRouter(ctx context.Context, workload string) bool
	SetNeoRouter(ctx context.Context, workload string) error
	ClearOverride(ctx context.Context, workload string) error
}

type RoleOffer struct {
	Models int    `json:"models"`
	Auto   int    `json:"auto"`
	Error  string `json:"error,omitempty"`
}

type Offer struct {
	Roles      map[string]RoleOffer `json:"roles"`
	NotAllowed map[string]int       `json:"notAllowed"`
}

type offerCacheEntry struct {
	offer     Offer
	expiresAt time.Time
}

type signInFlow struct {
	UserID     string
	APIBase    string
	DeviceCode string
	IntervalMs int
	ExpiresAt  time.Time
	Status     string // pending, completed, failed
	Error      string
}

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	HTTP      *http.Client
	Workloads WorkloadAdapter
	OnReindex func(ctx context.Context) error
	Log       *slog.Logger

	offerMu sync.Mutex
	offers  map[string]offerCacheEntry

	flowMu sync.Mutex
	flows  map[string]*signInFlow
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
	return ssrf.NewClient(ssrf.Options{Timeout: 30 * time.Second})
}

func (s *Service) Get(ctx context.Context) (*Connection, error) {
	if s.DB == nil {
		return nil, nil
	}
	var connRaw, keyRaw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM app_settings WHERE key=?`, keyConnection).Scan(&connRaw); err != nil {
		return nil, nil
	}
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM app_settings WHERE key=?`, keyAPIKey).Scan(&keyRaw); err != nil {
		return nil, nil
	}
	var stored struct {
		APIBase    string `json:"apiBase"`
		Embeddings bool   `json:"embeddings"`
	}
	var encKey string
	if json.Unmarshal([]byte(connRaw), &stored) != nil || stored.APIBase == "" || json.Unmarshal([]byte(keyRaw), &encKey) != nil || encKey == "" {
		return nil, nil
	}
	mk, err := s.MasterKey()
	if err != nil {
		return nil, err
	}
	apiKey, err := crypto.DecryptString(mk, encKey)
	if err != nil {
		return nil, err
	}
	u, err := url.Parse(stored.APIBase)
	if err != nil {
		return nil, err
	}
	return &Connection{
		APIBase:    stored.APIBase,
		Origin:     u.Scheme + "://" + u.Host,
		APIKey:     apiKey,
		Embeddings: stored.Embeddings,
	}, nil
}

func (s *Service) Save(ctx context.Context, apiBase, apiKey string, embeddings bool) error {
	mk, err := s.MasterKey()
	if err != nil {
		return err
	}
	enc, err := crypto.EncryptString(mk, apiKey)
	if err != nil {
		return err
	}
	cb, _ := json.Marshal(map[string]any{"apiBase": apiBase, "embeddings": embeddings})
	kb, _ := json.Marshal(enc)
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	upsert := `INSERT INTO app_settings (key, value_json) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`
	if _, err := tx.ExecContext(ctx, upsert, keyConnection, string(cb)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, upsert, keyAPIKey, string(kb)); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Service) SetEmbeddings(ctx context.Context, enabled bool) error {
	var connRaw string
	if err := s.DB.R.QueryRowContext(ctx, `SELECT value_json FROM app_settings WHERE key=?`, keyConnection).Scan(&connRaw); err != nil {
		return nil
	}
	var m map[string]any
	if json.Unmarshal([]byte(connRaw), &m) != nil {
		return nil
	}
	m["embeddings"] = enabled
	b, _ := json.Marshal(m)
	_, err := s.DB.W.ExecContext(ctx, `INSERT INTO app_settings (key, value_json) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')`, keyConnection, string(b))
	return err
}

func (s *Service) Clear(ctx context.Context) error {
	_, err := s.DB.W.ExecContext(ctx, `DELETE FROM app_settings WHERE key IN (?, ?)`, keyConnection, keyAPIKey)
	return err
}

type RouterError struct {
	Code    string
	Status  int
	Message string
}

func (e *RouterError) Error() string { return e.Message }

func (s *Service) Call(ctx context.Context, conn *Connection, method, path string, body any) (map[string]any, http.Header, error) {
	timeout := time.Duration(max(1000, s.cfg().NeoRouterRequestTimeoutMs)) * time.Millisecond
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(tctx, method, conn.APIBase+path, rdr)
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+conn.APIKey)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := s.httpClient().Do(req)
	if err != nil {
		return nil, nil, &RouterError{Code: "NEOROUTER_UNREACHABLE", Message: fmt.Sprintf("Could not reach NeoRouter at %s.", conn.Origin)}
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	var data map[string]any
	_ = json.Unmarshal(raw, &data)
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		msg := fmt.Sprintf("HTTP %d", res.StatusCode)
		if eObj, _ := data["error"].(map[string]any); eObj != nil {
			if m, _ := eObj["message"].(string); m != "" {
				msg = m
			}
		}
		code := "NEOROUTER_HTTP_ERROR"
		if res.StatusCode == 401 || res.StatusCode == 403 {
			code = "NEOROUTER_KEY_REJECTED"
		}
		return nil, res.Header, &RouterError{Code: code, Status: res.StatusCode, Message: "NeoRouter: " + msg}
	}
	return data, res.Header, nil
}

type ModelListResult struct {
	Models     []string
	NotAllowed map[string]int
}

func (s *Service) ModelList(ctx context.Context, conn *Connection, typ string) (ModelListResult, error) {
	data, _, err := s.Call(ctx, conn, http.MethodGet, "/models?type="+url.QueryEscape(typ), nil)
	if err != nil {
		return ModelListResult{}, err
	}
	res := ModelListResult{NotAllowed: map[string]int{}}
	if list, _ := data["data"].([]any); list != nil {
		for _, item := range list {
			if m, _ := item.(map[string]any); m != nil {
				if id, _ := m["id"].(string); id != "" {
					res.Models = append(res.Models, id)
				}
			}
		}
	}
	if nr, _ := data["neorouter"].(map[string]any); nr != nil {
		if na, _ := nr["not_allowed_for_key"].(map[string]any); na != nil {
			for k, v := range na {
				if f, ok := v.(float64); ok {
					res.NotAllowed[k] = int(f)
				}
			}
		}
	}
	return res, nil
}

type EmbedResult struct {
	Vector []float32
	Space  string
}

func (s *Service) Embed(ctx context.Context, conn *Connection, text, inputType string, dims int) (EmbedResult, error) {
	it := "query"
	if inputType == "passage" {
		it = "document"
	}
	data, hdr, err := s.Call(ctx, conn, http.MethodPost, "/embeddings", map[string]any{
		"model":      "auto",
		"input":      text,
		"dimensions": dims,
		"input_type": it,
	})
	if err != nil {
		return EmbedResult{}, err
	}
	arr, _ := data["data"].([]any)
	var first map[string]any
	if len(arr) > 0 {
		first, _ = arr[0].(map[string]any)
	}
	rawVec, _ := first["embedding"].([]any)
	if len(rawVec) != dims {
		return EmbedResult{}, &RouterError{
			Code:    "NEOROUTER_BAD_EMBEDDING",
			Message: fmt.Sprintf("NeoRouter returned %d embedding dimensions; %d are required.", len(rawVec), dims),
		}
	}
	vec := make([]float32, dims)
	var normSq float64
	for i, v := range rawVec {
		f, _ := v.(float64)
		vec[i] = float32(f)
		normSq += f * f
	}
	norm := math.Sqrt(normSq)
	if norm == 0 {
		norm = 1
	}
	for i := range vec {
		vec[i] = float32(float64(vec[i]) / norm)
	}
	space := strings.TrimSpace(hdr.Get("x-neorouter-embedding-pin"))
	if space == "" {
		space, _ = data["model"].(string)
	}
	if space == "" {
		space = "auto"
	}
	return EmbedResult{Vector: vec, Space: space}, nil
}

func (s *Service) ResetUnusedPin(ctx context.Context, conn *Connection, embedErr error, unused func(model string) bool) bool {
	var re *RouterError
	if embedErr == nil {
		return false
	}
	isWrongSize := (errors.As(embedErr, &re) && re.Code == "NEOROUTER_BAD_EMBEDDING") ||
		strings.Contains(embedErr.Error(), "dimensions instead of")
	if !isWrongSize {
		return false
	}
	data, _, err := s.Call(ctx, conn, http.MethodGet, "/embeddings/pin", nil)
	if err != nil || data == nil {
		return false
	}
	pin, _ := data["pin"].(map[string]any)
	model, _ := pin["canonicalId"].(string)
	if model == "" || !unused(model) {
		return false
	}
	del, _, err := s.Call(ctx, conn, http.MethodDelete, "/embeddings/pin", nil)
	if err != nil || del == nil {
		return false
	}
	reset, _ := del["reset"].(bool)
	return reset
}

func (s *Service) DescribeOffer(ctx context.Context, conn *Connection, fresh bool) (Offer, error) {
	sum := sha256.Sum256([]byte(conn.APIBase + "\n" + conn.APIKey))
	key := hex.EncodeToString(sum[:])

	s.offerMu.Lock()
	if s.offers == nil {
		s.offers = make(map[string]offerCacheEntry)
	}
	if !fresh {
		if e, ok := s.offers[key]; ok && time.Now().Before(e.expiresAt) {
			s.offerMu.Unlock()
			return e.offer, nil
		}
	}
	s.offerMu.Unlock()

	offer := Offer{Roles: map[string]RoleOffer{}, NotAllowed: map[string]int{}}
	for _, role := range AllRoles {
		typ := RoleTypes[role]
		list, err := s.ModelList(ctx, conn, typ)
		if err != nil {
			var re *RouterError
			if errors.As(err, &re) && re.Code == "NEOROUTER_UNREACHABLE" {
				return Offer{}, err
			}
			offer.Roles[role] = RoleOffer{Error: err.Error()}
			offer.NotAllowed[role] = 0
			continue
		}
		autoCount := 0
		for _, id := range list.Models {
			if IsAutoModel(id) {
				autoCount++
			}
		}
		offer.Roles[role] = RoleOffer{Models: len(list.Models) - autoCount, Auto: autoCount}
		offer.NotAllowed[role] = list.NotAllowed["free"] + list.NotAllowed["plan"] + list.NotAllowed["paid"]
	}

	ttl := time.Duration(max(1000, int(s.cfg().NeoRouterOfferCacheMs))) * time.Millisecond
	s.offerMu.Lock()
	s.offers[key] = offerCacheEntry{offer: offer, expiresAt: time.Now().Add(ttl)}
	s.offerMu.Unlock()
	return offer, nil
}

func (s *Service) ActiveRoles(ctx context.Context) []string {
	conn, err := s.Get(ctx)
	if err != nil || conn == nil {
		return []string{}
	}
	var active []string
	for _, role := range AllRoles {
		if role == "embeddings" {
			if conn.Embeddings {
				active = append(active, role)
			}
			continue
		}
		if s.Workloads != nil && s.Workloads.IsNeoRouter(ctx, role) {
			active = append(active, role)
		}
	}
	if active == nil {
		return []string{}
	}
	return active
}

func (s *Service) setRole(ctx context.Context, role string, on bool) error {
	if role == "embeddings" {
		conn, _ := s.Get(ctx)
		was := conn != nil && conn.Embeddings
		if err := s.SetEmbeddings(ctx, on); err != nil {
			return err
		}
		if was != on && s.OnReindex != nil {
			_ = s.OnReindex(ctx)
		}
		return nil
	}
	if s.Workloads == nil {
		return nil
	}
	isRouter := s.Workloads.IsNeoRouter(ctx, role)
	if on && !isRouter {
		return s.Workloads.SetNeoRouter(ctx, role)
	}
	if !on && isRouter {
		return s.Workloads.ClearOverride(ctx, role)
	}
	return nil
}

func (s *Service) ApplyConnection(ctx context.Context, apiBase, apiKey string) error {
	conn, _ := s.Get(ctx)
	curEmb := conn != nil && conn.Embeddings
	if err := s.Save(ctx, apiBase, apiKey, curEmb); err != nil {
		return err
	}
	for _, role := range AllRoles {
		if err := s.setRole(ctx, role, true); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) UpdateRoles(ctx context.Context, wanted []string) ([]string, error) {
	if conn, _ := s.Get(ctx); conn == nil {
		return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_NOT_CONNECTED", "NeoRouter is not connected.")
	}
	set := make(map[string]bool, len(wanted))
	for _, r := range wanted {
		set[r] = true
	}
	for _, role := range AllRoles {
		if err := s.setRole(ctx, role, set[role]); err != nil {
			return nil, err
		}
	}
	return s.ActiveRoles(ctx), nil
}

func (s *Service) Disconnect(ctx context.Context) error {
	if conn, _ := s.Get(ctx); conn == nil {
		return nil
	}
	for _, role := range AllRoles {
		_ = s.setRole(ctx, role, false)
	}
	return s.Clear(ctx)
}

func (s *Service) postForm(ctx context.Context, targetURL string, form url.Values) (int, map[string]any, error) {
	timeout := time.Duration(max(1000, s.cfg().NeoRouterRequestTimeoutMs)) * time.Millisecond
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(tctx, http.MethodPost, targetURL, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var parsed map[string]any
	_ = json.Unmarshal(raw, &parsed)
	return res.StatusCode, parsed, nil
}

func (s *Service) pruneFlowsLocked(now time.Time) {
	for id, f := range s.flows {
		if !now.Before(f.ExpiresAt) && f.Status == "pending" {
			delete(s.flows, id)
		}
	}
}

func (s *Service) schedulePoll(id string, delay time.Duration) {
	time.AfterFunc(delay, func() {
		s.pollSignIn(id)
	})
}

func (s *Service) pollSignIn(id string) {
	s.flowMu.Lock()
	f, ok := s.flows[id]
	if !ok || f.Status != "pending" {
		s.flowMu.Unlock()
		return
	}
	if !time.Now().Before(f.ExpiresAt) {
		f.Status = "failed"
		f.Error = "The sign-in expired. Start again."
		s.flowMu.Unlock()
		return
	}
	apiBase := f.APIBase
	devCode := f.DeviceCode
	intervalMs := f.IntervalMs
	s.flowMu.Unlock()

	u, err := url.Parse(apiBase)
	if err != nil {
		return
	}
	origin := u.Scheme + "://" + u.Host
	status, data, callErr := s.postForm(context.Background(), origin+"/oauth/token", url.Values{
		"grant_type":  {"urn:ietf:params:oauth:grant-type:device_code"},
		"device_code": {devCode},
		"client_id":   {ClientID},
	})
	if callErr == nil && status >= 200 && status < 300 {
		if tok, _ := data["access_token"].(string); tok != "" {
			err := s.ApplyConnection(context.Background(), apiBase, tok)
			s.flowMu.Lock()
			if fl := s.flows[id]; fl != nil {
				if err != nil {
					fl.Status = "failed"
					fl.Error = err.Error()
				} else {
					fl.Status = "completed"
				}
			}
			s.flowMu.Unlock()
			return
		}
	}
	code, _ := data["error"].(string)
	if callErr != nil {
		code = "network"
	}
	if code == "slow_down" {
		intervalMs += 5000
	}
	if code == "authorization_pending" || code == "slow_down" || code == "network" {
		s.flowMu.Lock()
		if fl := s.flows[id]; fl != nil && fl.Status == "pending" {
			fl.IntervalMs = intervalMs
			s.schedulePoll(id, time.Duration(intervalMs)*time.Millisecond)
		}
		s.flowMu.Unlock()
		return
	}
	errMsg, _ := data["error_description"].(string)
	if code == "access_denied" {
		errMsg = "The connection was declined in NeoRouter."
	} else if errMsg == "" {
		errMsg = "NeoRouter did not hand out a key."
	}
	s.flowMu.Lock()
	if fl := s.flows[id]; fl != nil {
		fl.Status = "failed"
		fl.Error = errMsg
	}
	s.flowMu.Unlock()
}

func (s *Service) BeginSignIn(ctx context.Context, userID, address string) (map[string]any, error) {
	apiBase := APIBaseFor(address)
	if apiBase == "" {
		return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_BAD_ADDRESS", "Enter the address of your NeoRouter, for example https://router.example.com.")
	}
	u, _ := url.Parse(apiBase)
	origin := u.Scheme + "://" + u.Host
	host, _ := os.Hostname()
	status, data, err := s.postForm(ctx, origin+"/oauth/device/code", url.Values{
		"client_id":   {ClientID},
		"client_name": {fmt.Sprintf("NeoRecall (%s)", host)},
		"scope":       {Scopes},
	})
	if err != nil {
		return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_UNREACHABLE", fmt.Sprintf("Could not reach NeoRouter at %s.", origin))
	}
	devCode, _ := data["device_code"].(string)
	if status < 200 || status >= 300 || devCode == "" {
		return nil, httperr.New(http.StatusBadRequest, "NEOROUTER_NOT_A_ROUTER", fmt.Sprintf("%s did not answer like a NeoRouter. Check the address.", origin))
	}

	rawID := make([]byte, 18)
	_, _ = rand.Read(rawID)
	id := hex.EncodeToString(rawID)

	intSec := 5.0
	if v, ok := data["interval"].(float64); ok && v >= 1 {
		intSec = v
	}
	intervalMs := int(intSec * 1000)
	expSec := 600.0
	if v, ok := data["expires_in"].(float64); ok && v > 0 {
		expSec = v
	}
	ttl := time.Duration(expSec) * time.Second
	if maxTTL := time.Duration(s.cfg().NeoRouterSignInTTLMs) * time.Millisecond; maxTTL > 0 && maxTTL < ttl {
		ttl = maxTTL
	}

	s.flowMu.Lock()
	if s.flows == nil {
		s.flows = make(map[string]*signInFlow)
	}
	s.pruneFlowsLocked(time.Now())
	s.flows[id] = &signInFlow{
		UserID:     userID,
		APIBase:    apiBase,
		DeviceCode: devCode,
		IntervalMs: intervalMs,
		ExpiresAt:  time.Now().Add(ttl),
		Status:     "pending",
	}
	s.flowMu.Unlock()
	s.schedulePoll(id, time.Duration(intervalMs)*time.Millisecond)

	verURL, _ := data["verification_uri_complete"].(string)
	if verURL == "" {
		verURL, _ = data["verification_uri"].(string)
	}
	userCode, _ := data["user_code"].(string)
	return map[string]any{"id": id, "url": verURL, "userCode": userCode}, nil
}

func (s *Service) SignInStatus(id, userID string) (map[string]any, bool) {
	s.flowMu.Lock()
	defer s.flowMu.Unlock()
	if s.flows == nil {
		return nil, false
	}
	s.pruneFlowsLocked(time.Now())
	f, ok := s.flows[id]
	if !ok || f.UserID != userID {
		return nil, false
	}
	if f.Status != "pending" {
		delete(s.flows, id)
	}
	var errVal any
	if f.Error != "" {
		errVal = f.Error
	}
	return map[string]any{"status": f.Status, "error": errVal}, true
}

func (s *Service) Describe(ctx context.Context) map[string]any {
	conn, _ := s.Get(ctx)
	if conn == nil {
		return map[string]any{
			"connected":         false,
			"address":           nil,
			"roles":             []string{},
			"offer":             nil,
			"reachable":         false,
			"unreachableReason": nil,
		}
	}
	var offerAny any
	var reason any
	offer, err := s.DescribeOffer(ctx, conn, true)
	if err != nil {
		reason = err.Error()
	} else {
		offerAny = offer
	}
	return map[string]any{
		"connected":         true,
		"address":           conn.Origin,
		"roles":             s.ActiveRoles(ctx),
		"offer":             offerAny,
		"reachable":         offerAny != nil,
		"unreachableReason": reason,
	}
}

type Routes struct {
	Svc  *Service
	Auth *auth.Authenticator
	Log  *slog.Logger
}

// Mount mounts routes under /api/v1/admin/neorouter*.
func (rt *Routes) Mount(mux *http.ServeMux) {
	admin := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireAdmin(h))
	}
	mux.Handle("GET /api/v1/admin/neorouter", admin(rt.handleDescribe))
	mux.Handle("GET /api/v1/admin/neorouter/", admin(rt.handleDescribe))
	mux.Handle("POST /api/v1/admin/neorouter/connect", admin(rt.handleConnect))
	mux.Handle("GET /api/v1/admin/neorouter/connect/{id}", admin(rt.handleConnectStatus))
	mux.Handle("PUT /api/v1/admin/neorouter/roles", admin(rt.handleRoles))
	mux.Handle("DELETE /api/v1/admin/neorouter", admin(rt.handleDisconnect))
	mux.Handle("DELETE /api/v1/admin/neorouter/", admin(rt.handleDisconnect))
}

func (rt *Routes) handleDescribe(w http.ResponseWriter, r *http.Request) {
	out := rt.Svc.Describe(r.Context())
	out["allRoles"] = AllRoles
	httpx.WriteJSON(w, http.StatusOK, out)
}

func (rt *Routes) handleConnect(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Address string `json:"address"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	addr := strings.TrimSpace(body.Address)
	if addr == "" || len(addr) > 2048 {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "address is required."))
		return
	}
	started, err := rt.Svc.BeginSignIn(r.Context(), a.UserID, addr)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "neorouter_connect_started", IPAddress: httperr.ClientIP(r, false),
	})
	httpx.WriteJSON(w, http.StatusOK, started)
}

func (rt *Routes) handleConnectStatus(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	res, ok := rt.Svc.SignInStatus(r.PathValue("id"), a.UserID)
	if !ok {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusNotFound, "NEOROUTER_SIGN_IN_EXPIRED", "This sign-in expired. Start again."))
		return
	}
	if res["status"] == "completed" {
		_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
			ActorType: "admin", ActorID: a.UserID, Action: "neorouter_connected", IPAddress: httperr.ClientIP(r, false),
		})
	}
	httpx.WriteJSON(w, http.StatusOK, res)
}

func (rt *Routes) handleRoles(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	var body struct {
		Roles []string `json:"roles"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	allowed := map[string]bool{"llm": true, "transcription": true, "embeddings": true}
	if len(body.Roles) > len(AllRoles) {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Too many roles."))
		return
	}
	for _, rl := range body.Roles {
		if !allowed[rl] {
			httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Invalid NeoRouter role: "+rl))
			return
		}
	}
	active, err := rt.Svc.UpdateRoles(r.Context(), body.Roles)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "neorouter_roles_updated", IPAddress: httperr.ClientIP(r, false),
		Metadata: map[string]any{"roles": active},
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"roles": active})
}

func (rt *Routes) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	a := auth.FromContext(r.Context())
	_ = rt.Svc.Disconnect(r.Context())
	_ = audit.Record(r.Context(), rt.Svc.DB, audit.Entry{
		ActorType: "admin", ActorID: a.UserID, Action: "neorouter_disconnected", IPAddress: httperr.ClientIP(r, false),
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"success": true})
}
