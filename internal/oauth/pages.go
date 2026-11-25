package oauth

import (
	"fmt"
	"html"
	"net/http"
	"net/url"
	"strings"
)

func esc(s string) string { return html.EscapeString(s) }

func formActionSources(redirectURI string) string {
	if redirectURI == "" {
		return "'self'"
	}
	u, err := url.Parse(redirectURI)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return "'self'"
	}
	return "'self' " + u.Scheme + "://" + u.Host
}

func renderPage(w http.ResponseWriter, status int, htmlBody, redirectURI string) {
	w.Header().Set("Cache-Control", "no-store, max-age=0")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action "+formActionSources(redirectURI)+"; base-uri 'none'; frame-ancestors 'none'")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(htmlBody))
}

func shellHTML(title, eyebrow, content string) string {
	return fmt.Sprintf(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>%s · NeoRecall</title><style>
  :root{color-scheme:light dark;--bg:#f4f1e8;--surface:rgba(253,252,248,.82);--surface-solid:#fdfcf8;--ink:#1c2117;--ink-2:#49503f;--ink-3:#7e8470;--line:rgba(28,33,23,.10);--line-2:rgba(28,33,23,.16);--gold:#b07d2b;--gold-soft:#c8943f;--rose:#a8506e;--sage:#5e6b4c;--btn:#1c2117;--btn-ink:#fdfcf8;--btn-hover:#2a3226;--shadow:0 18px 48px -24px rgba(28,33,23,.28), 0 8px 20px -12px rgba(28,33,23,.12);--sans:"Inter",ui-sans-serif,system-ui,sans-serif;--mono:"IBM Plex Mono",ui-monospace,monospace;}@media (prefers-color-scheme: dark){:root{--bg:#0e1511;--surface:rgba(23,31,26,.78);--surface-solid:#171f1a;--ink:#ecefe5;--ink-2:#aeb7a6;--ink-3:#7e8877;--line:rgba(224,240,224,.08);--line-2:rgba(224,240,224,.14);--gold:#e1b052;--gold-soft:#eac272;--rose:#d98aa6;--sage:#84ba87;--btn:#e1b052;--btn-ink:#0e1511;--btn-hover:#eac272;--shadow:0 24px 60px -28px rgba(0,0,0,.65), 0 10px 24px -16px rgba(0,0,0,.35);}}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:radial-gradient(circle at 12%% 8%%,color-mix(in srgb,var(--gold) 16%%,transparent),transparent 28%%),radial-gradient(circle at 88%% 18%%,color-mix(in srgb,var(--rose) 12%%,transparent),transparent 24%%),var(--bg);color:var(--ink);font-family:var(--sans);-webkit-font-smoothing:antialiased}.card{width:min(560px,100%%);padding:32px;border:1px solid var(--line);border-radius:24px;background:var(--surface);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);box-shadow:var(--shadow)}.eyebrow{font-family:var(--mono);font-size:11px;font-weight:600;letter-spacing:1.7px;text-transform:uppercase;color:var(--gold-soft)}.brand{display:flex;align-items:center;gap:12px;margin-bottom:28px}.mark{width:38px;height:38px;display:grid;place-items:center;border-radius:12px;background:color-mix(in srgb,var(--rose) 14%%,transparent);border:1px solid color-mix(in srgb,var(--rose) 35%%,transparent);color:var(--rose);font-weight:900;font-size:18px}.brand strong{font-size:18px}h1{margin:8px 0 10px;font-size:30px;line-height:1.1;font-weight:800;letter-spacing:-0.9px}p{color:var(--ink-2);line-height:1.6}.field{margin-top:16px}label{display:block;margin-bottom:8px;color:var(--ink);font-size:13px;font-weight:700}input{width:100%%;padding:13px 14px;border:1px solid var(--line-2);border-radius:12px;background:var(--surface-solid);color:var(--ink);font:inherit;outline:none;transition:border-color .2s,box-shadow .2s}input:focus{border-color:var(--gold);box-shadow:0 0 0 3px color-mix(in srgb,var(--gold) 12%%,transparent)}.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:28px}button{padding:12px 20px;border:1px solid transparent;border-radius:999px;font:inherit;font-weight:700;font-size:14px;cursor:pointer;transition:transform .2s,background .2s,border-color .2s}.primary{background:var(--btn);color:var(--btn-ink)}.primary:hover{background:var(--btn-hover);transform:translateY(-1px)}.secondary{background:transparent;color:var(--ink);border-color:var(--line-2)}.secondary:hover{transform:translateY(-1px)}.error{padding:12px 16px;margin-top:16px;border-radius:12px;background:color-mix(in srgb,#de5f70 12%%,transparent);border:1px solid color-mix(in srgb,#de5f70 35%%,transparent);color:#de5f70}.scope{display:flex;gap:14px;align-items:flex-start;padding:14px 0;border-top:1px solid var(--line)}.scope:first-child{border-top:0}.scope i{width:8px;height:8px;margin-top:7px;border-radius:50%%;background:var(--sage)}.scope b{display:block;color:var(--ink)}.scope span{display:block;color:var(--ink-3);font-size:13px;margin-top:4px}.redirect{padding:14px;border-radius:12px;background:var(--surface-solid);border:1px solid var(--line);color:var(--ink-3);font-family:var(--mono);font-size:12px;overflow-wrap:anywhere}
  </style></head><body><main class="card"><div class="brand"><div class="mark">R</div><div><div class="eyebrow">%s</div><strong>NeoRecall</strong></div></div>%s</main></body></html>`,
		esc(title), esc(eyebrow), content)
}

func renderSignIn(continuePath, errMsg, account string, requiresTwoFactor bool) string {
	errBox := ""
	if errMsg != "" {
		errBox = `<div class="error">` + esc(errMsg) + `</div>`
	}
	if requiresTwoFactor {
		return shellHTML("Two-factor authentication", "CONNECTION",
			`<h1>Two-factor authentication</h1><p>Enter the 6-digit code from your authenticator app, or a recovery code. Spaces and dashes are fine.</p>`+errBox+
				`<form method="post" action="/oauth/sign-in" autocomplete="on"><input type="hidden" name="continue" value="`+esc(continuePath)+`"><input type="hidden" name="account" value="`+esc(account)+`"><div class="field"><label for="two_factor_code">Authenticator or recovery code</label><input id="two_factor_code" name="two_factor_code" type="text" inputmode="text" autocomplete="one-time-code" maxlength="32" placeholder="123 456" spellcheck="false" autocorrect="off" autocapitalize="none" required autofocus></div><div class="actions"><button class="primary" type="submit">Verify and continue</button></div><div style="margin-top:14px;text-align:center;"><a href="/oauth/sign-in?continue=`+url.QueryEscape(continuePath)+`" style="color:var(--ink-2);font-size:12px;text-decoration:none;">← Back</a></div></form>`)
	}
	acctFocus, pwFocus := "autofocus", ""
	if account != "" {
		acctFocus, pwFocus = "", "autofocus"
	}
	return shellHTML("Sign in", "CONNECTION",
		`<h1>Sign in to approve access</h1><p>Use your NeoRecall account. Your password is verified by this NeoRecall server and is never sent to the application requesting access. If 2FA is enabled, you will be asked for a code next.</p>`+errBox+
			`<form method="post" action="/oauth/sign-in"><input type="hidden" name="continue" value="`+esc(continuePath)+`"><div class="field"><label for="account">Username or email</label><input id="account" name="account" autocomplete="username" value="`+esc(account)+`" required `+acctFocus+`></div><div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required `+pwFocus+`></div><div class="actions"><button class="primary" type="submit">Sign in securely</button></div></form>`)
}

func renderConsent(ar AuthorizeRequest) string {
	fields := []struct{ k, v string }{
		{"response_type", "code"},
		{"client_id", ar.Client.ID},
		{"redirect_uri", ar.RedirectURI},
		{"state", ar.State},
		{"scope", strings.Join(ar.Scopes, " ")},
		{"code_challenge", ar.CodeChallenge},
		{"code_challenge_method", "S256"},
	}
	var hidden strings.Builder
	for _, f := range fields {
		hidden.WriteString(`<input type="hidden" name="` + f.k + `" value="` + esc(f.v) + `">`)
	}
	labels := map[string][2]string{
		"search:read":     {"Search your recall", "Run local keyword and semantic searches without invoking NeoRecall Ask."},
		"memories:read":   {"Read memories", "Read memories, mini-memories, entities, and daily summaries."},
		"recordings:read": {"Read transcript evidence", "Read conversations and transcript evidence; audio is never available."},
	}
	var scopesHTML strings.Builder
	for _, sc := range ar.Scopes {
		title, desc := sc, ""
		if l, ok := labels[sc]; ok {
			title, desc = l[0], l[1]
		}
		scopesHTML.WriteString(`<div class="scope"><i></i><div><b>` + esc(title) + `</b><span>` + esc(desc) + `</span></div></div>`)
	}
	name := ar.Client.Name
	if ar.Client.Description == "companion:neoagent" {
		name = "NeoAgent"
	} else if name == "" {
		name = "this application"
	}
	intro := esc(name) + ` requests read-only access to this account. It cannot record audio, modify memories, or trigger NeoRecall’s LLM.`
	return shellHTML("Authorize "+name, "EXPLICIT CONSENT",
		`<h1>Connect `+esc(name)+`?</h1><p>`+intro+`</p><div>`+scopesHTML.String()+`</div><p>After approval, return credentials only to:</p><div class="redirect">`+esc(ar.RedirectURI)+`</div><form method="post" action="/oauth/authorize">`+hidden.String()+`<div class="actions"><button class="primary" type="submit" name="decision" value="approve">Authorize `+esc(name)+`</button><button class="secondary" type="submit" name="decision" value="deny">Deny</button></div></form>`)
}

func renderError(msg string) string {
	return shellHTML("Authorization error", "CONNECTION ERROR", `<h1>Authorization failed</h1><div class="error">`+esc(msg)+`</div>`)
}
