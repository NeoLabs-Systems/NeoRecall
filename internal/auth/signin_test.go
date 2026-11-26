package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/lockout"
	"github.com/NeoLabs-Systems/neolabs-go/servicemail"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
)

type sentMail chan servicemail.Message

func (s sentMail) Send(_ context.Context, _ string, m servicemail.Message) error {
	s <- m
	return nil
}

func call(t *testing.T, mux http.Handler, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest(method, path, bytes.NewReader(raw))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	out := map[string]any{}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestQRSignInGivesTheOtherDeviceASession(t *testing.T) {
	mux, _, svc, _ := setupTestStack(t)
	user, phone, err := svc.Register(context.Background(), "ada", nil, "Orchid-Tram-58-Lagoon", auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	code, challenge := call(t, mux, "POST", "/api/v1/auth/qr-login/challenge", "", map[string]any{})
	if code != 200 {
		t.Fatal(code, challenge)
	}
	payload, err := url.Parse(challenge["qrPayload"].(string))
	if err != nil || payload.Scheme != "neorecall" {
		t.Fatal(payload, err)
	}
	id, poll := challenge["challengeId"].(string), map[string]any{"token": challenge["pollToken"]}
	claim := "/api/v1/auth/qr-login/challenge/" + id + "/claim"
	if code, _ := call(t, mux, "POST", claim, "", poll); code != 409 {
		t.Fatal("claimed before approval:", code)
	}
	scan := map[string]any{"challengeId": id, "secret": payload.Query().Get("secret")}
	if code, _ := call(t, mux, "POST", "/api/v1/account/qr-login/approve", "", scan); code != 401 {
		t.Fatal("approved without a session:", code)
	}
	if code, out := call(t, mux, "POST", "/api/v1/account/qr-login/approve", phone.Token, scan); code != 200 {
		t.Fatal(code, out)
	}
	code, claimed := call(t, mux, "POST", claim, "", poll)
	if code != 200 || claimed["user"].(map[string]any)["id"] != user.ID {
		t.Fatal(code, claimed)
	}
	token := claimed["session"].(map[string]any)["token"].(string)
	if svc.AuthenticateSessionToken(context.Background(), token) == nil {
		t.Fatal("the claimed session does not work")
	}
	if code, _ := call(t, mux, "POST", claim, "", poll); code == 200 {
		t.Fatal("a challenge was claimed twice")
	}
}

func TestPasswordResetLinkChangesThePasswordOnce(t *testing.T) {
	ctx := context.Background()
	_, _, svc, _ := setupTestStack(t)
	email := "ada@example.com"
	_, session, err := svc.Register(ctx, "ada", &email, "Orchid-Tram-58-Lagoon", auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	mail := make(sentMail, 1)
	cfg := svc.Cfg()
	cfg.Mail = servicemail.Config{Enabled: true, TokenTTLHours: 1}
	svc.Cfg, svc.Mailer = cfgOf(cfg), mail

	if err := svc.RequestPasswordReset(ctx, email, "https://recall.example"); err != nil {
		t.Fatal(err)
	}
	var link *url.URL
	select {
	case m := <-mail:
		link, err = url.Parse(m.ActionURL)
	case <-time.After(time.Second):
		t.Fatal("no email")
	}
	if err != nil || !strings.HasSuffix(link.Path, "/password/reset") {
		t.Fatal(link, err)
	}
	token := link.Query().Get("token")
	if err := svc.ResetPassword(ctx, token, "password"); err == nil {
		t.Fatal("a weak password was accepted")
	}
	if err := svc.ResetPassword(ctx, token, "Copper-Vane-73-Meadow"); err != nil {
		t.Fatal("the link did not survive a weak attempt:", err)
	}
	if svc.AuthenticateSessionToken(ctx, session.Token) != nil {
		t.Fatal("old sessions stayed signed in")
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", "Copper-Vane-73-Meadow", "", auth.RequestContext{}); err != nil {
		t.Fatal(err)
	}
	if err := svc.ResetPassword(ctx, token, "Orchid-Tram-58-Lagoon"); err == nil {
		t.Fatal("a reset link worked twice")
	}
}

func TestWrongConfirmationsCountAndLockTheAccount(t *testing.T) {
	ctx := context.Background()
	_, db, svc, _ := setupTestStack(t)
	user, _, err := svc.Register(ctx, "ada", nil, "Orchid-Tram-58-Lagoon", auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	key := lockout.ConfirmKey(user.ID)
	_ = svc.ChangePassword(ctx, user.ID, "wrong", "Copper-Vane-73-Meadow")
	var counted int
	if err := db.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM login_failures WHERE account_key = ?`, key).Scan(&counted); err != nil || counted != 1 {
		t.Fatal("a wrong password was not counted:", counted, err)
	}
	// The backoff between tries is real time, so the failures are written
	// directly: how long a password hash takes must not decide this test.
	store := lockout.Store{DB: db.W}
	for range 10 {
		if err := store.Record(ctx, key, "password"); err != nil {
			t.Fatal(err)
		}
	}
	err = svc.ChangePassword(ctx, user.ID, "Orchid-Tram-58-Lagoon", "Copper-Vane-73-Meadow")
	if err == nil || !strings.Contains(err.Error(), "Too many wrong") {
		t.Fatal("expected a lockout, got", err)
	}
}

func cfgOf(c config.Config) func() config.Config { return func() config.Config { return c } }
