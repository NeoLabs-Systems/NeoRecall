package cloud

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
)

const singlePutMaxBytes int64 = 8 * 1024 * 1024

type SinkError struct {
	Code      string
	Status    int
	Retryable bool
	Message   string
}

func (e *SinkError) Error() string { return e.Message }

type PutOptions struct {
	CapturedAt      string
	ResumeUploadID  string
	OnUploadStarted func(uploadID string)
}

type Sink interface {
	Put(ctx context.Context, plainPath, remotePath string, opts PutOptions) error
}

// webDAVSink uploads unsealed plaintext files via write-only WebDAV MKCOL + PUT.
type webDAVSink struct {
	baseURL   string
	username  string
	password  string
	folder    string
	http      *http.Client
	timeoutMs int64
}

func (w *webDAVSink) davURL(parts []string) string {
	enc := make([]string, 0, 3+len(parts))
	enc = append(enc, "remote.php", "dav", "files", url.PathEscape(w.username))
	for _, p := range parts {
		enc = append(enc, strings.ReplaceAll(url.PathEscape(p), "'", "%27"))
	}
	return JoinURL(w.baseURL, strings.Join(enc, "/"))
}

func (w *webDAVSink) do(ctx context.Context, method, target string, body io.Reader, contentLen int64, extra map[string]string) (*http.Response, error) {
	t := time.Duration(max(5000, w.timeoutMs)) * time.Millisecond
	tctx, cancel := context.WithTimeout(ctx, t)
	defer cancel()
	req, err := http.NewRequestWithContext(tctx, method, target, body)
	if err != nil {
		return nil, err
	}
	if contentLen >= 0 {
		req.ContentLength = contentLen
	}
	auth := base64.StdEncoding.EncodeToString([]byte(w.username + ":" + w.password))
	req.Header.Set("Authorization", "Basic "+auth)
	req.Header.Set("User-Agent", "NeoRecall")
	for k, v := range extra {
		req.Header.Set(k, v)
	}
	return w.http.Do(req)
}

func (w *webDAVSink) mkcol(ctx context.Context, parts []string) error {
	res, err := w.do(ctx, "MKCOL", w.davURL(parts), nil, 0, nil)
	if err != nil {
		return &SinkError{Code: "CLOUD_MKCOL_FAILED", Retryable: true, Message: err.Error()}
	}
	res.Body.Close()
	if res.StatusCode == 200 || res.StatusCode == 201 || res.StatusCode == 405 || res.StatusCode == 409 || res.StatusCode == 301 {
		return nil
	}
	code := "CLOUD_MKCOL_FAILED"
	if res.StatusCode == 401 || res.StatusCode == 403 {
		code = "CLOUD_AUTH_FAILED"
	}
	return &SinkError{
		Code:      code,
		Status:    res.StatusCode,
		Retryable: res.StatusCode >= 500,
		Message:   fmt.Sprintf("Nextcloud MKCOL failed (%d).", res.StatusCode),
	}
}

func (w *webDAVSink) Put(ctx context.Context, plainPath, remotePath string, _ PutOptions) error {
	if crypto.IsSealedFile(plainPath) {
		return fmt.Errorf("refusing to upload sealed blob")
	}
	parts := []string{w.folder}
	for _, seg := range strings.Split(remotePath, "/") {
		if seg != "" {
			if seg == "." || seg == ".." {
				return fmt.Errorf("invalid remote path")
			}
			parts = append(parts, seg)
		}
	}
	for i := 1; i < len(parts); i++ {
		if err := w.mkcol(ctx, parts[:i]); err != nil {
			return err
		}
	}
	st, err := os.Stat(plainPath)
	if err != nil {
		return err
	}
	f, err := os.Open(plainPath)
	if err != nil {
		return err
	}
	defer f.Close()
	res, err := w.do(ctx, http.MethodPut, w.davURL(parts), f, st.Size(), map[string]string{
		"Content-Type": "application/octet-stream",
		"Overwrite":    "T",
	})
	if err != nil {
		return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
	}
	res.Body.Close()
	if res.StatusCode == 200 || res.StatusCode == 201 || res.StatusCode == 204 {
		return nil
	}
	code := "CLOUD_PUT_FAILED"
	if res.StatusCode == 401 || res.StatusCode == 403 {
		code = "CLOUD_AUTH_FAILED"
	}
	return &SinkError{
		Code:      code,
		Status:    res.StatusCode,
		Retryable: res.StatusCode >= 500,
		Message:   fmt.Sprintf("Nextcloud PUT failed (%d).", res.StatusCode),
	}
}

type neoCloudMe struct {
	Username   string
	QuotaUsed  *int64
	QuotaLimit *int64
}

type neoCloudSink struct {
	baseURL   string
	token     string
	folder    string
	http      *http.Client
	timeoutMs int64
}

func (n *neoCloudSink) request(ctx context.Context, method, p string, jsonBody any, binBody []byte, headers map[string]string) (*http.Response, error) {
	t := time.Duration(max(5000, n.timeoutMs)) * time.Millisecond
	tctx, cancel := context.WithTimeout(ctx, t)
	defer cancel()
	var body io.Reader
	if jsonBody != nil {
		jb, _ := json.Marshal(jsonBody)
		body = bytes.NewReader(jb)
	} else if binBody != nil {
		body = bytes.NewReader(binBody)
	}
	req, err := http.NewRequestWithContext(tctx, method, JoinURL(n.baseURL, p), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+n.token)
	req.Header.Set("User-Agent", "NeoRecall")
	req.Header.Set("Accept", "application/json")
	if jsonBody != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	return n.http.Do(req)
}

func (n *neoCloudSink) failure(res *http.Response, action string) *SinkError {
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	var parsed struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(raw, &parsed)
	se := &SinkError{
		Code:      "CLOUD_PUT_FAILED",
		Status:    res.StatusCode,
		Retryable: res.StatusCode >= 500 || res.StatusCode == 429 || res.StatusCode == 408,
		Message:   fmt.Sprintf("NeoCloud %s failed (%d).", action, res.StatusCode),
	}
	switch {
	case res.StatusCode == 401 || res.StatusCode == 403:
		se.Code = "CLOUD_AUTH_FAILED"
		se.Retryable = false
		se.Message = "NeoCloud no longer accepts NeoRecall. Reconnect NeoCloud in Settings."
	case res.StatusCode == 413 && parsed.Code == "QUOTA_EXCEEDED":
		se.Code = "CLOUD_QUOTA_EXCEEDED"
		se.Retryable = false
		se.Message = "Your NeoCloud storage is full. Free up space there; new copies resume after that."
	case res.StatusCode == 413:
		se.Code = "CLOUD_FILE_TOO_LARGE"
		se.Retryable = false
		se.Message = "This file is larger than your NeoCloud allows per file."
	case res.StatusCode == 507:
		se.Code = "CLOUD_SERVER_FULL"
		se.Retryable = true
		se.Message = "The NeoCloud server has no space left right now."
	case res.StatusCode == 422 && parsed.Code == "CHECKSUM_MISMATCH":
		se.Code = "CLOUD_CHECKSUM_MISMATCH"
		se.Retryable = true
		se.Message = "The copy arrived damaged at NeoCloud and was refused; it will be sent again."
	}
	return se
}

func (n *neoCloudSink) Me(ctx context.Context) (neoCloudMe, error) {
	res, err := n.request(ctx, http.MethodGet, "api/devices/me", nil, nil, nil)
	if err != nil {
		return neoCloudMe{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return neoCloudMe{}, n.failure(res, "account check")
	}
	var payload struct {
		User struct {
			Username string `json:"username"`
		} `json:"user"`
		Quota struct {
			Used  *int64 `json:"used"`
			Limit *int64 `json:"limit"`
		} `json:"quota"`
	}
	_ = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&payload)
	return neoCloudMe{Username: payload.User.Username, QuotaUsed: payload.Quota.Used, QuotaLimit: payload.Quota.Limit}, nil
}

func (n *neoCloudSink) Put(ctx context.Context, plainPath, remotePath string, opts PutOptions) error {
	if crypto.IsSealedFile(plainPath) {
		return fmt.Errorf("refusing to upload sealed blob")
	}
	parts := []string{n.folder}
	for _, seg := range strings.Split(remotePath, "/") {
		if seg == "." || seg == ".." {
			return fmt.Errorf("invalid remote path")
		}
		if seg != "" {
			parts = append(parts, seg)
		}
	}
	dir := strings.Join(parts[:len(parts)-1], "/")
	name := parts[len(parts)-1]

	f, err := os.Open(plainPath)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	size, err := io.Copy(h, f)
	if err != nil {
		return err
	}
	sumHex := hex.EncodeToString(h.Sum(nil))

	fRes, err := n.request(ctx, http.MethodPost, "api/folders", map[string]any{"parentId": "root", "path": dir}, nil, nil)
	if err != nil {
		return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
	}
	var folderObj struct {
		ID string `json:"id"`
	}
	if fRes.StatusCode != 200 && fRes.StatusCode != 201 {
		se := n.failure(fRes, "folder")
		fRes.Body.Close()
		return se
	}
	_ = json.NewDecoder(io.LimitReader(fRes.Body, 1<<20)).Decode(&folderObj)
	fRes.Body.Close()
	if folderObj.ID == "" {
		return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: "NeoCloud did not return backup folder id."}
	}

	dateHdrs := map[string]string{}
	if opts.CapturedAt != "" {
		dateHdrs["X-File-Created"] = opts.CapturedAt
		dateHdrs["X-File-Modified"] = opts.CapturedAt
	}

	if size <= singlePutMaxBytes {
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			return err
		}
		all, err := io.ReadAll(f)
		if err != nil {
			return err
		}
		q := url.Values{"parentId": {folderObj.ID}, "name": {name}, "conflict": {"rename"}}
		hdrs := map[string]string{"Content-Type": "application/octet-stream", "X-Content-SHA256": sumHex}
		for k, v := range dateHdrs {
			hdrs[k] = v
		}
		upRes, err := n.request(ctx, http.MethodPut, "api/upload?"+q.Encode(), nil, all, hdrs)
		if err != nil {
			return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
		}
		defer upRes.Body.Close()
		if upRes.StatusCode != 200 && upRes.StatusCode != 201 {
			return n.failure(upRes, "upload")
		}
		return nil
	}

	// Resumable chunked upload
	type uploadSess struct {
		ID            string `json:"id"`
		Name          string `json:"name"`
		Size          int64  `json:"size"`
		PartSize      int64  `json:"partSize"`
		ReceivedParts []int  `json:"receivedParts"`
	}
	var sess *uploadSess
	if opts.ResumeUploadID != "" {
		gRes, err := n.request(ctx, http.MethodGet, "api/uploads/"+url.PathEscape(opts.ResumeUploadID), nil, nil, nil)
		if err == nil {
			if gRes.StatusCode == 200 {
				var s uploadSess
				if json.NewDecoder(gRes.Body).Decode(&s) == nil && s.Size == size && s.Name == name {
					sess = &s
				}
			}
			gRes.Body.Close()
		}
	}
	if sess == nil {
		body := map[string]any{"parentId": folderObj.ID, "name": name, "size": size, "sha256": sumHex, "conflict": "rename"}
		if opts.CapturedAt != "" {
			body["createdAt"] = opts.CapturedAt
			body["modifiedAt"] = opts.CapturedAt
		}
		cRes, err := n.request(ctx, http.MethodPost, "api/uploads", body, nil, nil)
		if err != nil {
			return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
		}
		if cRes.StatusCode != 200 && cRes.StatusCode != 201 {
			se := n.failure(cRes, "upload")
			cRes.Body.Close()
			return se
		}
		var s uploadSess
		_ = json.NewDecoder(cRes.Body).Decode(&s)
		cRes.Body.Close()
		if s.ID == "" || s.PartSize <= 0 {
			return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: "NeoCloud did not start upload."}
		}
		sess = &s
		if opts.OnUploadStarted != nil {
			opts.OnUploadStarted(sess.ID)
		}
	}

	got := make(map[int]bool, len(sess.ReceivedParts))
	for _, p := range sess.ReceivedParts {
		got[p] = true
	}
	partCount := int((size + sess.PartSize - 1) / sess.PartSize)
	for idx := 0; idx < partCount; idx++ {
		if got[idx] {
			continue
		}
		off := int64(idx) * sess.PartSize
		length := min(sess.PartSize, size-off)
		buf := make([]byte, length)
		if _, err := f.ReadAt(buf, off); err != nil && err != io.EOF {
			return err
		}
		pRes, err := n.request(ctx, http.MethodPut, fmt.Sprintf("api/uploads/%s/parts/%d", url.PathEscape(sess.ID), idx), nil, buf, map[string]string{
			"Content-Type": "application/octet-stream",
		})
		if err != nil {
			return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
		}
		if pRes.StatusCode != 200 && pRes.StatusCode != 201 && pRes.StatusCode != 204 {
			se := n.failure(pRes, "upload")
			pRes.Body.Close()
			if pRes.StatusCode == 404 {
				se.Retryable = true
				if opts.OnUploadStarted != nil {
					opts.OnUploadStarted("")
				}
			}
			return se
		}
		pRes.Body.Close()
	}
	doneRes, err := n.request(ctx, http.MethodPost, "api/uploads/"+url.PathEscape(sess.ID)+"/complete", map[string]any{}, nil, nil)
	if err != nil {
		return &SinkError{Code: "CLOUD_PUT_FAILED", Retryable: true, Message: err.Error()}
	}
	defer doneRes.Body.Close()
	if doneRes.StatusCode != 200 && doneRes.StatusCode != 201 {
		se := n.failure(doneRes, "upload")
		if doneRes.StatusCode == 404 {
			se.Retryable = true
			if opts.OnUploadStarted != nil {
				opts.OnUploadStarted("")
			}
		}
		return se
	}
	return nil
}
