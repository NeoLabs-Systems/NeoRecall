package ingest

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/httperr"
	"github.com/NeoLabs-Systems/neorecall/internal/jobs"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
	"github.com/google/uuid"
)

type ImportPartView struct {
	PartNumber int    `json:"part_number"`
	RangeStart int64  `json:"range_start"`
	RangeEnd   int64  `json:"range_end"`
	ByteSize   int64  `json:"byte_size"`
	SHA256     string `json:"sha256"`
}

type ImportView struct {
	ID            string           `json:"id"`
	UserID        string           `json:"user_id"`
	DeviceID      *string          `json:"device_id"`
	OriginalName  string           `json:"original_name"`
	ContentType   string           `json:"content_type"`
	TotalSize     int64            `json:"total_size"`
	SHA256        string           `json:"sha256"`
	PartSize      int64            `json:"part_size"`
	CaptureTime   *string          `json:"capture_time"`
	Timezone      *string          `json:"timezone"`
	State         string           `json:"state"`
	TemporaryPath *string          `json:"temporary_path"`
	ErrorCode     *string          `json:"error_code"`
	ExpiresAt     *string          `json:"expires_at"`
	CreatedAt     string           `json:"created_at"`
	UpdatedAt     string           `json:"updated_at"`
	Parts         []ImportPartView `json:"parts"`
	MissingParts  []int            `json:"missingParts"`
}

type ImportService struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	TempAudio *TempAudio
}

func (s *ImportService) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func nullStringPtr(n sql.NullString) *string {
	if !n.Valid {
		return nil
	}
	v := n.String
	return &v
}

func (s *ImportService) Get(ctx context.Context, userID, id string) (ImportView, error) {
	var v ImportView
	var devID, capTime, tz, tmpPath, ec, exp sql.NullString
	err := s.DB.R.QueryRowContext(ctx, `SELECT id, user_id, device_id, original_name, content_type, total_size, sha256,
		part_size, capture_time, timezone, state, temporary_path, error_code, expires_at, created_at, updated_at
		FROM imports WHERE id=? AND user_id=?`, id, userID).
		Scan(&v.ID, &v.UserID, &devID, &v.OriginalName, &v.ContentType, &v.TotalSize, &v.SHA256,
			&v.PartSize, &capTime, &tz, &v.State, &tmpPath, &ec, &exp, &v.CreatedAt, &v.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ImportView{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Import not found.")
	}
	if err != nil {
		return ImportView{}, err
	}
	v.DeviceID = nullStringPtr(devID)
	v.CaptureTime = nullStringPtr(capTime)
	v.Timezone = nullStringPtr(tz)
	v.TemporaryPath = nullStringPtr(tmpPath)
	v.ErrorCode = nullStringPtr(ec)
	v.ExpiresAt = nullStringPtr(exp)

	rows, err := s.DB.R.QueryContext(ctx, `SELECT part_number, range_start, range_end, byte_size, sha256
		FROM import_parts WHERE import_id=? ORDER BY part_number`, id)
	if err != nil {
		return ImportView{}, err
	}
	defer rows.Close()
	v.Parts = []ImportPartView{}
	known := map[int]bool{}
	for rows.Next() {
		var p ImportPartView
		if err := rows.Scan(&p.PartNumber, &p.RangeStart, &p.RangeEnd, &p.ByteSize, &p.SHA256); err != nil {
			return ImportView{}, err
		}
		v.Parts = append(v.Parts, p)
		known[p.PartNumber] = true
	}
	expected := int((v.TotalSize + v.PartSize - 1) / v.PartSize)
	v.MissingParts = []int{}
	for i := 0; i < expected; i++ {
		if !known[i] {
			v.MissingParts = append(v.MissingParts, i)
		}
	}
	return v, nil
}

type DeclareImportInput struct {
	ID           string
	DeviceID     string
	OriginalName string
	ContentType  string
	TotalSize    int64
	SHA256       string
	PartSize     int64
	CaptureTime  string
	Timezone     string
}

func (s *ImportService) Declare(ctx context.Context, userID string, in DeclareImportInput) (ImportView, error) {
	c := s.cfg()
	partSize := in.PartSize
	if partSize <= 0 {
		partSize = c.ImportPartBytes
	}
	if partSize > c.ImportPartBytes {
		return ImportView{}, httperr.New(http.StatusBadRequest, "IMPORT_PART_TOO_LARGE", fmt.Sprintf("Import parts may not exceed %d bytes.", c.ImportPartBytes))
	}
	if in.DeviceID != "" {
		var one int
		if err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL`, in.DeviceID, userID).Scan(&one); err != nil {
			return ImportView{}, httperr.New(http.StatusNotFound, "NOT_FOUND", "Device not found.")
		}
	}
	id := in.ID
	if id == "" {
		id = uuid.NewString()
	}
	if existing, err := s.Get(ctx, userID, id); err == nil {
		if existing.SHA256 != in.SHA256 || existing.TotalSize != in.TotalSize {
			return ImportView{}, httperr.New(http.StatusConflict, "IDEMPOTENCY_CONFLICT", "Import ID was already used with different content.")
		}
		return existing, nil
	}
	var devArg, capArg, tzArg sql.NullString
	if in.DeviceID != "" {
		devArg = sql.NullString{String: in.DeviceID, Valid: true}
	}
	if in.CaptureTime != "" {
		capArg = sql.NullString{String: in.CaptureTime, Valid: true}
	}
	if in.Timezone != "" {
		tzArg = sql.NullString{String: in.Timezone, Valid: true}
	}
	exp := timeutil.FormatISO(time.Now().Add(time.Duration(c.ImportFailedTTLHours) * time.Hour))
	if _, err := s.DB.W.ExecContext(ctx, `INSERT INTO imports
		(id, user_id, device_id, original_name, content_type, total_size, sha256, part_size, capture_time, timezone, state, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'declared', ?)`,
		id, userID, devArg, filepath.Base(in.OriginalName), in.ContentType, in.TotalSize, in.SHA256, partSize, capArg, tzArg, exp); err != nil {
		return ImportView{}, err
	}
	return s.Get(ctx, userID, id)
}

func (s *ImportService) AcceptPart(ctx context.Context, userID, id string, partNumber int, rangeStart, rangeEnd, total int64, expectedSHA string, tempPartPath string) (ImportView, error) {
	if tempPartPath == "" {
		return ImportView{}, httperr.New(http.StatusBadRequest, "PART_REQUIRED", "The part field is required.")
	}
	defer func() {
		_ = os.Remove(tempPartPath)
	}()

	rec, err := s.Get(ctx, userID, id)
	if err != nil {
		return ImportView{}, err
	}
	if rec.State != "declared" && rec.State != "uploading" {
		return ImportView{}, httperr.New(http.StatusConflict, "IMPORT_NOT_UPLOADABLE", "Import is not accepting parts.")
	}
	st, err := os.Stat(tempPartPath)
	if err != nil {
		return ImportView{}, err
	}
	expectedStart := int64(partNumber) * rec.PartSize
	expectedEnd := min(rec.TotalSize-1, expectedStart+rec.PartSize-1)
	if total != rec.TotalSize || rangeStart != expectedStart || rangeEnd != expectedEnd || st.Size() != expectedEnd-expectedStart+1 {
		return ImportView{}, httperr.New(http.StatusConflict, "INVALID_CONTENT_RANGE", "The uploaded part range is not the expected range.")
	}
	digest, err := crypto.SHA256File(tempPartPath)
	if err != nil {
		return ImportView{}, err
	}
	if digest != expectedSHA {
		return ImportView{}, httperr.New(http.StatusUnprocessableEntity, "HASH_MISMATCH", "The import part hash does not match.")
	}

	var exSHA string
	var exBytes int64
	if err := s.DB.R.QueryRowContext(ctx, `SELECT sha256, byte_size FROM import_parts WHERE import_id=? AND part_number=?`, id, partNumber).Scan(&exSHA, &exBytes); err == nil {
		if exSHA != digest || exBytes != st.Size() {
			return ImportView{}, httperr.New(http.StatusConflict, "IDEMPOTENCY_CONFLICT", "This import part number already contains different data.")
		}
		return s.Get(ctx, userID, id)
	}

	dest := filepath.Join(s.cfg().Paths.ImportTmp, fmt.Sprintf("%s.%d.part", id, partNumber))
	if err := os.Rename(tempPartPath, dest); err != nil {
		return ImportView{}, err
	}
	key, err := s.MasterKey()
	if err != nil {
		return ImportView{}, err
	}
	if err := crypto.SealInPlace(key, dest); err != nil {
		_ = UnlinkStrict(dest)
		return ImportView{}, err
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		_ = UnlinkStrict(dest)
		return ImportView{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `INSERT INTO import_parts (import_id, part_number, range_start, range_end, byte_size, sha256, temporary_path)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, id, partNumber, rangeStart, rangeEnd, st.Size(), digest, dest); err != nil {
		return ImportView{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE imports SET state='uploading', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, id); err != nil {
		return ImportView{}, err
	}
	if err := tx.Commit(); err != nil {
		return ImportView{}, err
	}
	return s.Get(ctx, userID, id)
}

func (s *ImportService) Complete(ctx context.Context, userID, id string) (ImportView, error) {
	rec, err := s.Get(ctx, userID, id)
	if err != nil {
		return ImportView{}, err
	}
	if slices.Contains([]string{"assembled", "processing", "completed"}, rec.State) {
		return rec, nil
	}
	if rec.State != "declared" && rec.State != "uploading" {
		return ImportView{}, httperr.New(http.StatusConflict, "IMPORT_NOT_COMPLETABLE", "Import is not in a completable state.")
	}
	if len(rec.MissingParts) > 0 {
		return ImportView{}, httperr.New(http.StatusConflict, "IMPORT_INCOMPLETE", "One or more import parts are missing.", map[string]any{"missingParts": rec.MissingParts})
	}

	key, err := s.MasterKey()
	if err != nil {
		return ImportView{}, err
	}
	dest := filepath.Join(s.cfg().Paths.ImportTmp, id+".source")
	out, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return ImportView{}, err
	}

	rows, err := s.DB.R.QueryContext(ctx, `SELECT temporary_path FROM import_parts WHERE import_id=? ORDER BY part_number`, id)
	if err != nil {
		out.Close()
		_ = os.Remove(dest)
		return ImportView{}, err
	}
	var partFiles []string
	h := sha256.New()
	for rows.Next() {
		var tp string
		if rows.Scan(&tp) == nil {
			partFiles = append(partFiles, tp)
			plain, rerr := crypto.ReadSealedFile(key, tp)
			if rerr != nil {
				rows.Close()
				out.Close()
				_ = os.Remove(dest)
				return ImportView{}, rerr
			}
			_, _ = h.Write(plain)
			if _, werr := out.Write(plain); werr != nil {
				rows.Close()
				out.Close()
				_ = os.Remove(dest)
				return ImportView{}, werr
			}
		}
	}
	rows.Close()
	_ = out.Sync()
	_ = out.Close()

	digest := hex.EncodeToString(h.Sum(nil))
	if digest != rec.SHA256 {
		_ = os.Remove(dest)
		return ImportView{}, httperr.New(http.StatusUnprocessableEntity, "HASH_MISMATCH", "The assembled import hash does not match.")
	}
	if err := crypto.SealInPlace(key, dest); err != nil {
		_ = os.Remove(dest)
		return ImportView{}, err
	}

	tx, err := s.DB.W.BeginTx(ctx, nil)
	if err != nil {
		_ = os.Remove(dest)
		return ImportView{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM import_parts WHERE import_id=?`, id); err != nil {
		return ImportView{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE imports SET state='assembled', temporary_path=?, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, dest, id); err != nil {
		return ImportView{}, err
	}
	if _, err := jobs.EnqueueTx(ctx, tx, jobs.EnqueueInput{
		UserID: userID, ResourceType: "import", ResourceID: id, Type: "process_import", Priority: 90,
	}, s.cfg().JobMaxAttempts); err != nil {
		return ImportView{}, err
	}
	if err := tx.Commit(); err != nil {
		return ImportView{}, err
	}
	for _, pf := range partFiles {
		_ = UnlinkStrict(pf)
	}
	return s.Get(ctx, userID, id)
}

func (s *ImportService) Cancel(ctx context.Context, userID, id string) error {
	rec, err := s.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	rows, err := s.DB.R.QueryContext(ctx, `SELECT temporary_path FROM import_parts WHERE import_id=?`, id)
	if err == nil {
		for rows.Next() {
			var tp string
			if rows.Scan(&tp) == nil && s.TempAudio != nil {
				s.TempAudio.UnlinkBestEffort(tp, "importId", id, "userId", userID)
			}
		}
		rows.Close()
	}
	if rec.TemporaryPath != nil && s.TempAudio != nil {
		s.TempAudio.UnlinkBestEffort(*rec.TemporaryPath, "importId", id, "userId", userID)
	}
	_, err = s.DB.W.ExecContext(ctx, `UPDATE imports SET state='cancelled', temporary_path=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND user_id=?`, id, userID)
	return err
}

func (s *ImportService) ReconcileProcessing(ctx context.Context) (int, error) {
	rows, err := s.DB.R.QueryContext(ctx, `SELECT id, temporary_path FROM imports WHERE state IN ('processing','failed') AND temporary_path IS NOT NULL`)
	if err != nil {
		return 0, err
	}
	type item struct{ id, tmp string }
	var list []item
	for rows.Next() {
		var it item
		if rows.Scan(&it.id, &it.tmp) == nil {
			list = append(list, it)
		}
	}
	rows.Close()

	completed := 0
	for _, it := range list {
		var srcID string
		if err := s.DB.R.QueryRowContext(ctx, `SELECT id FROM recording_sources WHERE client_uuid=?`, "import-source-"+it.id).Scan(&srcID); err != nil {
			continue
		}
		var pending int
		if err := s.DB.R.QueryRowContext(ctx, `SELECT 1 FROM audio_chunks WHERE source_id=? AND state NOT IN ('transcribed','silent') LIMIT 1`, srcID).Scan(&pending); err == nil {
			continue
		}
		if err := UnlinkStrict(it.tmp); err != nil {
			return completed, err
		}
		if _, err := s.DB.W.ExecContext(ctx, `UPDATE imports SET state='completed', temporary_path=NULL, expires_at=NULL, error_code=NULL, updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=?`, it.id); err != nil {
			return completed, err
		}
		completed++
	}
	return completed, nil
}

func (s *ImportService) SweepOrphans(ctx context.Context) int {
	if s.TempAudio == nil {
		return 0
	}
	ref := map[string]bool{}
	for _, q := range []string{
		`SELECT temporary_path FROM imports WHERE temporary_path IS NOT NULL`,
		`SELECT temporary_path FROM import_parts WHERE temporary_path IS NOT NULL`,
	} {
		rows, err := s.DB.R.QueryContext(ctx, q)
		if err != nil {
			continue
		}
		for rows.Next() {
			var tp string
			if rows.Scan(&tp) == nil && tp != "" {
				if abs, err := filepath.Abs(tp); err == nil {
					ref[abs] = true
				}
			}
		}
		rows.Close()
	}
	return s.TempAudio.SweepOrphans(s.cfg().Paths.ImportTmp, ref)
}
