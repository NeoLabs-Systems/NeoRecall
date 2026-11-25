package cloud

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/ssrf"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/settings"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

var folderPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

type Account struct {
	ID                string  `json:"id"`
	UserID            string  `json:"userId"`
	Type              string  `json:"type"`
	BaseURL           string  `json:"baseUrl"`
	Username          string  `json:"username"`
	Folder            string  `json:"folder"`
	AudioEnabled      bool    `json:"audioEnabled"`
	DataBackupEnabled bool    `json:"dataBackupEnabled"`
	Status            string  `json:"status"`
	LastError         *string `json:"lastError"`
	LastAudioUploadAt *string `json:"lastAudioUploadAt"`
	LastDataBackupAt  *string `json:"lastDataBackupAt"`
	RemoteDeviceID    *string `json:"remoteDeviceId"`
	QuotaUsed         *int64  `json:"quotaUsed"`
	QuotaLimit        *int64  `json:"quotaLimit"`
	CreatedAt         string  `json:"createdAt"`
	UpdatedAt         string  `json:"updatedAt"`
}

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	Jobs      *jobs.Service
	Settings  *settings.Service
	HTTP      *http.Client
	Log       *slog.Logger

	mu     sync.Mutex
	ncFlow map[string]*nextcloudPending
	neoFl  map[string]*neocloudPending
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
	return ssrf.NewClient(ssrf.Options{AllowPrivate: true})
}

func (s *Service) encryptSecret(typ, cred string) (string, error) {
	key, err := s.MasterKey()
	if err != nil {
		return "", err
	}
	var payload []byte
	if typ == "neocloud" {
		payload, _ = json.Marshal(map[string]any{"version": 2, "type": typ, "token": cred})
	} else {
		payload, _ = json.Marshal(map[string]any{"version": 1, "appPassword": cred})
	}
	return crypto.EncryptString(key, string(payload))
}

func (s *Service) decryptSecret(enc string) (string, error) {
	key, err := s.MasterKey()
	if err != nil {
		return "", err
	}
	raw, err := crypto.DecryptString(key, enc)
	if err != nil {
		return "", err
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(raw), &parsed); err != nil {
		return "", err
	}
	if typ, _ := parsed["type"].(string); typ == "neocloud" {
		if tok, ok := parsed["token"].(string); ok {
			return tok, nil
		}
	}
	if ap, ok := parsed["appPassword"].(string); ok {
		return ap, nil
	}
	return "", fmt.Errorf("cloud secret is malformed")
}

func (s *Service) GetAccount(ctx context.Context, userID string) (*Account, string, error) {
	row := s.DB.R.QueryRowContext(ctx, `SELECT id, user_id, type, base_url, username, secret_encrypted,
		folder, audio_enabled, data_backup_enabled, status, last_error, last_audio_upload_at,
		last_data_backup_at, remote_device_id, quota_used, quota_limit, created_at, updated_at
		FROM cloud_accounts WHERE user_id=?`, userID)
	var a Account
	var secEnc string
	var ae, dbe int
	var le, la, ld, rdid sql.NullString
	var qu, ql sql.NullInt64
	if err := row.Scan(&a.ID, &a.UserID, &a.Type, &a.BaseURL, &a.Username, &secEnc,
		&a.Folder, &ae, &dbe, &a.Status, &le, &la, &ld, &rdid, &qu, &ql, &a.CreatedAt, &a.UpdatedAt); err != nil {
		if err == sql.ErrNoRows {
			return nil, "", nil
		}
		return nil, "", err
	}
	a.AudioEnabled = ae == 1
	a.DataBackupEnabled = dbe == 1
	if le.Valid {
		a.LastError = &le.String
	}
	if la.Valid {
		a.LastAudioUploadAt = &la.String
	}
	if ld.Valid {
		a.LastDataBackupAt = &ld.String
	}
	if rdid.Valid {
		a.RemoteDeviceID = &rdid.String
	}
	if qu.Valid {
		v := qu.Int64
		a.QuotaUsed = &v
	}
	if ql.Valid {
		v := ql.Int64
		a.QuotaLimit = &v
	}
	return &a, secEnc, nil
}

func (s *Service) pendingCount(ctx context.Context, userID string) int {
	var c1, c2 int
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM cloud_archive_items WHERE user_id=? AND state IN ('queued','uploading')`, userID).Scan(&c1)
	_ = s.DB.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM cloud_recording_assemblies WHERE user_id=? AND state='assembling'`, userID).Scan(&c2)
	return c1 + c2
}

func (s *Service) PublicAccount(ctx context.Context, userID string) (map[string]any, error) {
	a, _, err := s.GetAccount(ctx, userID)
	if err != nil {
		return nil, err
	}
	if a == nil {
		return map[string]any{
			"connected":         false,
			"status":            "disconnected",
			"type":              nil,
			"audioEnabled":      false,
			"dataBackupEnabled": false,
			"pendingCount":      0,
		}, nil
	}
	res := map[string]any{
		"connected":         true,
		"type":              a.Type,
		"baseUrl":           a.BaseURL,
		"username":          a.Username,
		"folder":            a.Folder,
		"audioEnabled":      a.AudioEnabled,
		"dataBackupEnabled": a.DataBackupEnabled,
		"status":            a.Status,
		"lastError":         a.LastError,
		"lastAudioUploadAt": a.LastAudioUploadAt,
		"lastDataBackupAt":  a.LastDataBackupAt,
		"pendingCount":      s.pendingCount(ctx, userID),
	}
	if a.Type == "neocloud" && a.QuotaUsed != nil {
		lim := int64(-1)
		if a.QuotaLimit != nil {
			lim = *a.QuotaLimit
		}
		res["quota"] = map[string]any{"used": *a.QuotaUsed, "limit": lim}
	}
	return res, nil
}

type ConnectInput struct {
	Type       string
	BaseURL    string
	Username   string
	Credential string
	DeviceID   *string
	QuotaUsed  *int64
	QuotaLimit *int64
}

func (s *Service) UpsertConnected(ctx context.Context, userID string, in ConnectInput) (*Account, error) {
	sec, err := s.encryptSecret(in.Type, in.Credential)
	if err != nil {
		return nil, err
	}
	now := timeutil.NowISO()
	ex, _, err := s.GetAccount(ctx, userID)
	if err != nil {
		return nil, err
	}
	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if ex != nil {
		_, err = tx.ExecContext(ctx, `UPDATE cloud_accounts SET type=?, base_url=?, username=?, secret_encrypted=?,
			remote_device_id=?, quota_used=?, quota_limit=?, status='connected', last_error=NULL, updated_at=? WHERE id=?`,
			in.Type, in.BaseURL, in.Username, sec, in.DeviceID, in.QuotaUsed, in.QuotaLimit, now, ex.ID)
		if err == nil {
			_, _ = tx.ExecContext(ctx, `UPDATE cloud_archive_items SET remote_upload_id=NULL WHERE account_id=?`, ex.ID)
		}
	} else {
		_, err = tx.ExecContext(ctx, `INSERT INTO cloud_accounts
			(id, user_id, type, base_url, username, secret_encrypted, remote_device_id, quota_used, quota_limit, status)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'connected')`,
			uuid.NewString(), userID, in.Type, in.BaseURL, in.Username, sec, in.DeviceID, in.QuotaUsed, in.QuotaLimit)
	}
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	acc, _, err := s.GetAccount(ctx, userID)
	return acc, err
}

func (s *Service) ConnectNeoCloud(ctx context.Context, userID, baseURL, username, token string, deviceID *string) (*Account, error) {
	sink := &neoCloudSink{baseURL: baseURL, token: token, folder: "NeoRecall", http: s.httpClient(), timeoutMs: s.cfg().CloudHTTPTimeoutMs}
	var qu, ql *int64
	if info, err := sink.Me(ctx); err == nil {
		qu = info.QuotaUsed
		ql = info.QuotaLimit
	}
	return s.UpsertConnected(ctx, userID, ConnectInput{
		Type: "neocloud", BaseURL: baseURL, Username: username, Credential: token,
		DeviceID: deviceID, QuotaUsed: qu, QuotaLimit: ql,
	})
}

func (s *Service) UpdateSettings(ctx context.Context, userID string, audioEn, dataEn *bool, folder *string) (map[string]any, error) {
	a, _, err := s.GetAccount(ctx, userID)
	if err != nil {
		return nil, err
	}
	if a == nil {
		return nil, httperr.New(http.StatusNotFound, "CLOUD_NOT_CONNECTED", "Connect a cloud backup first.")
	}
	ae := a.AudioEnabled
	if audioEn != nil {
		ae = *audioEn
	}
	de := a.DataBackupEnabled
	if dataEn != nil {
		de = *dataEn
	}
	fld := a.Folder
	if folder != nil {
		fld = strings.TrimSpace(*folder)
		if !folderPattern.MatchString(fld) {
			return nil, httperr.New(http.StatusBadRequest, "INVALID_CLOUD_FOLDER", "The cloud folder name may only contain letters, numbers, dots, dashes and underscores.")
		}
	}
	_, err = s.DB.W.ExecContext(ctx, `UPDATE cloud_accounts SET audio_enabled=?, data_backup_enabled=?, folder=?, updated_at=? WHERE id=?`,
		boolToInt(ae), boolToInt(de), fld, timeutil.NowISO(), a.ID)
	if err != nil {
		return nil, err
	}
	return s.PublicAccount(ctx, userID)
}

func (s *Service) RecordSuccess(ctx context.Context, userID, kind string) {
	col := "last_audio_upload_at"
	if kind == "data" {
		col = "last_data_backup_at"
	}
	now := timeutil.NowISO()
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_accounts SET `+col+`=?, status='connected', last_error=NULL, updated_at=? WHERE user_id=?`, now, now, userID)
}

func (s *Service) RecordError(ctx context.Context, userID, msg string) {
	if len(msg) > 500 {
		msg = msg[:500]
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_accounts SET status='error', last_error=?, updated_at=? WHERE user_id=?`, msg, timeutil.NowISO(), userID)
}

func (s *Service) RecordQuota(ctx context.Context, userID string, used, limit *int64) {
	if used == nil {
		return
	}
	lim := int64(-1)
	if limit != nil {
		lim = *limit
	}
	_, _ = s.DB.W.ExecContext(ctx, `UPDATE cloud_accounts SET quota_used=?, quota_limit=? WHERE user_id=?`, *used, lim, userID)
}

func (s *Service) Disconnect(ctx context.Context, userID string) error {
	s.DiscardPending(ctx, userID)
	_, err := s.DB.W.ExecContext(ctx, `DELETE FROM cloud_accounts WHERE user_id=?`, userID)
	return err
}

func (s *Service) ListDueDataBackups(ctx context.Context, intervalHours int) []string {
	cutoff := timeutil.FormatISO(timeutil.AddMillis(time.Now().UTC(), -int64(intervalHours)*60*60_000))
	rows, err := s.DB.R.QueryContext(ctx, `SELECT user_id FROM cloud_accounts WHERE data_backup_enabled=1 AND (last_data_backup_at IS NULL OR last_data_backup_at<?)`, cutoff)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var u string
		if rows.Scan(&u) == nil {
			out = append(out, u)
		}
	}
	return out
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
