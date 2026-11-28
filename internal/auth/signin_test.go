package auth_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/lockout"
	"github.com/NeoLabs-Systems/neolabs-go/servicemail"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
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
	mux, svc, mail := resetStack(t, "https://recall.example", "")
	_, session, err := svc.Login(ctx, "ada", "Orchid-Tram-58-Lagoon", "", auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	if code, body := forgot(t, mux, "recall.example", "ada@example.com"); code != 200 {
		t.Fatal(code, body)
	}
	link := mailedLink(t, mail)
	if !strings.HasSuffix(link.Path, "/password/reset") {
		t.Fatal(link)
	}
	token := link.Query().Get("token")
	if page := resetSubmit(t, mux, token, "password"); !strings.Contains(page, "password") || strings.Contains(page, "has been changed") {
		t.Fatal("a weak password was accepted:", page)
	}
	if svc.AuthenticateSessionToken(ctx, session.Token) == nil {
		t.Fatal("a refused reset signed the account out")
	}
	resetSubmit(t, mux, token, "Copper-Vane-73-Meadow")
	if svc.AuthenticateSessionToken(ctx, session.Token) != nil {
		t.Fatal("old sessions stayed signed in")
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", "Copper-Vane-73-Meadow", "", auth.RequestContext{}); err != nil {
		t.Fatal("the link did not survive a weak attempt:", err)
	}
	resetSubmit(t, mux, token, "Orchid-Tram-58-Lagoon")
	if _, err := svc.AuthenticateCredentials(ctx, "ada", "Orchid-Tram-58-Lagoon", "", auth.RequestContext{}); err == nil {
		t.Fatal("a reset link worked twice")
	}
}

// mailedLink waits for the next email and returns its link.
func mailedLink(t *testing.T, mail sentMail) *url.URL {
	t.Helper()
	select {
	case m := <-mail:
		link, err := url.Parse(m.ActionURL)
		if err != nil || link.Query().Get("token") == "" {
			t.Fatal(m.ActionURL, err)
		}
		return link
	case <-time.After(5 * time.Second):
		t.Fatal("no email")
	}
	return nil
}

// resetSubmit posts the reset form and returns the page it answers with.
func resetSubmit(t *testing.T, mux http.Handler, token, password string) string {
	t.Helper()
	form := url.Values{"token": {token}, "password": {password}, "confirmPassword": {password}}
	req := httptest.NewRequest("POST", "/api/v1/auth/password/reset", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec.Body.String()
}

// forgot asks for a reset the way an unauthenticated caller can, with a Host
// header of its choosing.
func forgot(t *testing.T, mux http.Handler, host, account string) (int, string) {
	t.Helper()
	req := httptest.NewRequest("POST", "/api/v1/auth/password/forgot", strings.NewReader(`{"account":"`+account+`"}`))
	req.Host = host
	req.Header.Set("X-Forwarded-Host", host)
	req.Header.Set("X-Forwarded-Proto", "https")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

func resetStack(t *testing.T, publicURL, mailPublicURL string) (http.Handler, *auth.Service, sentMail) {
	t.Helper()
	mux, _, svc, _ := setupTestStack(t)
	email := "ada@example.com"
	if _, _, err := svc.Register(context.Background(), "ada", &email, "Orchid-Tram-58-Lagoon", auth.RequestContext{}); err != nil {
		t.Fatal(err)
	}
	mail := make(sentMail, 4)
	cfg := svc.Cfg()
	cfg.PublicURL = publicURL
	cfg.Mail = servicemail.Config{Enabled: true, TokenTTLHours: 1, PublicURL: mailPublicURL}
	svc.Cfg, svc.Mailer = cfgOf(cfg), mail
	return mux, svc, mail
}

func TestResetLinkIgnoresTheRequestHost(t *testing.T) {
	for _, tc := range []struct{ name, publicURL, mailURL, want string }{
		{"public URL", "https://recall.example", "", "https://recall.example/api/v1/auth/password/reset"},
		{"email public URL wins", "https://recall.example", "https://mail.recall.example/sub/", "https://mail.recall.example/sub/api/v1/auth/password/reset"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mux, _, mail := resetStack(t, tc.publicURL, tc.mailURL)
			if code, body := forgot(t, mux, "attacker.example", "ada"); code != 200 {
				t.Fatal(code, body)
			}
			select {
			case m := <-mail:
				link, err := url.Parse(m.ActionURL)
				if err != nil || link.Query().Get("token") == "" {
					t.Fatal(m.ActionURL, err)
				}
				if got := link.Scheme + "://" + link.Host + link.Path; got != tc.want || strings.Contains(m.ActionURL, "attacker") {
					t.Fatalf("reset link %q, want it under %q", m.ActionURL, tc.want)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("no email")
			}
		})
	}
}

func TestNoResetEmailWithoutAPublicURL(t *testing.T) {
	mux, svc, mail := resetStack(t, "", "")
	code, withoutURL := forgot(t, mux, "attacker.example", "ada")
	if code != 200 {
		t.Fatal(code, withoutURL)
	}
	select {
	case m := <-mail:
		t.Fatal("a reset email was sent without a configured public URL:", m.ActionURL)
	case <-time.After(300 * time.Millisecond):
	}
	if _, err := auth.MailLinkBase(svc.Cfg()); !errors.Is(err, auth.ErrNoMailLinkBase) {
		t.Fatal("expected ErrNoMailLinkBase, got", err)
	}
	// Unknown accounts get the same answer, so the refusal reveals nothing.
	if _, unknown := forgot(t, mux, "attacker.example", "nobody"); unknown != withoutURL {
		t.Fatalf("answers differ: %q vs %q", withoutURL, unknown)
	}
	if code, out := call(t, mux, "GET", "/api/v1/auth/options", "", nil); code != 200 || out["passwordReset"] != false {
		t.Fatal("password reset offered without a public URL:", code, out)
	}

	mux, _, _ = resetStack(t, "not a url", "")
	if _, out := call(t, mux, "GET", "/api/v1/auth/options", "", nil); out["passwordReset"] != false {
		t.Fatal("password reset offered with an invalid public URL:", out)
	}
	mux, _, _ = resetStack(t, "https://recall.example", "")
	if _, out := call(t, mux, "GET", "/api/v1/auth/options", "", nil); out["passwordReset"] != true {
		t.Fatal("password reset not offered with a public URL:", out)
	}
}

func TestTwoFactorSetupCannotReplaceAnEnabledSecret(t *testing.T) {
	ctx := context.Background()
	mux, _, svc, _ := setupTestStack(t)
	password := "Orchid-Tram-58-Lagoon"
	user, session, err := svc.Register(ctx, "ada", nil, password, auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	code, setup := call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, nil)
	if code != 200 {
		t.Fatal(code, setup)
	}
	secret := setup["secret"].(string)
	// Each accepted code has to be from a newer step than the last, so the
	// three uses below take the previous, current and next step's codes.
	at := steadyStep()
	prev, _ := totp.Code(secret, at.Add(-30*time.Second))
	now, _ := totp.Code(secret, at)
	next, _ := totp.Code(secret, at.Add(30*time.Second))
	if _, err := svc.ActivateTwoFactor(ctx, user.ID, prev); err != nil {
		t.Fatal(err)
	}

	code, out := call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, nil)
	if errBody, _ := out["error"].(map[string]any); code != 409 || errBody["code"] != "TWO_FACTOR_ALREADY_ENABLED" {
		t.Fatal("setup was allowed while 2FA is on:", code, out)
	}
	if code, _ := call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, map[string]string{"password": "wrong-password", "code": now}); code != 401 {
		t.Fatal("setup accepted a wrong password:", code)
	}
	if code, _ := call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, map[string]string{"password": password, "code": "000000"}); code != 401 {
		t.Fatal("setup accepted a wrong code:", code)
	}
	if st, err := svc.GetTwoFactorStatus(ctx, user.ID); err != nil || !st.Enabled {
		t.Fatal("refused setups turned 2FA off:", st, err)
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", password, now, auth.RequestContext{}); err != nil {
		t.Fatal("the original authenticator stopped working:", err)
	}

	code, out = call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, map[string]string{"password": password, "code": next})
	if code != 200 || out["secret"] == secret {
		t.Fatal("re-authenticated setup failed:", code, out)
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

// steadyStep returns now, after waiting out the end of a 30-second TOTP step
// when it is near, so codes worked out from it stay in the accepted window
// for the rest of a test.
func steadyStep() time.Time {
	if left := 30 - time.Now().Unix()%30; left < 8 {
		time.Sleep(time.Duration(left) * time.Second)
	}
	return time.Now()
}

func TestAnAcceptedCodeIsRefusedAgain(t *testing.T) {
	ctx := context.Background()
	mux, _, svc, _ := setupTestStack(t)
	password := "Orchid-Tram-58-Lagoon"
	user, session, err := svc.Register(ctx, "ada", nil, password, auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	_, setup := call(t, mux, "POST", "/api/v1/auth/2fa/setup", session.Token, nil)
	secret := setup["secret"].(string)
	at := steadyStep()
	prev, _ := totp.Code(secret, at.Add(-30*time.Second))
	now, _ := totp.Code(secret, at)
	if _, err := svc.ActivateTwoFactor(ctx, user.ID, prev); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", password, prev, auth.RequestContext{}); err == nil {
		t.Fatal("the code that turned 2FA on signed in again")
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", password, now, auth.RequestContext{}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.AuthenticateCredentials(ctx, "ada", password, now, auth.RequestContext{}); err == nil {
		t.Fatal("a sign-in code was accepted twice")
	}
	body := map[string]string{"password": password, "twoFactorCode": now}
	if code, out := call(t, mux, "POST", "/api/v1/auth/account/export", session.Token, body); code != 401 {
		t.Fatal("a used code re-authenticated an export:", code, out)
	}
}
