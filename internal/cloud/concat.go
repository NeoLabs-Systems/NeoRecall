package cloud

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

type audioPart struct {
	Sequence  int
	File      string
	OverlapMs int64
}

type wavParsed struct {
	PCM        []byte
	SampleRate uint32
	Channels   uint16
	ByteRate   uint32
	BlockAlign uint16
}

func parseWAV(data []byte) *wavParsed {
	if len(data) < 44 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return nil
	}
	off := 12
	var sr, br uint32
	var ch, ba uint16
	var dStart, dSize int
	foundData := false
	for off+8 <= len(data) {
		id := string(data[off : off+4])
		sz := int(binary.LittleEndian.Uint32(data[off+4 : off+8]))
		if id == "fmt " && sz >= 16 && off+8+16 <= len(data) {
			ch = binary.LittleEndian.Uint16(data[off+10 : off+12])
			sr = binary.LittleEndian.Uint32(data[off+12 : off+16])
			br = binary.LittleEndian.Uint32(data[off+16 : off+20])
			ba = binary.LittleEndian.Uint16(data[off+20 : off+22])
		}
		if id == "data" {
			dStart = off + 8
			dSize = sz
			foundData = true
			break
		}
		off += 8 + sz + (sz % 2)
	}
	if !foundData || br == 0 || ch == 0 {
		return nil
	}
	end := min(len(data), dStart+dSize)
	if sr == 0 {
		sr = 16000
	}
	if ba == 0 {
		ba = ch * 2
	}
	return &wavParsed{PCM: data[dStart:end], SampleRate: sr, Channels: ch, ByteRate: br, BlockAlign: ba}
}

func wrapWAV(pcm []byte, sr uint32, ch uint16) []byte {
	ba := ch * 2
	br := sr * uint32(ba)
	var buf bytes.Buffer
	buf.Grow(44 + len(pcm))
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(36+len(pcm)))
	buf.WriteString("WAVEfmt ")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(16))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1))
	_ = binary.Write(&buf, binary.LittleEndian, ch)
	_ = binary.Write(&buf, binary.LittleEndian, sr)
	_ = binary.Write(&buf, binary.LittleEndian, br)
	_ = binary.Write(&buf, binary.LittleEndian, ba)
	_ = binary.Write(&buf, binary.LittleEndian, uint16(16))
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(len(pcm)))
	buf.Write(pcm)
	return buf.Bytes()
}

func concatWAVParts(key []byte, parts []audioPart, dest string) bool {
	var sr uint32
	var ch uint16
	var br uint32
	var ba uint16
	var pcm bytes.Buffer
	for idx, p := range parts {
		raw, err := crypto.ReadSealedFile(key, p.File)
		if err != nil {
			return false
		}
		wav := parseWAV(raw)
		if wav == nil {
			return false
		}
		if idx == 0 {
			sr, ch, br, ba = wav.SampleRate, wav.Channels, wav.ByteRate, wav.BlockAlign
		} else if wav.SampleRate != sr || wav.Channels != ch {
			return false
		}
		chunk := wav.PCM
		if idx > 0 && p.OverlapMs > 0 {
			skip := min(len(chunk), int((float64(p.OverlapMs)/1000.0)*float64(br)))
			skip -= skip % int(max(1, ba))
			chunk = chunk[skip:]
		}
		pcm.Write(chunk)
	}
	return os.WriteFile(dest, wrapWAV(pcm.Bytes(), sr, ch), 0o600) == nil
}

func concatRecording(cfg config.Config, key []byte, parts []audioPart, dest string) error {
	if len(parts) == 0 {
		return fmt.Errorf("recording assembly has no audio parts")
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return err
	}
	if concatWAVParts(key, parts, dest) {
		return nil
	}
	ff := transcription.ResolveFFmpegPath()
	if ff == "" {
		return fmt.Errorf("ffmpeg is not available to join a recording")
	}
	tmpDir, err := os.MkdirTemp(filepath.Dir(dest), "concat-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	var lines []string
	for idx, p := range parts {
		plain, err := crypto.ReadSealedFile(key, p.File)
		if err != nil {
			return err
		}
		pf := filepath.Join(tmpDir, fmt.Sprintf("p%06d%s", idx, filepath.Ext(p.File)))
		if err := os.WriteFile(pf, plain, 0o600); err != nil {
			return err
		}
		escaped := strings.ReplaceAll(pf, "'", "'\\''")
		lines = append(lines, "file '"+escaped+"'")
		if idx > 0 && p.OverlapMs > 0 {
			lines = append(lines, fmt.Sprintf("inpoint %.3f", float64(p.OverlapMs)/1000.0))
		}
	}
	listPath := filepath.Join(tmpDir, "list.txt")
	if err := os.WriteFile(listPath, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		return err
	}
	timeout := time.Duration(max(10_000, cfg.CloudConcatTimeoutMs)) * time.Millisecond
	cmd := exec.Command(ff, "-hide_banner", "-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c:a", "pcm_s16le", dest)
	timer := time.AfterFunc(timeout, func() { _ = cmd.Process.Kill() })
	out, err := cmd.CombinedOutput()
	timer.Stop()
	if err != nil {
		return fmt.Errorf("ffmpeg could not join recording: %s", strings.TrimSpace(string(out)))
	}
	_ = os.Chmod(dest, 0o600)
	return nil
}
