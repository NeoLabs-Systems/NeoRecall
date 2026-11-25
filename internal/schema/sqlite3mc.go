package schema

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/NeoLabs-Systems/neolabs-go/dbx"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"golang.org/x/crypto/chacha20"
	"golang.org/x/crypto/pbkdf2"
	"golang.org/x/crypto/poly1305"
)

var sqliteMagicHeader = []byte("SQLite format 3\x00")

const (
	sqlite3mcChaChaSaltLen     = 16
	sqlite3mcChaChaKeyLen      = 32
	sqlite3mcChaChaKDFIter     = 64007
	sqlite3mcChaChaNonceLen    = 16
	sqlite3mcChaChaTagLen      = 16
	sqlite3mcChaChaReserved    = sqlite3mcChaChaNonceLen + sqlite3mcChaChaTagLen // 32
	sqlite3mcChaChaPage1Offset = 24
	sqlite3mcDefaultPageSize   = 4096
)

// IsPlainSQLiteFile checks whether path begins with the standard SQLite header.
func IsPlainSQLiteFile(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	var hdr [16]byte
	n, err := io.ReadFull(f, hdr[:])
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return false, err
	}
	return n == 16 && bytes.Equal(hdr[:], sqliteMagicHeader), nil
}

// DecryptSQLite3MCBytes decrypts a SQLite3MultipleCiphers ChaCha20-Poly1305 database image
// using rawKey (from secret.key) into a standard plaintext SQLite 3 image.
func DecryptSQLite3MCBytes(ciphertext, rawKey []byte) ([]byte, error) {
	if len(rawKey) != crypto.MasterKeyLen {
		return nil, fmt.Errorf("secret.key must be %d bytes, got %d", crypto.MasterKeyLen, len(rawKey))
	}
	if len(ciphertext) >= 16 && bytes.Equal(ciphertext[:16], sqliteMagicHeader) {
		out := make([]byte, len(ciphertext))
		copy(out, ciphertext)
		return out, nil
	}
	if len(ciphertext) < 512 {
		return nil, errors.New("encrypted database is too small")
	}

	pageSize := int(binary.BigEndian.Uint16(ciphertext[16:18]))
	if pageSize == 1 {
		pageSize = 65536
	}
	if pageSize < 512 || (pageSize&(pageSize-1)) != 0 || pageSize > 65536 {
		pageSize = sqlite3mcDefaultPageSize
	}
	if len(ciphertext) < pageSize || len(ciphertext)%pageSize != 0 {
		return nil, fmt.Errorf("encrypted database size %d is not a multiple of page size %d", len(ciphertext), pageSize)
	}

	salt := ciphertext[:sqlite3mcChaChaSaltLen]
	derivedKey := pbkdf2.Key(rawKey, salt, sqlite3mcChaChaKDFIter, sqlite3mcChaChaKeyLen, sha256.New)
	defer clear(derivedKey)

	out := make([]byte, len(ciphertext))
	copy(out, ciphertext)

	nPayload := pageSize - sqlite3mcChaChaReserved
	numPages := len(out) / pageSize
	var zero64 [64]byte

	for page := 1; page <= numPages; page++ {
		pg := out[(page-1)*pageSize : page*pageSize]
		offset := 0
		if page == 1 {
			offset = sqlite3mcChaChaPage1Offset
		}

		nonce := pg[nPayload : nPayload+sqlite3mcChaChaNonceLen]
		tagBytes := pg[nPayload+sqlite3mcChaChaNonceLen : pageSize]
		counter := binary.LittleEndian.Uint32(nonce[sqlite3mcChaChaNonceLen-4:sqlite3mcChaChaNonceLen]) ^ uint32(page)

		c1, err := chacha20.NewUnauthenticatedCipher(derivedKey, nonce[:12])
		if err != nil {
			return nil, err
		}
		c1.SetCounter(counter)
		var otk [64]byte
		c1.XORKeyStream(otk[:], zero64[:])

		var macKey [32]byte
		var tag [16]byte
		copy(macKey[:], otk[:32])
		copy(tag[:], tagBytes)
		if !poly1305.Verify(&tag, pg[:nPayload+sqlite3mcChaChaNonceLen], &macKey) {
			clear(otk[:])
			if page == 1 {
				return nil, errors.New("could not unlock encrypted NeoRecall database with secret.key")
			}
			return nil, fmt.Errorf("corrupt or invalid MAC on database page %d", page)
		}

		c2, err := chacha20.NewUnauthenticatedCipher(otk[32:64], nonce[:12])
		clear(otk[:])
		if err != nil {
			return nil, err
		}
		c2.SetCounter(counter + 1)
		c2.XORKeyStream(pg[offset:nPayload], pg[offset:nPayload])

		if page == 1 {
			copy(pg[:16], sqliteMagicHeader)
		}
		clear(pg[nPayload:pageSize])
	}

	return out, nil
}

// EnsurePlaintextLegacyDB checks whether dbPath is encrypted with legacy Node.js
// better-sqlite3-multiple-ciphers and, if so, decrypts it in place using secretKeyPath.
func EnsurePlaintextLegacyDB(ctx context.Context, dbPath, secretKeyPath, appDir, homeDir string) (bool, error) {
	plain, err := IsPlainSQLiteFile(dbPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if plain {
		return false, nil
	}

	rawKey, err := crypto.MasterKey(secretKeyPath)
	if err != nil {
		return false, fmt.Errorf("read secret.key to unlock legacy database: %w", err)
	}

	rawBak := dbPath + ".pre-decrypt.bak"
	if _, serr := os.Stat(rawBak); os.IsNotExist(serr) {
		if b, rerr := os.ReadFile(dbPath); rerr == nil {
			_ = os.WriteFile(rawBak, b, 0o600)
		}
	}

	walPath := dbPath + "-wal"
	walInfo, walErr := os.Stat(walPath)
	hasNonEmptyWAL := walErr == nil && walInfo.Size() > 0
	if hasNonEmptyWAL {
		if wb, rerr := os.ReadFile(walPath); rerr == nil {
			_ = os.WriteFile(walPath+".pre-decrypt.bak", wb, 0o600)
		}
	}
	if modPath := findLegacyBSMCModule(appDir, homeDir); modPath != "" {
		if nerr := decryptViaLegacyNode(ctx, modPath, dbPath, secretKeyPath); nerr == nil {
			if ok, _ := IsPlainSQLiteFile(dbPath); ok {
				return true, nil
			}
		} else {
			walAfter, werr := os.Stat(walPath)
			if werr == nil && walAfter.Size() > 0 {
				return false, fmt.Errorf("legacy database has pending WAL frames and Node rekey failed: %w", nerr)
			}
		}
	}

	encrypted, err := os.ReadFile(dbPath)
	if err != nil {
		return false, err
	}
	decrypted, err := DecryptSQLite3MCBytes(encrypted, rawKey)
	if err != nil {
		return false, err
	}

	tmpPlain := dbPath + ".decrypted.tmp"
	_ = os.Remove(tmpPlain)
	if err := os.WriteFile(tmpPlain, decrypted, 0o600); err != nil {
		return false, err
	}

	cleanOut := dbPath + ".clean.tmp"
	_ = os.Remove(cleanOut)
	if err := verifyAndRepackSQLite(ctx, tmpPlain, cleanOut); err != nil {
		_ = os.Remove(tmpPlain)
		_ = os.Remove(cleanOut)
		return false, fmt.Errorf("decrypted legacy database failed verification: %w", err)
	}
	_ = os.Remove(tmpPlain)

	_ = os.Remove(dbPath + "-wal")
	_ = os.Remove(dbPath + "-shm")
	if err := os.Rename(cleanOut, dbPath); err != nil {
		_ = os.Remove(cleanOut)
		return false, err
	}
	return true, nil
}

func verifyAndRepackSQLite(ctx context.Context, srcPath, cleanPath string) error {
	db, err := dbx.Open(ctx, srcPath, dbx.Options{})
	if err != nil {
		return err
	}
	var integrity string
	qerr := db.R.QueryRowContext(ctx, `PRAGMA integrity_check`).Scan(&integrity)
	if qerr != nil {
		_ = db.Close()
		return qerr
	}
	if strings.ToLower(strings.TrimSpace(integrity)) != "ok" {
		_ = db.Close()
		return fmt.Errorf("integrity_check returned %q", integrity)
	}
	escaped := strings.ReplaceAll(cleanPath, "'", "''")
	_, verr := db.W.ExecContext(ctx, `VACUUM INTO '`+escaped+`'`)
	_ = db.Close()
	if verr != nil {
		b, rerr := os.ReadFile(srcPath)
		if rerr != nil {
			return verr
		}
		return os.WriteFile(cleanPath, b, 0o600)
	}
	chk, cerr := sql.Open("sqlite", cleanPath+"?_pragma=query_only(1)")
	if cerr != nil {
		return cerr
	}
	defer chk.Close()
	var chkRes string
	if err := chk.QueryRowContext(ctx, `PRAGMA integrity_check`).Scan(&chkRes); err != nil {
		return err
	}
	if strings.ToLower(strings.TrimSpace(chkRes)) != "ok" {
		return fmt.Errorf("repacked integrity_check returned %q", chkRes)
	}
	return os.Chmod(cleanPath, 0o600)
}

func findLegacyBSMCModule(appDir, homeDir string) string {
	var roots []string
	if appDir != "" {
		roots = append(roots, appDir)
	}
	if homeDir != "" {
		roots = append(roots, filepath.Join(homeDir, "app"))
	}
	for _, r := range roots {
		cand := filepath.Join(r, "node_modules", "better-sqlite3-multiple-ciphers")
		if info, err := os.Stat(cand); err == nil && info.IsDir() {
			return cand
		}
	}
	return ""
}

func decryptViaLegacyNode(ctx context.Context, modPath, dbPath, keyPath string) error {
	nodeBin, err := exec.LookPath("node")
	if err != nil {
		return err
	}
	script := `
const fs = require('node:fs');
const Database = require(process.argv[1]);
const key = fs.readFileSync(process.argv[3]);
function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
let lastErr;
for (let attempt = 0; attempt < 12; attempt++) {
  let db;
  try {
    db = new Database(process.argv[2], { timeout: 10000 });
    db.key(key);
    db.pragma('busy_timeout = 10000');
    db.pragma('wal_checkpoint(TRUNCATE)');
    db.pragma('journal_mode = DELETE');
    db.rekey(Buffer.alloc(0));
    lastErr = null;
    break;
  } catch (err) {
    lastErr = err;
    if (!err || err.code !== 'SQLITE_BUSY' || attempt === 11) {
      throw err;
    }
    sleep(300);
  } finally {
    try { db?.close(); } catch (_) {}
  }
}
if (lastErr) throw lastErr;
`
	cmd := exec.CommandContext(ctx, nodeBin, "-e", script, modPath, dbPath, keyPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
