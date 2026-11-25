package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

type nextcloudPending struct {
	BaseURL      string
	LoginURL     string
	PollToken    string
	PollEndpoint string
	StartedAt    time.Time
}

type neocloudPending struct {
	BaseURL    string
	DeviceCode string
	UserCode   string
	LoginURL   string
	ExpiresAt  time.Time
	IntervalMs int64
	LastPollAt time.Time
}

func (s *Service) NextcloudStart(ctx context.Context, userID, instanceURL string) (map[string]any, error) {
	baseURL, err := NormalizeInstanceURL(instanceURL, "Nextcloud")
	if err != nil {
		return nil, err
	}
	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, s.cfg().CloudHTTPTimeoutMs))*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(tctx, http.MethodPost, JoinURL(baseURL, "index.php/login/v2"), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "NeoRecall")
	req.Header.Set("Accept", "application/json")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_UNREACHABLE", "Could not reach that Nextcloud instance.")
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "That Nextcloud instance did not start a login.")
	}
	var payload struct {
		Login string `json:"login"`
		Poll  struct {
			Token    string `json:"token"`
			Endpoint string `json:"endpoint"`
		} `json:"poll"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&payload); err != nil || payload.Login == "" || payload.Poll.Token == "" || payload.Poll.Endpoint == "" {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "That Nextcloud instance did not start a login.")
	}
	if !SameOrigin(baseURL, payload.Poll.Endpoint) || !SameOrigin(baseURL, payload.Login) {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "That Nextcloud instance returned an unexpected login URL.")
	}
	s.mu.Lock()
	if s.ncFlow == nil {
		s.ncFlow = make(map[string]*nextcloudPending)
	}
	s.ncFlow[userID] = &nextcloudPending{
		BaseURL: baseURL, LoginURL: payload.Login, PollToken: payload.Poll.Token,
		PollEndpoint: payload.Poll.Endpoint, StartedAt: time.Now(),
	}
	s.mu.Unlock()
	return map[string]any{"status": "connecting", "type": "nextcloud", "loginUrl": payload.Login, "baseUrl": baseURL}, nil
}

func (s *Service) NextcloudPoll(ctx context.Context, userID string) (map[string]any, error) {
	s.mu.Lock()
	entry := s.ncFlow[userID]
	if entry != nil && time.Since(entry.StartedAt).Milliseconds() > s.cfg().CloudLoginTimeoutMs {
		delete(s.ncFlow, userID)
		entry = nil
	}
	s.mu.Unlock()
	if entry == nil {
		return nil, nil
	}

	form := url.Values{"token": {entry.PollToken}}.Encode()
	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, s.cfg().CloudHTTPTimeoutMs))*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(tctx, http.MethodPost, entry.PollEndpoint, strings.NewReader(form))
	req.Header.Set("User-Agent", "NeoRecall")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return map[string]any{"status": "connecting", "type": "nextcloud", "loginUrl": entry.LoginURL, "baseUrl": entry.BaseURL}, nil
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound {
		return map[string]any{"status": "connecting", "type": "nextcloud", "loginUrl": entry.LoginURL, "baseUrl": entry.BaseURL}, nil
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "Nextcloud login did not complete.")
	}
	var body struct {
		LoginName   string `json:"loginName"`
		AppPassword string `json:"appPassword"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body); err != nil || body.LoginName == "" || body.AppPassword == "" {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "Nextcloud login did not complete.")
	}
	s.mu.Lock()
	delete(s.ncFlow, userID)
	s.mu.Unlock()
	_, err = s.UpsertConnected(ctx, userID, ConnectInput{
		Type: "nextcloud", BaseURL: entry.BaseURL, Username: body.LoginName, Credential: body.AppPassword,
	})
	if err != nil {
		return nil, err
	}
	return s.PublicAccount(ctx, userID)
}

func (s *Service) NextcloudCancel(userID string) {
	s.mu.Lock()
	delete(s.ncFlow, userID)
	s.mu.Unlock()
}

func (s *Service) NeoCloudStart(ctx context.Context, userID, instanceURL string) (map[string]any, error) {
	baseURL, err := NormalizeInstanceURL(instanceURL, "NeoCloud")
	if err != nil {
		return nil, err
	}
	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, s.cfg().CloudHTTPTimeoutMs))*time.Millisecond)
	defer cancel()

	// Assert /api/version reports product="neocloud".
	vReq, _ := http.NewRequestWithContext(tctx, http.MethodGet, JoinURL(baseURL, "api/version"), nil)
	vReq.Header.Set("User-Agent", "NeoRecall")
	vReq.Header.Set("Accept", "application/json")
	vRes, err := s.httpClient().Do(vReq)
	if err != nil {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_UNREACHABLE", "Could not reach that NeoCloud server.")
	}
	var vBody struct {
		Product string `json:"product"`
	}
	_ = json.NewDecoder(io.LimitReader(vRes.Body, 1<<20)).Decode(&vBody)
	vRes.Body.Close()
	if vBody.Product != "neocloud" {
		return nil, httperr.New(http.StatusBadRequest, "NOT_NEOCLOUD", "That address is not a NeoCloud server.")
	}

	ab, _ := json.Marshal(map[string]any{"name": "NeoRecall", "platform": ""})
	aReq, _ := http.NewRequestWithContext(tctx, http.MethodPost, JoinURL(baseURL, "api/devices/authorize"), bytes.NewReader(ab))
	aReq.Header.Set("User-Agent", "NeoRecall")
	aReq.Header.Set("Content-Type", "application/json")
	aReq.Header.Set("Accept", "application/json")
	aRes, err := s.httpClient().Do(aReq)
	if err != nil {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_UNREACHABLE", "Could not reach that NeoCloud server.")
	}
	defer aRes.Body.Close()
	if aRes.StatusCode == http.StatusTooManyRequests {
		return nil, httperr.New(http.StatusTooManyRequests, "CLOUD_LOGIN_RATE_LIMITED", "NeoCloud asked to wait before starting another sign-in.")
	}
	if aRes.StatusCode < 200 || aRes.StatusCode >= 300 {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "That NeoCloud server did not start a sign-in.")
	}
	var authBody struct {
		DeviceCode      string `json:"deviceCode"`
		UserCode        string `json:"userCode"`
		VerificationURL string `json:"verificationUrl"`
		ExpiresIn       int64  `json:"expiresIn"`
		Interval        int64  `json:"interval"`
	}
	if err := json.NewDecoder(io.LimitReader(aRes.Body, 1<<20)).Decode(&authBody); err != nil || authBody.DeviceCode == "" || authBody.UserCode == "" {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "That NeoCloud server did not start a sign-in.")
	}
	loginURL := JoinURL(baseURL, "app/device") + "?code=" + url.QueryEscape(authBody.UserCode)
	if authBody.VerificationURL != "" && SameOrigin(baseURL, authBody.VerificationURL) {
		if u, err := url.Parse(authBody.VerificationURL); err == nil && (u.Scheme == "https" || u.Scheme == "http") {
			loginURL = u.String()
		}
	}
	lifeMs := int64(600_000)
	if authBody.ExpiresIn > 0 {
		lifeMs = min(authBody.ExpiresIn*1000, s.cfg().CloudLoginTimeoutMs)
	}
	intMs := int64(3000)
	if authBody.Interval > 0 {
		intMs = max(1000, min(authBody.Interval*1000, 30_000))
	}
	entry := &neocloudPending{
		BaseURL: baseURL, DeviceCode: authBody.DeviceCode, UserCode: authBody.UserCode,
		LoginURL: loginURL, ExpiresAt: timeutil.AddMillis(time.Now(), lifeMs), IntervalMs: intMs,
	}
	s.mu.Lock()
	if s.neoFl == nil {
		s.neoFl = make(map[string]*neocloudPending)
	}
	s.neoFl[userID] = entry
	s.mu.Unlock()
	return s.neoCloudEntryPublic(entry), nil
}

func (s *Service) neoCloudEntryPublic(e *neocloudPending) map[string]any {
	return map[string]any{
		"status":    "connecting",
		"type":      "neocloud",
		"loginUrl":  e.LoginURL,
		"userCode":  e.UserCode,
		"baseUrl":   e.BaseURL,
		"expiresAt": timeutil.FormatISO(e.ExpiresAt),
	}
}

func (s *Service) NeoCloudPoll(ctx context.Context, userID string) (map[string]any, error) {
	s.mu.Lock()
	entry := s.neoFl[userID]
	if entry != nil && !time.Now().Before(entry.ExpiresAt) {
		delete(s.neoFl, userID)
		entry = nil
	}
	if entry == nil {
		s.mu.Unlock()
		return nil, nil
	}
	if !entry.LastPollAt.IsZero() && time.Since(entry.LastPollAt).Milliseconds() < entry.IntervalMs {
		pub := s.neoCloudEntryPublic(entry)
		s.mu.Unlock()
		return pub, nil
	}
	entry.LastPollAt = time.Now()
	s.mu.Unlock()

	tb, _ := json.Marshal(map[string]any{"deviceCode": entry.DeviceCode})
	tctx, cancel := context.WithTimeout(ctx, time.Duration(max(5000, s.cfg().CloudHTTPTimeoutMs))*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(tctx, http.MethodPost, JoinURL(entry.BaseURL, "api/devices/token"), bytes.NewReader(tb))
	req.Header.Set("User-Agent", "NeoRecall")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	res, err := s.httpClient().Do(req)
	if err != nil {
		return s.neoCloudEntryPublic(entry), nil
	}
	defer res.Body.Close()
	if res.StatusCode == 428 || res.StatusCode == 429 {
		return s.neoCloudEntryPublic(entry), nil
	}
	if res.StatusCode == 403 {
		s.mu.Lock()
		delete(s.neoFl, userID)
		s.mu.Unlock()
		return nil, httperr.New(http.StatusForbidden, "CLOUD_LOGIN_DENIED", "The sign-in was declined in NeoCloud.")
	}
	if res.StatusCode == 410 {
		s.mu.Lock()
		delete(s.neoFl, userID)
		s.mu.Unlock()
		return nil, httperr.New(http.StatusGone, "CLOUD_LOGIN_EXPIRED", "The NeoCloud sign-in code expired. Start again.")
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "NeoCloud sign-in did not complete.")
	}
	var payload struct {
		Token string `json:"token"`
		User  struct {
			Username string `json:"username"`
		} `json:"user"`
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&payload); err != nil || payload.Token == "" || payload.User.Username == "" {
		s.mu.Lock()
		delete(s.neoFl, userID)
		s.mu.Unlock()
		return nil, httperr.New(http.StatusBadGateway, "CLOUD_LOGIN_FAILED", "NeoCloud sign-in did not complete.")
	}
	s.mu.Lock()
	delete(s.neoFl, userID)
	s.mu.Unlock()
	var devID *string
	if payload.Device.ID != "" {
		devID = &payload.Device.ID
	}
	if _, err := s.ConnectNeoCloud(ctx, userID, entry.BaseURL, payload.User.Username, payload.Token, devID); err != nil {
		return nil, err
	}
	return s.PublicAccount(ctx, userID)
}

func (s *Service) NeoCloudCancel(userID string) {
	s.mu.Lock()
	delete(s.neoFl, userID)
	s.mu.Unlock()
}

func (s *Service) PublicPending(userID string) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e, ok := s.ncFlow[userID]; ok && time.Since(e.StartedAt).Milliseconds() <= s.cfg().CloudLoginTimeoutMs {
		return map[string]any{"status": "connecting", "type": "nextcloud", "loginUrl": e.LoginURL, "baseUrl": e.BaseURL}
	}
	if e, ok := s.neoFl[userID]; ok && time.Now().Before(e.ExpiresAt) {
		return s.neoCloudEntryPublic(e)
	}
	return nil
}
