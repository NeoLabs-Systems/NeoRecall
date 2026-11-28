package auth_test

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/totp"
	"github.com/NeoLabs-Systems/neorecall/internal/auth"
)

const testPassword = "Orchid-Tram-58-Lagoon"

type member struct {
	id, token string
}

// accounts registers root (the first account, so admin), ada and bob.
func accounts(t *testing.T, svc *auth.Service) (root, ada, bob member) {
	t.Helper()
	register := func(name string) member {
		email := name + "@example.com"
		u, s, err := svc.Register(context.Background(), name, &email, testPassword, auth.RequestContext{})
		if err != nil {
			t.Fatal(err)
		}
		return member{u.ID, s.Token}
	}
	return register("root"), register("ada"), register("bob")
}

func send(t *testing.T, mux http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		r = bytes.NewReader(raw)
	}
	req := httptest.NewRequest(method, path, r)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var out struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return out.Error.Code
}

func addEntity(t *testing.T, db *dbx.DB, userID, name string) {
	t.Helper()
	if _, err := db.W.Exec(`INSERT INTO entities (id, user_id, kind, canonical_name_en, normalized_identity_key) VALUES (?, ?, 'person', ?, ?)`,
		userID+name, userID, name, name); err != nil {
		t.Fatal(err)
	}
}

// addImportFile stores a temporary import file for the account and returns
// its path.
func addImportFile(t *testing.T, db *dbx.DB, svc *auth.Service, userID string) string {
	t.Helper()
	path := filepath.Join(svc.Cfg().Paths.ImportTmp, userID+".part")
	if err := os.WriteFile(path, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := db.W.Exec(`INSERT INTO imports (id, user_id, original_name, content_type, total_size, sha256, part_size, state, temporary_path)
		VALUES (?, ?, 'a.m4a', 'audio/mp4', 5, ?, 5, 'uploading', ?)`, "imp-"+userID, userID, strings.Repeat("a", 64), path); err != nil {
		t.Fatal(err)
	}
	return path
}

func exists(t *testing.T, db *dbx.DB, userID string) bool {
	t.Helper()
	var n int
	if err := db.R.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}

func readZip(t *testing.T, body []byte) map[string]map[string]any {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]map[string]any{}
	for _, f := range zr.File {
		r, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		var doc map[string]any
		if err := json.NewDecoder(r).Decode(&doc); err != nil {
			t.Fatal(f.Name, err)
		}
		r.Close()
		out[f.Name] = doc
	}
	return out
}

func enableTwoFactor(t *testing.T, mux http.Handler, svc *auth.Service, m member) string {
	t.Helper()
	rec := send(t, mux, "POST", "/api/v1/auth/2fa/setup", m.token, nil)
	var setup struct{ Secret string }
	if err := json.Unmarshal(rec.Body.Bytes(), &setup); err != nil || setup.Secret == "" {
		t.Fatal(rec.Code, rec.Body.String())
	}
	code, _ := totp.Code(setup.Secret, time.Now())
	if _, err := svc.ActivateTwoFactor(context.Background(), m.id, code); err != nil {
		t.Fatal(err)
	}
	return setup.Secret
}

func TestExportNeedsTheSecretsAndHoldsOnlyTheAccountsData(t *testing.T) {
	mux, db, svc, _ := setupTestStack(t)
	_, ada, bob := accounts(t, svc)
	addEntity(t, db, ada.id, "Grace")
	addEntity(t, db, bob.id, "Linus")
	const path = "/api/v1/auth/account/export"

	if rec := send(t, mux, "GET", path, ada.token, nil); rec.Code != http.StatusMethodNotAllowed {
		t.Fatal("the export is still served without re-authentication:", rec.Code)
	}
	if rec := send(t, mux, "POST", path, ada.token, map[string]string{"password": "wrong"}); rec.Code != 401 || errorCode(t, rec) != "INVALID_PASSWORD" {
		t.Fatal(rec.Code, rec.Body.String())
	}
	rec := send(t, mux, "POST", path, ada.token, map[string]string{"password": testPassword})
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "application/zip" ||
		!strings.Contains(rec.Header().Get("Content-Disposition"), `filename="neorecall-ada-`) {
		t.Fatal(rec.Code, rec.Header(), rec.Body.String())
	}
	files := readZip(t, rec.Body.Bytes())
	manifest, data := files["manifest.json"], files["data.json"]
	if manifest["userId"] != ada.id || manifest["kind"] != "neorecall-user-backup" ||
		manifest["counts"].(map[string]any)["entities"] != float64(1) {
		t.Fatal(manifest)
	}
	if data["account"].(map[string]any)["username"] != "ada" {
		t.Fatal(data["account"])
	}
	raw, _ := json.Marshal(data)
	if !strings.Contains(string(raw), "Grace") || strings.Contains(string(raw), "Linus") ||
		strings.Contains(string(raw), bob.id) || strings.Contains(string(raw), "password") {
		t.Fatal("the export holds data it must not:", string(raw))
	}

	enableTwoFactor(t, mux, svc, ada)
	if rec := send(t, mux, "POST", path, ada.token, map[string]string{"password": testPassword}); rec.Code != 401 || errorCode(t, rec) != "TWO_FACTOR_REQUIRED" {
		t.Fatal("the export skipped the second factor:", rec.Code, rec.Body.String())
	}
}

func TestDeleteAccountErasesOnlyThatAccount(t *testing.T) {
	mux, db, svc, _ := setupTestStack(t)
	root, ada, bob := accounts(t, svc)
	adaFile, bobFile := addImportFile(t, db, svc, ada.id), addImportFile(t, db, svc, bob.id)
	addEntity(t, db, bob.id, "Linus")
	ctx := context.Background()

	if rec := send(t, mux, "DELETE", "/api/v1/auth/account", ada.token, map[string]string{"password": "wrong"}); rec.Code != 401 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if !exists(t, db, ada.id) {
		t.Fatal("a refused deletion erased the account")
	}
	if rec := send(t, mux, "DELETE", "/api/v1/auth/account", root.token, map[string]string{"password": testPassword}); rec.Code != 403 || errorCode(t, rec) != "ADMIN_SELF_DELETE" {
		t.Fatal("an admin deleted itself:", rec.Code, rec.Body.String())
	}
	if rec := send(t, mux, "DELETE", "/api/v1/auth/account", ada.token, map[string]string{"password": testPassword}); rec.Code != 204 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if exists(t, db, ada.id) || svc.AuthenticateSessionToken(ctx, ada.token) != nil {
		t.Fatal("the account or its session survived")
	}
	if _, err := os.Stat(adaFile); !os.IsNotExist(err) {
		t.Fatal("the account's file survived:", err)
	}
	var entities int
	_ = db.R.QueryRow(`SELECT COUNT(*) FROM entities WHERE user_id = ?`, bob.id).Scan(&entities)
	if _, err := os.Stat(bobFile); err != nil || entities != 1 || svc.AuthenticateSessionToken(ctx, bob.token) == nil {
		t.Fatal("deleting one account touched another:", err, entities)
	}
}

func TestAdminDeleteKeepsItsGuards(t *testing.T) {
	mux, db, svc, _ := setupTestStack(t)
	root, ada, bob := accounts(t, svc)
	ctx := context.Background()
	del := func(as member, target string) *httptest.ResponseRecorder {
		return send(t, mux, "DELETE", "/api/v1/admin/users/"+target, as.token, nil)
	}

	if rec := del(ada, bob.id); rec.Code != 403 || !exists(t, db, bob.id) {
		t.Fatal("a non-admin deleted an account:", rec.Code)
	}
	if rec := del(root, root.id); rec.Code != 400 || errorCode(t, rec) != "CANNOT_DELETE_SELF" {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if _, err := svc.GrantAdmin(ctx, "ada", "cli"); err != nil {
		t.Fatal(err)
	}
	if rec := del(root, ada.id); rec.Code != 403 || errorCode(t, rec) != "ADMIN_ACCOUNT" || !exists(t, db, ada.id) {
		t.Fatal("an admin account was deleted:", rec.Code, rec.Body.String())
	}
	if rec := del(root, "no-such-user"); rec.Code != 404 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if rec := del(root, bob.id); rec.Code != 204 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if exists(t, db, bob.id) || svc.AuthenticateSessionToken(ctx, bob.token) != nil {
		t.Fatal("the deleted account or its session survived")
	}
	var logged int
	_ = db.R.QueryRow(`SELECT COUNT(*) FROM audit_log WHERE action = 'admin.user_deleted' AND actor_id = ?`, root.id).Scan(&logged)
	if logged != 1 {
		t.Fatal("the admin deletion was not audited")
	}
}

func sessionList(t *testing.T, mux http.Handler, token string) []map[string]any {
	t.Helper()
	rec := send(t, mux, "GET", "/api/v1/auth/sessions", token, nil)
	var out struct{ Sessions []map[string]any }
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &out) != nil {
		t.Fatal(rec.Code, rec.Body.String())
	}
	return out.Sessions
}

func TestSessionsListRevokeAndSignOutEverywhere(t *testing.T) {
	mux, _, svc, _ := setupTestStack(t)
	_, ada, bob := accounts(t, svc)
	ctx := context.Background()
	_, laptop, err := svc.Login(ctx, "ada", testPassword, "", auth.RequestContext{UserAgent: "Laptop"})
	if err != nil {
		t.Fatal(err)
	}

	list := sessionList(t, mux, ada.token)
	var current, other string
	for _, s := range list {
		if s["current"] == true {
			current = s["id"].(string)
		} else if s["userAgent"] == "Laptop" && s["createdAt"] != nil {
			other = s["id"].(string)
		}
	}
	if len(list) != 2 || current == "" || other == "" {
		t.Fatal(list)
	}
	if rec := send(t, mux, "DELETE", "/api/v1/auth/sessions/"+current, ada.token, nil); rec.Code != 400 || errorCode(t, rec) != "CURRENT_SESSION" {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if rec := send(t, mux, "DELETE", "/api/v1/auth/sessions/"+other, bob.token, nil); rec.Code != 404 {
		t.Fatal("another account ended this session:", rec.Code)
	}
	if svc.AuthenticateSessionToken(ctx, laptop.Token) == nil {
		t.Fatal("another account's revoke ended the session")
	}
	if rec := send(t, mux, "DELETE", "/api/v1/auth/sessions/"+other, ada.token, nil); rec.Code != 200 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if svc.AuthenticateSessionToken(ctx, laptop.Token) != nil || len(sessionList(t, mux, ada.token)) != 1 {
		t.Fatal("the revoked session still works")
	}
	if rec := send(t, mux, "POST", "/api/v1/auth/logout-all", ada.token, nil); rec.Code != 204 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if svc.AuthenticateSessionToken(ctx, ada.token) != nil || svc.AuthenticateSessionToken(ctx, bob.token) == nil {
		t.Fatal("sign out everywhere ended the wrong sessions")
	}
}

func emailState(t *testing.T, mux http.Handler, token string) map[string]any {
	t.Helper()
	rec := send(t, mux, "GET", "/api/v1/auth/email", token, nil)
	out := map[string]any{}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &out) != nil {
		t.Fatal(rec.Code, rec.Body.String())
	}
	return out
}

func confirmSubmit(t *testing.T, mux http.Handler, token string) string {
	t.Helper()
	req := httptest.NewRequest("POST", "/api/v1/auth/email/confirm", strings.NewReader(url.Values{"token": {token}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec.Body.String()
}

func TestEmailChangeIsConfirmedByItsLink(t *testing.T) {
	mux, svc, mail := resetStack(t, "https://recall.example", "")
	ctx := context.Background()
	_, ada, err := svc.Login(ctx, "ada", testPassword, "", auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	if st := emailState(t, mux, ada.Token); st["email"] != "ada@example.com" || st["pendingEmail"] != nil || st["canConfirm"] != true {
		t.Fatal(st)
	}
	change := map[string]string{"email": "Ada.New@example.com"}
	if rec := send(t, mux, "PUT", "/api/v1/auth/email", ada.Token, change); rec.Code != 401 {
		t.Fatal("the address changed without the password:", rec.Code)
	}
	change["password"] = testPassword
	rec := send(t, mux, "PUT", "/api/v1/auth/email", ada.Token, change)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"pendingEmail":"ada.new@example.com"`) {
		t.Fatal(rec.Code, rec.Body.String())
	}
	token := mailedLink(t, mail).Query().Get("token")
	if st := emailState(t, mux, ada.Token); st["email"] != "ada@example.com" || st["pendingEmail"] != "ada.new@example.com" {
		t.Fatal("the address changed before it was confirmed:", st)
	}

	page := send(t, mux, "GET", "/api/v1/auth/email/confirm?token="+url.QueryEscape(token), "", nil)
	if page.Code != 200 || emailState(t, mux, ada.Token)["email"] != "ada@example.com" {
		t.Fatal("opening the link spent it:", page.Code)
	}
	if body := confirmSubmit(t, mux, token); !strings.Contains(body, "ada.new@example.com") {
		t.Fatal(body)
	}
	st := emailState(t, mux, ada.Token)
	if st["email"] != "ada.new@example.com" || st["emailVerified"] != true || st["pendingEmail"] != nil {
		t.Fatal(st)
	}
	if body := confirmSubmit(t, mux, token); strings.Contains(body, "now uses") {
		t.Fatal("a confirmation link worked twice")
	}

	// Another account cannot claim the address.
	email := "bob@example.com"
	_, bob, err := svc.Register(ctx, "bob", &email, testPassword, auth.RequestContext{})
	if err != nil {
		t.Fatal(err)
	}
	if rec := send(t, mux, "PUT", "/api/v1/auth/email", bob.Token, map[string]string{"email": "ada.new@example.com", "password": testPassword}); rec.Code != 409 || errorCode(t, rec) != "EMAIL_TAKEN" {
		t.Fatal(rec.Code, rec.Body.String())
	}
}

func TestEmailChangeWithoutServiceEmailSetsItUnconfirmed(t *testing.T) {
	mux, _, svc, _ := setupTestStack(t)
	_, ada, _ := accounts(t, svc)
	rec := send(t, mux, "PUT", "/api/v1/auth/email", ada.token, map[string]string{"email": "ada@new.example", "password": testPassword})
	if rec.Code != 200 {
		t.Fatal(rec.Code, rec.Body.String())
	}
	if st := emailState(t, mux, ada.token); st["email"] != "ada@new.example" || st["emailVerified"] != false || st["canConfirm"] != false {
		t.Fatal(st)
	}
}
