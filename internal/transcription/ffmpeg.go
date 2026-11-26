package transcription

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/google/uuid"
)

type DecodedChannel struct {
	Name       string
	Samples    []float32
	SampleRate int
}

// ResolveFFmpegPath locates ffmpeg from NEORECALL_FFMPEG_PATH, then beside this
// program (the runtime ships it, and an updated service may keep an old PATH),
// then PATH.
func ResolveFFmpegPath() string {
	if custom := strings.TrimSpace(os.Getenv("NEORECALL_FFMPEG_PATH")); custom != "" {
		if _, err := os.Stat(custom); err == nil {
			return custom
		}
	}
	if exe, err := os.Executable(); err == nil {
		name := "ffmpeg"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		beside := filepath.Join(filepath.Dir(exe), name)
		if info, err := os.Stat(beside); err == nil && info.Mode().IsRegular() {
			return beside
		}
	}
	p, err := exec.LookPath("ffmpeg")
	if err != nil {
		return ""
	}
	return p
}

func ChannelCount(layout string) (int, error) {
	switch layout {
	case "mono":
		return 1, nil
	case "stereo", "microphone_left_system_right":
		return 2, nil
	default:
		return 0, fmt.Errorf("UNSUPPORTED_CHANNEL_LAYOUT: unsupported channel layout: %s", layout)
	}
}

// DecodeAudio converts any supported input container to 16 kHz float32 channels via ffmpeg.
func DecodeAudio(ctx context.Context, ffmpegPath, filename, layout string) ([]DecodedChannel, error) {
	if ffmpegPath == "" {
		return nil, errors.New("AUDIO_DECODE_FAILED: ffmpeg binary not available")
	}
	channels, err := ChannelCount(layout)
	if err != nil {
		return nil, err
	}
	cmd := exec.CommandContext(ctx, ffmpegPath,
		"-v", "error", "-i", filename, "-vn",
		"-ac", fmt.Sprintf("%d", channels),
		"-ar", "16000", "-f", "f32le", "pipe:1",
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := stderr.String()
		if len(msg) > 500 {
			msg = msg[:500]
		}
		return nil, fmt.Errorf("AUDIO_DECODE_FAILED: ffmpeg could not decode the chunk: %s (%w)", msg, err)
	}
	b := stdout.Bytes()
	n := len(b) / 4
	raw := make([]float32, n)
	for i := range n {
		raw[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[i*4 : (i+1)*4]))
	}
	if channels == 1 {
		return []DecodedChannel{{Name: "combined", Samples: raw, SampleRate: 16000}}, nil
	}
	half := n / 2
	left := make([]float32, half)
	right := make([]float32, half)
	for i := range half {
		left[i] = raw[i*2]
		right[i] = raw[i*2+1]
	}
	names := [2]string{"left", "right"}
	if layout == "microphone_left_system_right" {
		names = [2]string{"microphone", "system"}
	}
	return []DecodedChannel{
		{Name: names[0], Samples: left, SampleRate: 16000},
		{Name: names[1], Samples: right, SampleRate: 16000},
	}, nil
}

var (
	filterLineRe   = regexp.MustCompile(`^\s*[A-Z.]+\s+(\S+)\s`)
	loudnormJSONRe = regexp.MustCompile(`\{[^{}]*"input_i"[\s\S]*?\}`)

	probedMu      sync.Mutex
	probedFFmpeg  string
	probedFilters map[string]bool
)

func AvailableFilters(ffmpegPath string) map[string]bool {
	if ffmpegPath == "" {
		return nil
	}
	probedMu.Lock()
	defer probedMu.Unlock()
	if probedFFmpeg == ffmpegPath && probedFilters != nil {
		return probedFilters
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, ffmpegPath, "-hide_banner", "-filters").Output()
	if err != nil {
		return nil
	}
	m := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if sub := filterLineRe.FindStringSubmatch(line); len(sub) == 2 {
			m[sub[1]] = true
		}
	}
	if len(m) == 0 {
		return nil
	}
	probedFFmpeg = ffmpegPath
	probedFilters = m
	return m
}

func BuildPreprocessFilters(cfg config.Config, supported map[string]bool, log *slog.Logger) (applied []string, chain []string) {
	type stageSpec struct {
		name   string
		filter string
		spec   string
	}
	var candidates []stageSpec
	if cfg.AudioPreprocessHighpassHz > 0 {
		candidates = append(candidates, stageSpec{
			name:   "highpass",
			filter: "highpass",
			spec:   fmt.Sprintf("highpass=f=%d:p=2", cfg.AudioPreprocessHighpassHz),
		})
	}
	if cfg.AudioPreprocessDenoiseEnabled {
		candidates = append(candidates, stageSpec{
			name:   "denoise",
			filter: "afftdn",
			spec:   fmt.Sprintf("afftdn=nr=%g:nf=%g:tn=1", cfg.AudioPreprocessDenoiseDb, cfg.AudioPreprocessDenoiseFloorDb),
		})
	}
	switch cfg.AudioPreprocessNormalizer {
	case "dynaudnorm":
		candidates = append(candidates, stageSpec{
			name:   "normalize",
			filter: "dynaudnorm",
			spec:   fmt.Sprintf("dynaudnorm=f=200:g=15:p=0.9:m=%g:t=0.02:n=1", cfg.AudioPreprocessMaxGain),
		})
	case "loudnorm":
		candidates = append(candidates, stageSpec{
			name:   "normalize",
			filter: "loudnorm",
			spec:   fmt.Sprintf("loudnorm=I=%g:TP=%g:LRA=11:print_format=json", cfg.AudioPreprocessTargetLufs, cfg.AudioPreprocessTruePeakDb),
		})
	case "speechnorm":
		candidates = append(candidates, stageSpec{
			name:   "normalize",
			filter: "speechnorm",
			spec:   fmt.Sprintf("speechnorm=e=%g:r=0.0001:l=1", cfg.AudioPreprocessMaxGain),
		})
	}
	if cfg.AudioPreprocessLimiterEnabled {
		candidates = append(candidates, stageSpec{
			name:   "limiter",
			filter: "alimiter",
			spec:   fmt.Sprintf("alimiter=limit=%g:level=false:latency=true", cfg.AudioPreprocessLimiterPeak),
		})
	}
	for _, st := range candidates {
		if len(supported) > 0 && !supported[st.filter] {
			if log != nil {
				log.Warn("Skipping audio conditioning stage missing in ffmpeg", "stage", st.name, "filter", st.filter)
			}
			continue
		}
		applied = append(applied, st.name)
		chain = append(chain, st.spec)
	}
	return applied, chain
}

type PreprocessResult struct {
	Filename   string
	Applied    []string
	Seconds    float64
	FellBack   bool
	InputLUFS  *float64
	OutputLUFS *float64
	Cleanup    func()
}

func MeasuredLoudness(stderr string) (inLUFS, outLUFS *float64) {
	raw := loudnormJSONRe.FindString(stderr)
	if raw == "" {
		return nil, nil
	}
	var parsed struct {
		InputI  any `json:"input_i"`
		OutputI any `json:"output_i"`
	}
	if json.Unmarshal([]byte(raw), &parsed) != nil {
		return nil, nil
	}
	toFloat := func(v any) *float64 {
		switch x := v.(type) {
		case float64:
			if !math.IsNaN(x) && !math.IsInf(x, 0) {
				return &x
			}
		case string:
			var f float64
			if _, err := fmt.Sscanf(x, "%f", &f); err == nil && !math.IsNaN(f) && !math.IsInf(f, 0) {
				return &f
			}
		}
		return nil
	}
	return toFloat(parsed.InputI), toFloat(parsed.OutputI)
}

// PreparePreprocess conditions a chunk using sample-exact ffmpeg filters and
// guarantees a usable passthrough result if anything goes wrong.
func PreparePreprocess(ctx context.Context, ffmpegPath string, cfg config.Config, filename, channelLayout string, durationMs int, log *slog.Logger) PreprocessResult {
	passthrough := PreprocessResult{
		Filename: filename,
		Cleanup:  func() {},
	}
	if !cfg.AudioPreprocessEnabled || ffmpegPath == "" {
		return passthrough
	}
	if cfg.AudioPreprocessMaxDurationMs > 0 && durationMs > cfg.AudioPreprocessMaxDurationMs {
		return passthrough
	}
	if channelLayout == "" {
		channelLayout = "mono"
	}
	applied, chain := BuildPreprocessFilters(cfg, AvailableFilters(ffmpegPath), log)
	if len(chain) == 0 {
		return passthrough
	}
	channels, err := ChannelCount(channelLayout)
	if err != nil {
		return passthrough
	}
	_ = os.MkdirAll(cfg.Paths.AudioWork, 0o700)
	format := cfg.AudioPreprocessFormat
	if format != "flac" {
		format = "wav"
	}
	codec := "pcm_s16le"
	if format == "flac" {
		codec = "flac"
	}
	outPath := filepath.Join(cfg.Paths.AudioWork, uuid.NewString()+"."+format)
	cleanup := func() { _ = os.Remove(outPath) }

	timeout := time.Duration(max(1000, cfg.AudioPreprocessTimeoutMs)) * time.Millisecond
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	vLevel := "error"
	if cfg.AudioPreprocessNormalizer == "loudnorm" {
		vLevel = "info"
	}
	started := time.Now()
	cmd := exec.CommandContext(tctx, ffmpegPath,
		"-hide_banner", "-nostdin",
		"-v", vLevel, "-y",
		"-i", filename,
		"-vn", "-map", "0:a:0",
		"-af", strings.Join(chain, ","),
		"-ar", fmt.Sprintf("%d", cfg.AudioPreprocessSampleRate),
		"-ac", fmt.Sprintf("%d", channels),
		"-c:a", codec,
		"-f", format,
		outPath,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		cleanup()
		if log != nil {
			log.Warn("Audio conditioning failed; using original chunk", "error", err)
		}
		passthrough.FellBack = true
		return passthrough
	}
	st, err := os.Stat(outPath)
	if err != nil {
		cleanup()
		passthrough.FellBack = true
		return passthrough
	}
	var expected int64
	if durationMs > 0 && format == "wav" {
		expected = int64((float64(durationMs) / 1000.0) * float64(cfg.AudioPreprocessSampleRate) * float64(channels) * 2.0)
	}
	if st.Size() < 1024 || (expected > 0 && st.Size() < expected/4) {
		cleanup()
		passthrough.FellBack = true
		return passthrough
	}
	inL, outL := MeasuredLoudness(stderr.String())
	return PreprocessResult{
		Filename:   outPath,
		Applied:    applied,
		Seconds:    time.Since(started).Seconds(),
		InputLUFS:  inL,
		OutputLUFS: outL,
		Cleanup:    cleanup,
	}
}
