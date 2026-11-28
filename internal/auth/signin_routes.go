package auth

import (
	"net/http"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/qrlogin"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
)

const passwordResetPath = "/api/v1/auth/password/reset"

func (rt *Routes) mountSignIn(mux *http.ServeMux) {
	reqSess := func(h http.HandlerFunc) http.Handler {
		return rt.Auth.RequireAuth(rt.Auth.RequireSession(h))
	}
	mux.HandleFunc("GET /api/v1/auth/options", rt.handleOptions)

	mux.HandleFunc("POST /api/v1/auth/qr-login/challenge", rt.handleQRChallenge)
	mux.HandleFunc("POST /api/v1/auth/qr-login/challenge/{id}/status", rt.handleQRStatus)
	mux.HandleFunc("POST /api/v1/auth/qr-login/challenge/{id}/cancel", rt.handleQRCancel)
	mux.HandleFunc("POST /api/v1/auth/qr-login/challenge/{id}/claim", rt.handleQRClaim)
	mux.Handle("POST /api/v1/account/qr-login/resolve", reqSess(rt.handleQRResolve))
	mux.Handle("POST /api/v1/account/qr-login/decline", reqSess(rt.handleQRDecline))
	mux.Handle("POST /api/v1/account/qr-login/approve", reqSess(rt.handleQRApprove))
}

// baseURL is how clients reach this server: the public URL when configured,
// otherwise the address the request came in on. It may only answer the
// requester itself; anything emailed uses MailLinkBase instead.
func (rt *Routes) baseURL(r *http.Request) string {
	c := rt.Svc.cfg()
	if c.PublicURL != "" {
		return strings.TrimRight(c.PublicURL, "/")
	}
	scheme := "http"
	if r.TLS != nil || c.TrustProxy && strings.EqualFold(r.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "https"
	}
	return scheme + "://" + r.Host
}

func (rt *Routes) handleOptions(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"passwordReset": rt.Svc.PasswordResetAvailable(), "registration": rt.Svc.cfg().RegistrationEnabled})
}

func (rt *Routes) handleQRChallenge(w http.ResponseWriter, r *http.Request) {
	if !rt.qrChallengeL.Allow(w, r, rt.Log) {
		return
	}
	var body struct {
		RequestMetadata any `json:"requestMetadata"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	rc := rt.reqCtx(r)
	userAgent := rc.UserAgent
	if len(userAgent) > 500 {
		userAgent = userAgent[:500]
	}
	out, err := rt.Svc.CreateQRChallenge(r.Context(), rt.baseURL(r), qrlogin.Request{
		UserAgent: userAgent, IPAddress: rc.IPAddress, Metadata: body.RequestMetadata,
	})
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, out)
}

// qrToken reads the poll token only the signing-in screen holds.
func (rt *Routes) qrToken(w http.ResponseWriter, r *http.Request) (token, known string, ok bool) {
	if !rt.qrPollL.Allow(w, r, rt.Log) {
		return "", "", false
	}
	var body struct {
		Token       string `json:"token"`
		KnownStatus string `json:"knownStatus"`
	}
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return "", "", false
	}
	if strings.TrimSpace(body.Token) == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "QR login poll token is required."))
		return "", "", false
	}
	return strings.TrimSpace(body.Token), strings.TrimSpace(body.KnownStatus), true
}

func (rt *Routes) handleQRStatus(w http.ResponseWriter, r *http.Request) {
	token, known, ok := rt.qrToken(w, r)
	if !ok {
		return
	}
	var poll *qrlogin.Poll
	var err error
	if known == "" {
		poll, err = rt.Svc.QR.PollStatus(r.Context(), r.PathValue("id"), token)
	} else {
		// Held open until the status changes, so the screen hears of a scan or
		// approval at once.
		poll, err = rt.Svc.QR.WaitForChange(r.Context(), r.PathValue("id"), token, known, qrlogin.LongPollMax)
	}
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	if r.Context().Err() == nil {
		httpx.WriteJSON(w, http.StatusOK, poll)
	}
}

func (rt *Routes) handleQRCancel(w http.ResponseWriter, r *http.Request) {
	token, _, ok := rt.qrToken(w, r)
	if !ok {
		return
	}
	if err := rt.Svc.QR.Cancel(r.Context(), r.PathValue("id"), token); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
}

func (rt *Routes) handleQRClaim(w http.ResponseWriter, r *http.Request) {
	token, _, ok := rt.qrToken(w, r)
	if !ok {
		return
	}
	user, session, err := rt.Svc.ClaimQRLogin(r.Context(), r.PathValue("id"), token, rt.reqCtx(r))
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"user": user, "session": session})
}

type qrScan struct {
	ChallengeID      string `json:"challengeId"`
	Secret           string `json:"secret"`
	ScannerMetadata  any    `json:"scannerMetadata"`
	ApprovalMetadata any    `json:"approvalMetadata"`
}

func (rt *Routes) qrScanned(w http.ResponseWriter, r *http.Request) (qrScan, bool) {
	var body qrScan
	if err := httperr.DecodeJSON(r, &body); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return body, false
	}
	body.ChallengeID, body.Secret = strings.TrimSpace(body.ChallengeID), strings.TrimSpace(body.Secret)
	if body.ChallengeID == "" || body.Secret == "" {
		httperr.WriteError(w, r, rt.Log, httperr.New(http.StatusBadRequest, "VALIDATION_ERROR", "Challenge id and QR secret are required."))
		return body, false
	}
	return body, true
}

func (rt *Routes) handleQRResolve(w http.ResponseWriter, r *http.Request) {
	body, ok := rt.qrScanned(w, r)
	if !ok {
		return
	}
	c, err := rt.Svc.QR.MarkScanned(r.Context(), body.ChallengeID, body.Secret, body.ScannerMetadata)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, c)
}

func (rt *Routes) handleQRDecline(w http.ResponseWriter, r *http.Request) {
	body, ok := rt.qrScanned(w, r)
	if !ok {
		return
	}
	if err := rt.Svc.QR.Decline(r.Context(), body.ChallengeID, body.Secret); err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]bool{"success": true})
}

func (rt *Routes) handleQRApprove(w http.ResponseWriter, r *http.Request) {
	body, ok := rt.qrScanned(w, r)
	if !ok {
		return
	}
	c, err := rt.Svc.ApproveQRLogin(r.Context(), FromContext(r.Context()), body.ChallengeID, body.Secret, body.ApprovalMetadata)
	if err != nil {
		httperr.WriteError(w, r, rt.Log, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, c)
}
