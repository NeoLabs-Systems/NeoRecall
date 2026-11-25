package crypto

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type nodeVectors struct {
	KeyHex       string `json:"keyHex"`
	StrPlain     string `json:"strPlain"`
	StrEnc       string `json:"strEnc"`
	BufPlainHex  string `json:"bufPlainHex"`
	BufSealedHex string `json:"bufSealedHex"`
	FilePlainHex string `json:"filePlainHex"`
	NRF1Hex      string `json:"nrf1Hex"`
	NRB1Hex      string `json:"nrb1Hex"`
}

func TestNodeVectorCompatibility(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "vectors.json"))
	if err != nil {
		t.Fatal(err)
	}
	var v nodeVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	key, err := hex.DecodeString(v.KeyHex)
	if err != nil {
		t.Fatal(err)
	}

	gotStr, err := DecryptString(key, v.StrEnc)
	if err != nil {
		t.Fatalf("DecryptString failed: %v", err)
	}
	if gotStr != v.StrPlain {
		t.Fatalf("got %q want %q", gotStr, v.StrPlain)
	}

	encStr, err := EncryptString(key, v.StrPlain)
	if err != nil {
		t.Fatal(err)
	}
	roundStr, err := DecryptString(key, encStr)
	if err != nil || roundStr != v.StrPlain {
		t.Fatalf("EncryptString round-trip failed: %v %q", err, roundStr)
	}

	bufPlain, _ := hex.DecodeString(v.BufPlainHex)
	bufSealed, _ := hex.DecodeString(v.BufSealedHex)
	if !IsSealedBuffer(key, bufSealed) {
		t.Fatal("IsSealedBuffer false for Node vector")
	}
	if gotBuf := UnsealBuffer(key, bufSealed); !bytes.Equal(gotBuf, bufPlain) {
		t.Fatalf("UnsealBuffer mismatch: %x vs %x", gotBuf, bufPlain)
	}
	if unsealed := UnsealBuffer(key, bufPlain); !bytes.Equal(unsealed, bufPlain) {
		t.Fatal("UnsealBuffer should pass through plaintext")
	}

	dir := t.TempDir()
	filePlain, _ := hex.DecodeString(v.FilePlainHex)
	nrf1Bytes, _ := hex.DecodeString(v.NRF1Hex)
	nrb1Bytes, _ := hex.DecodeString(v.NRB1Hex)

	nrf1Path := filepath.Join(dir, "vec.nrf1")
	nrb1Path := filepath.Join(dir, "vec.nrb1")
	_ = os.WriteFile(nrf1Path, nrf1Bytes, 0o600)
	_ = os.WriteFile(nrb1Path, nrb1Bytes, 0o600)

	gotNRF1, err := ReadSealedFile(key, nrf1Path)
	if err != nil {
		t.Fatalf("ReadSealedFile NRF1 failed: %v", err)
	}
	if !bytes.Equal(gotNRF1, filePlain) {
		t.Fatalf("NRF1 mismatch")
	}

	outNRB1 := filepath.Join(dir, "out.bin")
	if err := DecryptFile(key, nrb1Path, outNRB1, BackupMagic); err != nil {
		t.Fatalf("DecryptFile NRB1 failed: %v", err)
	}
	gotNRB1, _ := os.ReadFile(outNRB1)
	if !bytes.Equal(gotNRB1, filePlain) {
		t.Fatalf("NRB1 mismatch")
	}

	// Verify SealInPlace + WithPlain cleanup
	workDir := filepath.Join(dir, "work")
	audioFile := filepath.Join(dir, "chunk.wav")
	_ = os.WriteFile(audioFile, filePlain, 0o600)
	if err := SealInPlace(key, audioFile); err != nil {
		t.Fatal(err)
	}
	if !IsSealedFile(audioFile) {
		t.Fatal("expected sealed NRF1 file")
	}
	var seenPlain []byte
	if err := WithPlain(key, workDir, audioFile, func(p string) error {
		var err error
		seenPlain, err = os.ReadFile(p)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(seenPlain, filePlain) {
		t.Fatal("WithPlain content mismatch")
	}
	entries, _ := os.ReadDir(workDir)
	if len(entries) != 0 {
		t.Fatalf("WithPlain leaked temp files: %d", len(entries))
	}
}
