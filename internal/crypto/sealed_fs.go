package crypto

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/NeoLabs-Systems/neolabs-go/filebox"
)

// IsSealedFile checks whether path begins with the NRF1 magic header.
func IsSealedFile(path string) bool {
	return path != "" && filebox.HasMagic(path, FileMagic)
}

// SealInPlace encrypts path atomically with NRF1 if it exists and isn't already sealed.
func SealInPlace(key []byte, path string) error {
	if path == "" || IsSealedFile(path) {
		return nil
	}
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	suffix, err := RandomToken(8)
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.sealing-%s", path, suffix)
	if err := filebox.SealFile(path, tmp, key, FileMagic); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	_ = os.Chmod(path, 0o600)
	return nil
}

// ReadSealedFile reads plaintext bytes from path, unsealing NRF1 if sealed.
func ReadSealedFile(key []byte, path string) ([]byte, error) {
	if !IsSealedFile(path) {
		return os.ReadFile(path)
	}
	return filebox.DecryptBytes(path, key, FileMagic)
}

// WithPlain materializes a plaintext copy in audioWorkDir if path is NRF1-sealed,
// passes the plaintext path to fn, and removes the temporary file before returning.
func WithPlain(key []byte, audioWorkDir, path string, fn func(plainPath string) error) error {
	if path == "" || !IsSealedFile(path) {
		return fn(path)
	}
	tok, err := RandomToken(12)
	if err != nil {
		return err
	}
	ext := filepath.Ext(path)
	if ext == "" {
		ext = ".bin"
	}
	if err := os.MkdirAll(audioWorkDir, 0o700); err != nil {
		return err
	}
	plain := filepath.Join(audioWorkDir, "plain-"+tok+ext)
	if err := filebox.DecryptFile(path, plain, key, FileMagic); err != nil {
		return err
	}
	defer os.Remove(plain)
	return fn(plain)
}
