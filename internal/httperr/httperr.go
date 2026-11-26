// Package httperr defines NeoRecall's JSON error envelope, request ID middleware,
// JSON decode helpers, and request limiting.
package httperr

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/apperr"
	"github.com/NeoLabs-Systems/neolabs-go/httpx"
	"github.com/NeoLabs-Systems/neolabs-go/publicerr"
	"github.com/NeoLabs-Systems/neolabs-go/ratelimit"
	"github.com/google/uuid"
)

type ctxKey string

const (
	requestIDKey ctxKey = "neorecall.request_id"
	errCodeKey   ctxKey = "neorecall.err_code"
)

// Error is an HTTP failure serialized as {error: {code, message, details?, requestId}}.
type Error struct {
	Status  int
	Code    string
	Message string
	Details any
	Extra   map[string]any // optional extra error metadata (e.g. UserID on 2FA challenge)
}

func (e *Error) Error() string { return e.Message }

func New(status int, code, message string, details ...any) *Error {
	var d any
	if len(details) > 0 {
		d = details[0]
	}
	return &Error{Status: status, Code: code, Message: message, Details: d}
}

func RequestID(r *http.Request) string {
	if v, _ := r.Context().Value(requestIDKey).(string); v != "" {
		return v
	}
	return r.Header.Get("X-Request-Id")
}

// WithRequestID ensures every request has an X-Request-Id header and context value.
func WithRequestID() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := strings.TrimSpace(r.Header.Get("X-Request-Id"))
			if id == "" || len(id) > 128 {
				id = uuid.NewString()
			}
			w.Header().Set("X-Request-Id", id)
			ctx := context.WithValue(r.Context(), requestIDKey, id)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// WriteError writes NeoRecall's {error:{code,message,details?,requestId}} JSON payload.
func WriteError(w http.ResponseWriter, r *http.Request, log *slog.Logger, err error) {
	status := http.StatusInternalServerError
	code := "INTERNAL_ERROR"
	msg := "An internal error occurred."
	var details any

	var he *Error
	var maxErr *http.MaxBytesError
	if errors.As(err, &he) {
		status = he.Status
		if he.Code != "" {
			code = he.Code
		}
		msg = he.Message
		details = he.Details
	} else if ae, ok := apperr.As(err); ok {
		status = ae.Status
		if c := publicerr.PublicCode(ae.Code); c != "" {
			code = c
		}
		msg = publicerr.NonAdminMessage(publicerr.Failure{Message: ae.Message, Status: status, Code: ae.Code}, "", "")
	} else if errors.As(err, &maxErr) {
		status = http.StatusRequestEntityTooLarge
		code = "BODY_TOO_LARGE"
		msg = "Request body is too large."
	}

	if status >= 500 && log != nil {
		log.Error("request failed", "requestId", RequestID(r), "method", r.Method, "path", r.URL.Path, "error", err)
	}
	body := map[string]any{
		"code":      code,
		"message":   msg,
		"requestId": RequestID(r),
	}
	if details != nil {
		body["details"] = details
	}
	w.Header().Set("X-NeoRecall-Error-Code", code)
	httpx.WriteJSON(w, status, map[string]any{"error": body})
}

// DecodeJSON decodes a request JSON body into dst, mapping malformed/empty/oversized
// bodies cleanly to *Error.
func DecodeJSON(r *http.Request, dst any) error {
	if r.Body == nil {
		return New(http.StatusBadRequest, "INVALID_JSON", "Request body is required.")
	}
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			return maxErr
		}
		return New(http.StatusBadRequest, "INVALID_BODY", "Could not read request body.")
	}
	if len(strings.TrimSpace(string(raw))) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return New(http.StatusBadRequest, "INVALID_JSON", "Request body must be valid JSON.")
	}
	return nil
}

// ClientIP resolves the caller's IP (honouring X-Forwarded-For only when trustProxy is true).
func ClientIP(r *http.Request, trustProxy bool) string {
	return httpx.ClientIP(r, trustProxy)
}

// Limiter is neolabs-go's fixed-window limiter answering in NeoRecall's error
// envelope, usable from inside a handler.
type Limiter struct {
	code  string
	inner *ratelimit.Limiter
}

// NewLimiter allows limit requests per window for each key. A limit of zero
// switches the operation off.
func NewLimiter(window time.Duration, limit int, code string, keyFn func(*http.Request) string) *Limiter {
	l := &Limiter{code: code}
	if limit > 0 {
		l.inner = ratelimit.New(ratelimit.Config{
			Window: window, Max: limit, Key: keyFn,
			Message: map[string]any{"error": map[string]string{"code": code, "message": "Too many requests. Please try again later."}},
		})
	}
	return l
}

// Allow answers the request itself and returns false when it is over the limit.
func (l *Limiter) Allow(w http.ResponseWriter, r *http.Request, log *slog.Logger) bool {
	if l.inner == nil {
		WriteError(w, r, log, New(http.StatusTooManyRequests, l.code, "This operation is disabled."))
		return false
	}
	allowed := false
	l.inner.Middleware(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { allowed = true })).ServeHTTP(w, r)
	return allowed
}
