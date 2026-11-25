package cloud

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/NeoLabs-Systems/neolabs-go/audiox"
	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/NeoLabs-Systems/neorecall/internal/crypto"
	"github.com/NeoLabs-Systems/neorecall/internal/transcription"
)

type audioPart struct {
	Sequence  int
	File      string
	OverlapMs int64
}

func concatWAVParts(key []byte, parts []audioPart, dest string) bool {
	var base audiox.PCMFormat
	var pcm bytes.Buffer
	for idx, p := range parts {
		raw, err := crypto.ReadSealedFile(key, p.File)
		if err != nil {
			return false
		}
		chunk, wf, err := audiox.ParseWAV(raw)
		if err != nil || wf.Channels <= 0 {
			return false
		}
		if wf.SampleRate <= 0 {
			wf.SampleRate = 16000
		}
		if idx == 0 {
			base = wf
		} else if wf.SampleRate != base.SampleRate || wf.Channels != base.Channels {
			return false
		}
		if idx > 0 && p.OverlapMs > 0 {
			blockAlign := max(1, base.Channels*(base.BitsPerSample/8))
			byteRate := base.SampleRate * blockAlign
			skip := min(len(chunk), int((float64(p.OverlapMs)/1000.0)*float64(byteRate)))
			skip -= skip % blockAlign
			chunk = chunk[skip:]
		}
		pcm.Write(chunk)
	}
	return os.WriteFile(dest, audiox.WrapWAV(pcm.Bytes(), base), 0o600) == nil
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
