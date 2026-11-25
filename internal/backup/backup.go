package backup

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neolabs-go/filebox"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/timeutil"
)

var artifactKeyPattern = regexp.MustCompile(`^neorecall-\d{8}T\d{6}Z-[0-9a-f]{6}\.nrbak$`)

type Artifact struct {
	Key       string `json:"key"`
	Bytes     int64  `json:"bytes"`
	CreatedAt string `json:"createdAt"`
}

type Destination interface {
	Name() string
	Describe() string
	Store(sourcePath, key string) (Artifact, error)
	List() ([]Artifact, error)
	Remove(key string) error
	Fetch(key, destPath string) error
}

type LocalDestination struct {
	Dir func() string
}

func (l *LocalDestination) Name() string     { return "local" }
func (l *LocalDestination) Describe() string { return l.Dir() }

func (l *LocalDestination) resolve(key string) (string, error) {
	if !artifactKeyPattern.MatchString(key) {
		return "", fmt.Errorf("refusing to act on unrecognized backup key: %s", key)
	}
	dir := l.Dir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, key), nil
}

func (l *LocalDestination) Store(sourcePath, key string) (Artifact, error) {
	target, err := l.resolve(key)
	if err != nil {
		return Artifact{}, err
	}
	if err := copyPrivate(sourcePath, target); err != nil {
		return Artifact{}, err
	}
	st, err := os.Stat(target)
	if err != nil {
		return Artifact{}, err
	}
	return Artifact{Key: key, Bytes: st.Size(), CreatedAt: timeutil.FormatISO(st.ModTime().UTC())}, nil
}

func (l *LocalDestination) List() ([]Artifact, error) {
	dir := l.Dir()
	_ = os.MkdirAll(dir, 0o700)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := []Artifact{}
	for _, e := range entries {
		if !e.Type().IsRegular() || !artifactKeyPattern.MatchString(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, Artifact{
			Key:       e.Name(),
			Bytes:     info.Size(),
			CreatedAt: timeutil.FormatISO(info.ModTime().UTC()),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].Key > out[j].Key
	})
	return out, nil
}

func (l *LocalDestination) Remove(key string) error {
	target, err := l.resolve(key)
	if err != nil {
		return err
	}
	err = os.Remove(target)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (l *LocalDestination) Fetch(key, destPath string) error {
	target, err := l.resolve(key)
	if err != nil {
		return err
	}
	return copyPrivate(target, destPath)
}

func copyPrivate(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		_ = os.Remove(dst)
		return err
	}
	return out.Close()
}

type Service struct {
	DB        *dbx.DB
	Cfg       func() config.Config
	MasterKey func() ([]byte, error)
	Log       *slog.Logger
}

func (s *Service) cfg() config.Config {
	if s.Cfg != nil {
		return s.Cfg()
	}
	return config.Config{}
}

func (s *Service) Destination() (Destination, error) {
	c := s.cfg()
	dest := strings.ToLower(strings.TrimSpace(c.BackupDestination))
	if dest == "" || dest == "local" {
		return &LocalDestination{Dir: func() string { return s.cfg().Paths.Backups }}, nil
	}
	return nil, fmt.Errorf("unknown backup destination %q", dest)
}

func ArtifactKey(now time.Time) string {
	var b [3]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("neorecall-%s-%s.nrbak", now.UTC().Format("20060102T150405Z"), hex.EncodeToString(b[:]))
}

func (s *Service) Create(ctx context.Context) (Artifact, error) {
	dst, err := s.Destination()
	if err != nil {
		return Artifact{}, err
	}
	key, err := s.MasterKey()
	if err != nil {
		return Artifact{}, err
	}
	c := s.cfg()
	tmpDir, err := os.MkdirTemp(c.Paths.Backups, "bak-")
	if err != nil {
		return Artifact{}, err
	}
	defer os.RemoveAll(tmpDir)

	snapPath := filepath.Join(tmpDir, "snapshot.db")
	escaped := strings.ReplaceAll(snapPath, `'`, `''`)
	if _, err := s.DB.W.ExecContext(ctx, `VACUUM INTO '`+escaped+`'`); err != nil {
		return Artifact{}, fmt.Errorf("snapshot database: %w", err)
	}
	sealedPath := filepath.Join(tmpDir, "sealed.nrbak")
	if err := crypto.SealFile(key, snapPath, sealedPath, crypto.BackupMagic); err != nil {
		return Artifact{}, err
	}

	art, err := dst.Store(sealedPath, ArtifactKey(time.Now().UTC()))
	if err != nil {
		return Artifact{}, err
	}
	s.prune(dst, max(1, c.BackupRetain), art.Key)
	return art, nil
}

func (s *Service) prune(dst Destination, retain int, keepKey string) {
	items, err := dst.List()
	if err != nil || len(items) <= retain {
		return
	}
	kept := 0
	for _, it := range items {
		if it.Key == keepKey {
			kept++
			continue
		}
		if kept < retain {
			kept++
			continue
		}
		_ = dst.Remove(it.Key)
	}
}

func (s *Service) Status() (map[string]any, error) {
	c := s.cfg()
	dst, err := s.Destination()
	if err != nil {
		return nil, err
	}
	items, err := dst.List()
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"enabled":       c.BackupEnabled,
		"destination":   dst.Name(),
		"location":      dst.Describe(),
		"intervalHours": c.BackupIntervalHours,
		"retain":        c.BackupRetain,
		"items":         items,
	}, nil
}

func (s *Service) OpenDownload(key string) (*os.File, os.FileInfo, error) {
	dst, err := s.Destination()
	if err != nil {
		return nil, nil, err
	}
	tmp, err := os.CreateTemp(s.cfg().Paths.Backups, "dl-*")
	if err != nil {
		return nil, nil, err
	}
	tmpPath := tmp.Name()
	_ = tmp.Close()
	if err := dst.Fetch(key, tmpPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, nil, err
	}
	f, err := os.Open(tmpPath)
	_ = os.Remove(tmpPath)
	if err != nil {
		return nil, nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	return f, info, nil
}

// RestoreFile decrypts an NRB1 backup file, verifies it is a valid SQLite database, and atomically replaces targetDBPath.
func RestoreFile(key []byte, backupPath, targetDBPath string) error {
	if !filebox.HasMagic(backupPath, crypto.BackupMagic) {
		return fmt.Errorf("backup file is not a valid sealed NeoRecall backup (NRB1)")
	}
	tmpOut := targetDBPath + ".restoring"
	if err := filebox.DecryptFile(backupPath, tmpOut, key, crypto.BackupMagic); err != nil {
		_ = os.Remove(tmpOut)
		return fmt.Errorf("decrypt backup: %w", err)
	}
	// Verify integrity with PRAGMA integrity_check before replacing live DB.
	chkDB, err := sql.Open("sqlite", tmpOut+"?_pragma=query_only(1)")
	if err != nil {
		_ = os.Remove(tmpOut)
		return err
	}
	var chk string
	err = chkDB.QueryRow(`PRAGMA integrity_check`).Scan(&chk)
	_ = chkDB.Close()
	if err != nil || strings.ToLower(chk) != "ok" {
		_ = os.Remove(tmpOut)
		return fmt.Errorf("backup integrity check failed: %v (%s)", err, chk)
	}
	_ = os.Remove(targetDBPath + "-wal")
	_ = os.Remove(targetDBPath + "-shm")
	if err := os.Rename(tmpOut, targetDBPath); err != nil {
		_ = os.Remove(tmpOut)
		return err
	}
	_ = os.Chmod(targetDBPath, 0o600)
	return nil
}
