// Package crypto implements NeoRecall's master key management, tokens/digests,
// string/buffer sealing, and NRF1/NRB1 streaming AES-256-GCM file encryption.
//
// Formats are byte-compatible with the Node server's secret.key helpers so
// encrypted database fields, voiceprints, sealed audio files, and NRB1 backups
// remain readable across versions.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/NeoLabs-Systems/neolabs-go/filebox"
	"github.com/NeoLabs-Systems/neolabs-go/passhash"
)

const (
	MasterKeyLen = 32
	sealVersion  = 1
	sealHeader   = 1 + filebox.IVSize + filebox.TagSize // 29 bytes
)

var (
	FileMagic   = [4]byte{'N', 'R', 'F', '1'}
	BackupMagic = [4]byte{'N', 'R', 'B', '1'}

	keyMu         sync.Mutex
	cachedKeyPath string
	cachedKey     []byte
)

// RandomToken returns n random bytes encoded as unpadded base64url.
func RandomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// SHA256Hex returns the lowercase hexadecimal SHA-256 digest of s.
func SHA256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// SHA256File hashes path in streaming blocks without buffering the whole file.
func SHA256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// TimingSafeStringEqual compares two strings in constant time when lengths match.
func TimingSafeStringEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

// HashPassword hashes password with bcrypt cost 12.
func HashPassword(password string) (string, error) {
	return passhash.Hash(password, passhash.DefaultCost)
}

// VerifyPassword compares password with a stored bcrypt hash.
func VerifyPassword(password, hash string) bool {
	return passhash.Verify(hash, password)
}

// MasterKey reads (or atomically creates with 0600 permissions) the 32-byte key
// at secretKeyPath, caching by resolved path.
func MasterKey(secretKeyPath string) ([]byte, error) {
	abs, err := filepath.Abs(secretKeyPath)
	if err != nil {
		abs = secretKeyPath
	}
	keyMu.Lock()
	defer keyMu.Unlock()

	if cachedKeyPath == abs && len(cachedKey) == MasterKeyLen {
		return cachedKey, nil
	}
	if _, err := os.Stat(abs); errors.Is(err, os.ErrNotExist) {
		if err := os.MkdirAll(filepath.Dir(abs), 0o700); err != nil {
			return nil, err
		}
		buf := make([]byte, MasterKeyLen)
		if _, err := rand.Read(buf); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(abs, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			_, werr := f.Write(buf)
			cerr := f.Close()
			if werr != nil {
				return nil, werr
			}
			if cerr != nil {
				return nil, cerr
			}
		} else if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
	}
	key, err := os.ReadFile(abs)
	if err != nil {
		return nil, err
	}
	if len(key) != MasterKeyLen {
		return nil, fmt.Errorf("crypto: %s must contain exactly 32 bytes (got %d)", abs, len(key))
	}
	cachedKeyPath = abs
	cachedKey = key
	return key, nil
}

// ClearCachedMasterKey clears the cached key (for tests changing paths).
func ClearCachedMasterKey() {
	keyMu.Lock()
	cachedKeyPath = ""
	cachedKey = nil
	keyMu.Unlock()
}

func newAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != MasterKeyLen {
		return nil, filebox.ErrInvalidKeyLen
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// EncryptString seals plaintext as base64url(iv(12) | tag(16) | ciphertext).
func EncryptString(key []byte, plaintext string) (string, error) {
	aead, err := newAEAD(key)
	if err != nil {
		return "", err
	}
	iv := make([]byte, filebox.IVSize)
	if _, err := rand.Read(iv); err != nil {
		return "", err
	}
	out := aead.Seal(nil, iv, []byte(plaintext), nil) // ciphertext || tag
	cut := len(out) - filebox.TagSize
	packed := make([]byte, 0, filebox.IVSize+len(out))
	packed = append(packed, iv...)
	packed = append(packed, out[cut:]...)
	packed = append(packed, out[:cut]...)
	return base64.RawURLEncoding.EncodeToString(packed), nil
}

// DecryptString decrypts a base64url(iv(12) | tag(16) | ciphertext) string.
func DecryptString(key []byte, payload string) (string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(payload, "="))
	if err != nil || len(raw) < filebox.IVSize+filebox.TagSize {
		return "", errors.New("crypto: encrypted value is malformed")
	}
	aead, err := newAEAD(key)
	if err != nil {
		return "", err
	}
	iv := raw[:filebox.IVSize]
	tag := raw[filebox.IVSize : filebox.IVSize+filebox.TagSize]
	ct := raw[filebox.IVSize+filebox.TagSize:]
	joined := make([]byte, 0, len(ct)+filebox.TagSize)
	joined = append(joined, ct...)
	joined = append(joined, tag...)
	plain, err := aead.Open(nil, iv, joined, nil)
	if err != nil {
		return "", errors.New("crypto: decryption failed")
	}
	return string(plain), nil
}

// SealBuffer prepends version byte 1 and encrypts plaintext with AES-256-GCM:
// version(1) | iv(12) | tag(16) | ciphertext.
func SealBuffer(key, plaintext []byte) ([]byte, error) {
	aead, err := newAEAD(key)
	if err != nil {
		return nil, err
	}
	iv := make([]byte, filebox.IVSize)
	if _, err := rand.Read(iv); err != nil {
		return nil, err
	}
	out := aead.Seal(nil, iv, plaintext, nil)
	cut := len(out) - filebox.TagSize
	packed := make([]byte, 0, sealHeader+cut)
	packed = append(packed, sealVersion)
	packed = append(packed, iv...)
	packed = append(packed, out[cut:]...)
	packed = append(packed, out[:cut]...)
	return packed, nil
}

// UnsealBuffer decrypts a version-1 sealed buffer, or returns payload unchanged
// if it was not sealed (preserving migration tolerance for unsealed voiceprints).
func UnsealBuffer(key, payload []byte) []byte {
	if len(payload) < sealHeader || payload[0] != sealVersion {
		return payload
	}
	aead, err := newAEAD(key)
	if err != nil {
		return payload
	}
	iv := payload[1 : 1+filebox.IVSize]
	tag := payload[1+filebox.IVSize : sealHeader]
	ct := payload[sealHeader:]
	joined := make([]byte, 0, len(ct)+filebox.TagSize)
	joined = append(joined, ct...)
	joined = append(joined, tag...)
	plain, err := aead.Open(nil, iv, joined, nil)
	if err != nil {
		return payload
	}
	return plain
}

// IsSealedBuffer reports whether payload decrypts cleanly as a sealed buffer.
func IsSealedBuffer(key, payload []byte) bool {
	if len(payload) < sealHeader || payload[0] != sealVersion {
		return false
	}
	aead, err := newAEAD(key)
	if err != nil {
		return false
	}
	iv := payload[1 : 1+filebox.IVSize]
	tag := payload[1+filebox.IVSize : sealHeader]
	ct := payload[sealHeader:]
	joined := make([]byte, 0, len(ct)+filebox.TagSize)
	joined = append(joined, ct...)
	joined = append(joined, tag...)
	_, err = aead.Open(nil, iv, joined, nil)
	return err == nil
}

// SealFile encrypts srcPath into dstPath with 4-byte magic (NRF1 or NRB1).
func SealFile(key []byte, srcPath, dstPath string, magic [4]byte) error {
	return filebox.SealFile(srcPath, dstPath, key, magic)
}

// DecryptFile decrypts srcPath into dstPath with 4-byte magic verification.
func DecryptFile(key []byte, srcPath, dstPath string, magic [4]byte) error {
	return filebox.DecryptFile(srcPath, dstPath, key, magic)
}
