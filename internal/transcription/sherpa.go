package transcription

import (
	"context"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"unsafe"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/ebitengine/purego"
)

var RequiredAnalysisModels = []string{
	"vad/silero_vad.onnx",
	"diarization/pyannote-segmentation-3.0.int8.onnx",
	"diarization/wespeaker_en_voxceleb_CAM++_LM.onnx",
}

// C ABI structs matching sherpa-onnx v1.13.4 c-api.h (LP64 aligned).
type cSileroVadModelConfig struct {
	Model              *byte
	Threshold          float32
	MinSilenceDuration float32
	MinSpeechDuration  float32
	WindowSize         int32
	MaxSpeechDuration  float32
}

type cTenVadModelConfig struct {
	Model              *byte
	Threshold          float32
	MinSilenceDuration float32
	MinSpeechDuration  float32
	WindowSize         int32
	MaxSpeechDuration  float32
}

type cVadModelConfig struct {
	SileroVad  cSileroVadModelConfig
	SampleRate int32
	NumThreads int32
	Provider   *byte
	Debug      int32
	TenVad     cTenVadModelConfig
}

type cSpeechSegment struct {
	Start   int32
	Samples *float32
	N       int32
}

type cSpeakerEmbeddingExtractorConfig struct {
	Model      *byte
	NumThreads int32
	Debug      int32
	Provider   *byte
}

type cOfflineSpeakerSegmentationPyannoteModelConfig struct {
	Model *byte
}

type cOfflineSpeakerSegmentationModelConfig struct {
	Pyannote   cOfflineSpeakerSegmentationPyannoteModelConfig
	NumThreads int32
	Debug      int32
	Provider   *byte
}

type cFastClusteringConfig struct {
	NumClusters int32
	Threshold   float32
}

type cOfflineSpeakerDiarizationConfig struct {
	Segmentation   cOfflineSpeakerSegmentationModelConfig
	Embedding      cSpeakerEmbeddingExtractorConfig
	Clustering     cFastClusteringConfig
	MinDurationOn  float32
	MinDurationOff float32
}

type cOfflineSpeakerDiarizationSegment struct {
	Start   float32
	End     float32
	Speaker int32
}

func cStringBytes(s string) []byte {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return b
}

type sherpaLib struct {
	createVAD      func(*cVadModelConfig, float32) uintptr
	destroyVAD     func(uintptr)
	vadAccept      func(uintptr, *float32, int32)
	vadEmpty       func(uintptr) int32
	vadFlush       func(uintptr)
	vadReset       func(uintptr)
	vadFront       func(uintptr) *cSpeechSegment
	vadPop         func(uintptr)
	destroySegment func(*cSpeechSegment)

	createDiarizer       func(*cOfflineSpeakerDiarizationConfig) uintptr
	destroyDiarizer      func(uintptr)
	diarizeProcess       func(uintptr, *float32, int32) uintptr
	diarizeNumSegs       func(uintptr) int32
	diarizeSortSegments  func(uintptr) *cOfflineSpeakerDiarizationSegment
	diarizeDestroySegs   func(*cOfflineSpeakerDiarizationSegment)
	diarizeDestroyResult func(uintptr)

	createExtractor  func(*cSpeakerEmbeddingExtractorConfig) uintptr
	destroyExtractor func(uintptr)
	extractorDim     func(uintptr) int32
	createStream     func(uintptr) uintptr
	destroyStream    func(uintptr)
	streamAccept     func(uintptr, int32, *float32, int32)
	streamFinished   func(uintptr)
	extractorIsReady func(uintptr, uintptr) int32
	computeEmbedding func(uintptr, uintptr) *float32
	destroyEmbedding func(*float32)
}

var (
	sherpaMu       sync.Mutex
	sherpaLoaded   *sherpaLib
	sherpaAttempt  bool
	sherpaWarnOnce sync.Once
)

func candidateRuntimeDirs(cfg config.Config) []string {
	var dirs []string
	if d := os.Getenv("NEORECALL_RUNTIME_DIR"); d != "" {
		dirs = append(dirs, d)
	}
	if cfg.Paths.RuntimeDir != "" {
		dirs = append(dirs, cfg.Paths.RuntimeDir)
	}
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs, filepath.Dir(exe), filepath.Join(filepath.Dir(exe), "runtime"))
	}
	platDir := "sherpa-onnx-" + runtime.GOOS + "-" + runtime.GOARCH
	if runtime.GOARCH == "amd64" {
		platDir = "sherpa-onnx-" + runtime.GOOS + "-x64"
	}
	dirs = append(dirs,
		filepath.Join("node_modules", platDir),
		filepath.Join("..", "..", "node_modules", platDir),
		"/usr/local/lib",
		"/usr/lib",
	)
	return dirs
}

func libNames() (ortName, sherpaName string) {
	switch runtime.GOOS {
	case "darwin":
		return "libonnxruntime.dylib", "libsherpa-onnx-c-api.dylib"
	default:
		return "libonnxruntime.so", "libsherpa-onnx-c-api.so"
	}
}

func loadSherpa(cfg config.Config) (*sherpaLib, error) {
	sherpaMu.Lock()
	defer sherpaMu.Unlock()
	if sherpaLoaded != nil {
		return sherpaLoaded, nil
	}
	ortName, sherpaName := libNames()
	var sherpaHandle uintptr
	var lastErr error
	for _, dir := range candidateRuntimeDirs(cfg) {
		cand := filepath.Join(dir, sherpaName)
		if _, err := os.Stat(cand); err != nil {
			continue
		}
		ortCand := filepath.Join(dir, ortName)
		if _, err := os.Stat(ortCand); err == nil {
			_, _ = openSharedLib(ortCand)
		}
		h, err := openSharedLib(cand)
		if err == nil {
			sherpaHandle = h
			break
		}
		lastErr = err
	}
	if sherpaHandle == 0 {
		if h, err := openSharedLib(sherpaName); err == nil {
			sherpaHandle = h
		} else {
			lastErr = err
		}
	}
	if sherpaHandle == 0 {
		sherpaAttempt = true
		if lastErr == nil {
			lastErr = fmt.Errorf("%s not found", sherpaName)
		}
		return nil, lastErr
	}

	s := &sherpaLib{}
	purego.RegisterLibFunc(&s.createVAD, sherpaHandle, "SherpaOnnxCreateVoiceActivityDetector")
	purego.RegisterLibFunc(&s.destroyVAD, sherpaHandle, "SherpaOnnxDestroyVoiceActivityDetector")
	purego.RegisterLibFunc(&s.vadAccept, sherpaHandle, "SherpaOnnxVoiceActivityDetectorAcceptWaveform")
	purego.RegisterLibFunc(&s.vadEmpty, sherpaHandle, "SherpaOnnxVoiceActivityDetectorEmpty")
	purego.RegisterLibFunc(&s.vadFlush, sherpaHandle, "SherpaOnnxVoiceActivityDetectorFlush")
	purego.RegisterLibFunc(&s.vadReset, sherpaHandle, "SherpaOnnxVoiceActivityDetectorReset")
	purego.RegisterLibFunc(&s.vadFront, sherpaHandle, "SherpaOnnxVoiceActivityDetectorFront")
	purego.RegisterLibFunc(&s.vadPop, sherpaHandle, "SherpaOnnxVoiceActivityDetectorPop")
	purego.RegisterLibFunc(&s.destroySegment, sherpaHandle, "SherpaOnnxDestroySpeechSegment")

	purego.RegisterLibFunc(&s.createDiarizer, sherpaHandle, "SherpaOnnxCreateOfflineSpeakerDiarization")
	purego.RegisterLibFunc(&s.destroyDiarizer, sherpaHandle, "SherpaOnnxDestroyOfflineSpeakerDiarization")
	purego.RegisterLibFunc(&s.diarizeProcess, sherpaHandle, "SherpaOnnxOfflineSpeakerDiarizationProcess")
	purego.RegisterLibFunc(&s.diarizeNumSegs, sherpaHandle, "SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments")
	purego.RegisterLibFunc(&s.diarizeSortSegments, sherpaHandle, "SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime")
	purego.RegisterLibFunc(&s.diarizeDestroySegs, sherpaHandle, "SherpaOnnxOfflineSpeakerDiarizationDestroySegment")
	purego.RegisterLibFunc(&s.diarizeDestroyResult, sherpaHandle, "SherpaOnnxOfflineSpeakerDiarizationDestroyResult")

	purego.RegisterLibFunc(&s.createExtractor, sherpaHandle, "SherpaOnnxCreateSpeakerEmbeddingExtractor")
	purego.RegisterLibFunc(&s.destroyExtractor, sherpaHandle, "SherpaOnnxDestroySpeakerEmbeddingExtractor")
	purego.RegisterLibFunc(&s.extractorDim, sherpaHandle, "SherpaOnnxSpeakerEmbeddingExtractorDim")
	purego.RegisterLibFunc(&s.createStream, sherpaHandle, "SherpaOnnxSpeakerEmbeddingExtractorCreateStream")
	purego.RegisterLibFunc(&s.destroyStream, sherpaHandle, "SherpaOnnxDestroyOnlineStream")
	purego.RegisterLibFunc(&s.streamAccept, sherpaHandle, "SherpaOnnxOnlineStreamAcceptWaveform")
	purego.RegisterLibFunc(&s.streamFinished, sherpaHandle, "SherpaOnnxOnlineStreamInputFinished")
	purego.RegisterLibFunc(&s.extractorIsReady, sherpaHandle, "SherpaOnnxSpeakerEmbeddingExtractorIsReady")
	purego.RegisterLibFunc(&s.computeEmbedding, sherpaHandle, "SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding")
	purego.RegisterLibFunc(&s.destroyEmbedding, sherpaHandle, "SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding")

	sherpaLoaded = s
	return s, nil
}

type SpeechSegment struct {
	StartSample int
	Samples     []float32
}

type AnalysisResult struct {
	Analyzed  bool   `json:"analyzed"`
	HasSpeech bool   `json:"hasSpeech"`
	Turns     []Turn `json:"turns"`
}

// LocalAnalyzer runs Silero VAD and Pyannote+WeSpeaker diarization over chunks.
type LocalAnalyzer struct {
	Cfg        func() config.Config
	FFmpegPath string
	Log        *slog.Logger

	mu        sync.Mutex
	lib       *sherpaLib
	vad       uintptr
	diarizer  uintptr
	extractor uintptr
	embDim    int
}

func (a *LocalAnalyzer) cfg() config.Config {
	if a.Cfg != nil {
		return a.Cfg()
	}
	return config.Config{}
}

func (a *LocalAnalyzer) ModelsPresent() bool {
	c := a.cfg()
	for _, rel := range RequiredAnalysisModels {
		if _, err := os.Stat(filepath.Join(c.Paths.Models, rel)); err != nil {
			return false
		}
	}
	return true
}

func (a *LocalAnalyzer) Available() bool {
	c := a.cfg()
	if !c.DiarizationEnabled {
		return false
	}
	if !a.ModelsPresent() {
		sherpaWarnOnce.Do(func() {
			if a.Log != nil {
				a.Log.Warn("Speech-detection and diarization models are not installed; transcripts will carry no speaker identity. Run `neorecall setup`.")
			}
		})
		return false
	}
	if _, err := loadSherpa(c); err != nil {
		sherpaWarnOnce.Do(func() {
			if a.Log != nil {
				a.Log.Warn("The native audio runtime is unavailable on this platform; transcripts will carry no speaker identity.", "error", err)
			}
		})
		return false
	}
	return true
}

func (a *LocalAnalyzer) ensureInit(c config.Config) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.vad != 0 && a.diarizer != 0 && a.extractor != 0 {
		return nil
	}
	lib, err := loadSherpa(c)
	if err != nil {
		return err
	}
	a.lib = lib
	cpu := cStringBytes("cpu")
	sileroPath := cStringBytes(filepath.Join(c.Paths.Models, "vad", "silero_vad.onnx"))
	pyannotePath := cStringBytes(filepath.Join(c.Paths.Models, "diarization", "pyannote-segmentation-3.0.int8.onnx"))
	wespeakerPath := cStringBytes(filepath.Join(c.Paths.Models, "diarization", "wespeaker_en_voxceleb_CAM++_LM.onnx"))

	threads := int32(max(1, c.SherpaThreads))
	maxSpeechSec := float32(max(1, c.ChunkMaxMs)) / 1000.0
	if a.vad == 0 {
		vadCfg := cVadModelConfig{
			SileroVad: cSileroVadModelConfig{
				Model:              &sileroPath[0],
				Threshold:          float32(c.VADThreshold),
				MinSilenceDuration: float32(c.VADMinimumSilenceSeconds),
				MinSpeechDuration:  float32(c.VADMinimumSpeechSeconds),
				WindowSize:         512,
				MaxSpeechDuration:  maxSpeechSec,
			},
			SampleRate: 16000,
			NumThreads: threads,
			Provider:   &cpu[0],
		}
		a.vad = lib.createVAD(&vadCfg, maxSpeechSec+5.0)
		runtime.KeepAlive(sileroPath)
		runtime.KeepAlive(cpu)
		if a.vad == 0 {
			return fmt.Errorf("failed to initialize Silero VAD")
		}
	}
	if a.diarizer == 0 {
		dCfg := cOfflineSpeakerDiarizationConfig{
			Segmentation: cOfflineSpeakerSegmentationModelConfig{
				Pyannote:   cOfflineSpeakerSegmentationPyannoteModelConfig{Model: &pyannotePath[0]},
				NumThreads: threads,
				Provider:   &cpu[0],
			},
			Embedding: cSpeakerEmbeddingExtractorConfig{
				Model:      &wespeakerPath[0],
				NumThreads: threads,
				Provider:   &cpu[0],
			},
			Clustering: cFastClusteringConfig{
				NumClusters: -1,
				Threshold:   float32(c.DiarizationClusterDistance),
			},
			MinDurationOn:  float32(c.DiarizationMinimumOnSeconds),
			MinDurationOff: float32(c.DiarizationMinimumOffSeconds),
		}
		a.diarizer = lib.createDiarizer(&dCfg)
		runtime.KeepAlive(pyannotePath)
		runtime.KeepAlive(wespeakerPath)
		runtime.KeepAlive(cpu)
		if a.diarizer == 0 {
			return fmt.Errorf("failed to initialize OfflineSpeakerDiarization")
		}
	}
	if a.extractor == 0 {
		eCfg := cSpeakerEmbeddingExtractorConfig{
			Model:      &wespeakerPath[0],
			NumThreads: threads,
			Provider:   &cpu[0],
		}
		a.extractor = lib.createExtractor(&eCfg)
		runtime.KeepAlive(wespeakerPath)
		runtime.KeepAlive(cpu)
		if a.extractor == 0 {
			return fmt.Errorf("failed to initialize SpeakerEmbeddingExtractor")
		}
		a.embDim = int(lib.extractorDim(a.extractor))
	}
	return nil
}

func (a *LocalAnalyzer) Close() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.lib != nil {
		if a.vad != 0 {
			a.lib.destroyVAD(a.vad)
			a.vad = 0
		}
		if a.diarizer != 0 {
			a.lib.destroyDiarizer(a.diarizer)
			a.diarizer = 0
		}
		if a.extractor != 0 {
			a.lib.destroyExtractor(a.extractor)
			a.extractor = 0
		}
	}
}

func (a *LocalAnalyzer) speechSegments(samples []float32) []SpeechSegment {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.lib.vadReset(a.vad)
	const win = 512
	frame := make([]float32, win)
	for off := 0; off < len(samples); off += win {
		clear(frame)
		end := min(len(samples), off+win)
		copy(frame, samples[off:end])
		a.lib.vadAccept(a.vad, &frame[0], int32(win))
	}
	runtime.KeepAlive(frame)
	a.lib.vadFlush(a.vad)
	var out []SpeechSegment
	for a.lib.vadEmpty(a.vad) == 0 {
		seg := a.lib.vadFront(a.vad)
		if seg != nil {
			n := int(seg.N)
			cp := make([]float32, n)
			if n > 0 && seg.Samples != nil {
				copy(cp, unsafe.Slice(seg.Samples, n))
			}
			out = append(out, SpeechSegment{StartSample: int(seg.Start), Samples: cp})
			a.lib.destroySegment(seg)
		}
		a.lib.vadPop(a.vad)
	}
	return out
}

func (a *LocalAnalyzer) embeddingForSpan(samples []float32, startSec, endSec float32) []float32 {
	start := max(0, int(math.Floor(float64(startSec)*16000.0)))
	end := min(len(samples), int(math.Ceil(float64(endSec)*16000.0)))
	if end <= start {
		return nil
	}
	stream := a.lib.createStream(a.extractor)
	if stream == 0 {
		return nil
	}
	defer a.lib.destroyStream(stream)
	span := samples[start:end]
	a.lib.streamAccept(stream, 16000, &span[0], int32(len(span)))
	a.lib.streamFinished(stream)
	runtime.KeepAlive(span)
	if a.lib.extractorIsReady(a.extractor, stream) == 0 {
		return nil
	}
	ptr := a.lib.computeEmbedding(a.extractor, stream)
	if ptr == nil {
		return nil
	}
	defer a.lib.destroyEmbedding(ptr)
	vec := make([]float32, a.embDim)
	copy(vec, unsafe.Slice(ptr, a.embDim))
	return vec
}

// PoolBySpeaker averages each speaker cluster's embeddings across a chunk
// weighted by turn duration.
func PoolBySpeaker(turns []Turn) map[int]struct {
	Embedding []float32
	SpeechMs  int
} {
	grouped := make(map[int][]Turn)
	for _, t := range turns {
		if len(t.Embedding) == 0 {
			continue
		}
		grouped[t.Speaker] = append(grouped[t.Speaker], t)
	}
	pooled := make(map[int]struct {
		Embedding []float32
		SpeechMs  int
	}, len(grouped))
	for spk, list := range grouped {
		dim := len(list[0].Embedding)
		total := make([]float32, dim)
		weight := 0
		for _, t := range list {
			if len(t.Embedding) != dim {
				continue
			}
			dur := max(1, t.EndMs-t.StartMs)
			weight += dur
			for i := range dim {
				total[i] += t.Embedding[i] * float32(dur)
			}
		}
		if weight > 0 {
			for i := range dim {
				total[i] /= float32(weight)
			}
			pooled[spk] = struct {
				Embedding []float32
				SpeechMs  int
			}{Embedding: total, SpeechMs: weight}
		}
	}
	return pooled
}

func (a *LocalAnalyzer) diarizeSamples(samples []float32) []Turn {
	if len(samples) == 0 {
		return nil
	}
	a.mu.Lock()
	res := a.lib.diarizeProcess(a.diarizer, &samples[0], int32(len(samples)))
	runtime.KeepAlive(samples)
	if res == 0 {
		a.mu.Unlock()
		return nil
	}
	nSeg := int(a.lib.diarizeNumSegs(res))
	var rawTurns []Turn
	if nSeg > 0 {
		segsPtr := a.lib.diarizeSortSegments(res)
		if segsPtr != nil {
			segs := unsafe.Slice(segsPtr, nSeg)
			for _, seg := range segs {
				emb := a.embeddingForSpan(samples, seg.Start, seg.End)
				rawTurns = append(rawTurns, Turn{
					StartMs:   int(math.Round(float64(seg.Start) * 1000.0)),
					EndMs:     int(math.Round(float64(seg.End) * 1000.0)),
					Speaker:   int(seg.Speaker),
					Embedding: emb,
				})
			}
			a.lib.diarizeDestroySegs(segsPtr)
		}
	}
	a.lib.diarizeDestroyResult(res)
	a.mu.Unlock()

	pooled := PoolBySpeaker(rawTurns)
	out := make([]Turn, len(rawTurns))
	for i, t := range rawTurns {
		if voice, ok := pooled[t.Speaker]; ok {
			t.Embedding = voice.Embedding
			t.SpeechMs = voice.SpeechMs
		} else {
			t.SpeechMs = 0
		}
		out[i] = t
	}
	return out
}

func (a *LocalAnalyzer) Analyze(ctx context.Context, filename string) (AnalysisResult, error) {
	if !a.Available() {
		return AnalysisResult{Analyzed: false, HasSpeech: true}, nil
	}
	c := a.cfg()
	if err := a.ensureInit(c); err != nil {
		return AnalysisResult{Analyzed: false, HasSpeech: true}, err
	}
	ff := a.FFmpegPath
	if ff == "" {
		ff = ResolveFFmpegPath()
	}
	chans, err := DecodeAudio(ctx, ff, filename, "mono")
	if err != nil {
		return AnalysisResult{}, err
	}
	samples := chans[0].Samples
	speech := a.speechSegments(samples)
	if len(speech) == 0 {
		return AnalysisResult{Analyzed: true, HasSpeech: false}, nil
	}
	turns := a.diarizeSamples(samples)
	return AnalysisResult{Analyzed: true, HasSpeech: true, Turns: turns}, nil
}
