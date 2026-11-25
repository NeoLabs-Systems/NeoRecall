package ingest

import (
	"context"
	"database/sql"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/google/uuid"
)

var nonAlnumRe = regexp.MustCompile(`[^a-zA-Z0-9]+`)

type TempAudio struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	Log       *slog.Logger
}

func (t *TempAudio) cfg() config.Config {
	if t.Cfg != nil {
		return t.Cfg()
	}
	return config.Config{}
}

func (t *TempAudio) IncomingPath() string {
	return filepath.Join(t.cfg().Paths.AudioTmp, "incoming-"+uuid.NewString()+".part")
}

func (t *TempAudio) ChunkPath(chunkID, ext string) string {
	clean := strings.ToLower(nonAlnumRe.ReplaceAllString(ext, ""))
	if clean == "" {
		clean = "bin"
	}
	return filepath.Join(t.cfg().Paths.AudioTmp, chunkID+"."+clean)
}

func UnlinkStrict(file string) error {
	if file == "" {
		return nil
	}
	st, err := os.Lstat(file)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if st.IsDir() {
		return os.RemoveAll(file)
	}
	if err := os.Remove(file); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func (t *TempAudio) UnlinkBestEffort(file string, attrs ...any) bool {
	if err := UnlinkStrict(file); err != nil {
		if t.Log != nil {
			t.Log.Warn("temporary audio file could not be deleted", append([]any{"file", file, "error", err}, attrs...)...)
		}
		return false
	}
	return true
}

func (t *TempAudio) SweepOrphans(dir string, referenced map[string]bool) int {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	graceMs := t.cfg().OrphanFileGraceMs
	if graceMs <= 0 {
		graceMs = 60_000
	}
	grace := time.Duration(graceMs) * time.Millisecond
	removed := 0
	for _, ent := range entries {
		if !ent.Type().IsRegular() {
			continue
		}
		target, err := filepath.Abs(filepath.Join(dir, ent.Name()))
		if err != nil || referenced[target] {
			continue
		}
		info, err := ent.Info()
		if err != nil || time.Since(info.ModTime()) <= grace {
			continue
		}
		if t.UnlinkBestEffort(target) {
			removed++
		}
	}
	return removed
}

func (t *TempAudio) SweepDerived() (int, error) {
	dir := t.cfg().Paths.AudioWork
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	maxAge := time.Duration(t.cfg().TranscriptionTimeoutMs+60_000) * time.Millisecond
	if maxAge <= time.Minute {
		maxAge = 31 * time.Minute
	}
	removed := 0
	for _, ent := range entries {
		if !ent.Type().IsRegular() {
			continue
		}
		target := filepath.Join(dir, ent.Name())
		info, err := ent.Info()
		if err != nil || time.Since(info.ModTime()) <= maxAge {
			continue
		}
		if err := UnlinkStrict(target); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

func (t *TempAudio) Sweep(ctx context.Context) (int, error) {
	p := t.cfg().Paths
	key, err := t.MasterKey()
	if err != nil {
		return 0, err
	}
	rows, err := t.DB.R.QueryContext(ctx, `SELECT temporary_path FROM audio_chunks WHERE temporary_path IS NOT NULL`)
	if err != nil {
		return 0, err
	}
	referenced := map[string]bool{}
	for rows.Next() {
		var tp sql.NullString
		if rows.Scan(&tp) == nil && tp.Valid && tp.String != "" {
			if abs, err := filepath.Abs(tp.String); err == nil {
				referenced[abs] = true
				_ = crypto.SealInPlace(key, abs)
			}
		}
	}
	rows.Close()
	removed := t.SweepOrphans(p.AudioTmp, referenced)
	dRemoved, err := t.SweepDerived()
	if err != nil {
		return removed, err
	}
	return removed + dRemoved, nil
}
