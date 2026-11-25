package embeddings

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"

	"github.com/NeoLabs-Systems/neorecall/internal/config"
	"github.com/ebitengine/purego"
)

const (
	ortAPIVersion   = 14
	ortLoggingError = 3

	ortDeviceAllocator = 0
	ortMemTypeDefault  = 0

	onnxTypeFloat = 1
	onnxTypeInt64 = 7
)

type ortAPI struct {
	getErrorMessage             func(status uintptr) *byte
	createEnv                   func(level int32, logID *byte, out *uintptr) uintptr
	createSession               func(env uintptr, modelPath *byte, opts uintptr, out *uintptr) uintptr
	run                         func(session, runOpts uintptr, inputNames **byte, inputs *uintptr, inputLen uintptr, outputNames **byte, outputLen uintptr, outputs *uintptr) uintptr
	createSessionOptions        func(out *uintptr) uintptr
	setGraphOptLevel            func(opts uintptr, level int32) uintptr
	setIntraOpNumThreads        func(opts uintptr, threads int32) uintptr
	sessionGetInputCount        func(session uintptr, out *uintptr) uintptr
	sessionGetOutputCount       func(session uintptr, out *uintptr) uintptr
	sessionGetInputName         func(session uintptr, idx, alloc uintptr, out **byte) uintptr
	sessionGetOutputName        func(session uintptr, idx, alloc uintptr, out **byte) uintptr
	createTensorWithData        func(memInfo uintptr, data unsafe.Pointer, dataBytes uintptr, shape *int64, shapeLen uintptr, elemType int32, out *uintptr) uintptr
	getTensorMutableData        func(val uintptr, out *unsafe.Pointer) uintptr
	getDimensionsCount          func(info uintptr, out *uintptr) uintptr
	getDimensions               func(info uintptr, dims *int64, len uintptr) uintptr
	getTensorShapeElementCount  func(info uintptr, out *uintptr) uintptr
	getTensorTypeAndShape       func(val uintptr, out *uintptr) uintptr
	createCpuMemoryInfo         func(allocType, memType int32, out *uintptr) uintptr
	allocatorFree               func(alloc uintptr, p unsafe.Pointer) uintptr
	getAllocatorWithDefaultOpts func(out *uintptr) uintptr
	releaseEnv                  func(uintptr)
	releaseStatus               func(uintptr)
	releaseMemoryInfo           func(uintptr)
	releaseSession              func(uintptr)
	releaseValue                func(uintptr)
	releaseTensorTypeAndShape   func(uintptr)
	releaseSessionOptions       func(uintptr)
}

var (
	ortMu     sync.Mutex
	ortLoaded *ortAPI
)

func ortLibName() string {
	if runtime.GOOS == "darwin" {
		return "libonnxruntime.dylib"
	}
	return "libonnxruntime.so"
}

func candidateORTDirs(cfg config.Config) []string {
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
	plat := runtime.GOOS + "-" + runtime.GOARCH
	if runtime.GOARCH == "amd64" {
		plat = runtime.GOOS + "-x64"
	}
	dirs = append(dirs,
		filepath.Join("node_modules", "sherpa-onnx-"+plat),
		filepath.Join("..", "..", "node_modules", "sherpa-onnx-"+plat),
		filepath.Join("node_modules", "onnxruntime-node", "bin", "napi-v3", runtime.GOOS, runtime.GOARCH),
		"/usr/local/lib",
		"/usr/lib",
	)
	return dirs
}

func HasONNXRuntime(cfg config.Config) bool {
	if ortLoaded != nil {
		return true
	}
	name := ortLibName()
	for _, dir := range candidateORTDirs(cfg) {
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return true
		}
	}
	return false
}

type ortVTable = [512]uintptr

func loadORT(cfg config.Config) (*ortAPI, error) {
	ortMu.Lock()
	defer ortMu.Unlock()
	if ortLoaded != nil {
		return ortLoaded, nil
	}
	name := ortLibName()
	var handle uintptr
	var lastErr error
	for _, dir := range candidateORTDirs(cfg) {
		cand := filepath.Join(dir, name)
		if _, err := os.Stat(cand); err != nil {
			continue
		}
		h, err := openSharedLib(cand)
		if err != nil {
			lastErr = err
			continue
		}
		handle = h
		break
	}
	if handle == 0 {
		h, err := openSharedLib(name)
		if err != nil {
			if lastErr != nil {
				return nil, lastErr
			}
			return nil, fmt.Errorf("onnxruntime library %s not found: %w", name, err)
		}
		handle = h
	}

	var getAPIBase func() *ortVTable
	purego.RegisterLibFunc(&getAPIBase, handle, "OrtGetApiBase")
	baseTbl := getAPIBase()
	if baseTbl == nil {
		return nil, fmt.Errorf("OrtGetApiBase returned nil")
	}
	var getAPI func(version uint32) *ortVTable
	purego.RegisterFunc(&getAPI, baseTbl[0])
	slots := getAPI(ortAPIVersion)
	if slots == nil {
		return nil, fmt.Errorf("OrtApiBase.GetApi(%d) returned nil", ortAPIVersion)
	}

	api := &ortAPI{}
	purego.RegisterFunc(&api.getErrorMessage, slots[2])
	purego.RegisterFunc(&api.createEnv, slots[3])
	purego.RegisterFunc(&api.createSession, slots[7])
	purego.RegisterFunc(&api.run, slots[9])
	purego.RegisterFunc(&api.createSessionOptions, slots[10])
	purego.RegisterFunc(&api.setGraphOptLevel, slots[23])
	purego.RegisterFunc(&api.setIntraOpNumThreads, slots[24])
	purego.RegisterFunc(&api.sessionGetInputCount, slots[30])
	purego.RegisterFunc(&api.sessionGetOutputCount, slots[31])
	purego.RegisterFunc(&api.sessionGetInputName, slots[36])
	purego.RegisterFunc(&api.sessionGetOutputName, slots[37])
	purego.RegisterFunc(&api.createTensorWithData, slots[49])
	purego.RegisterFunc(&api.getTensorMutableData, slots[51])
	purego.RegisterFunc(&api.getDimensionsCount, slots[61])
	purego.RegisterFunc(&api.getDimensions, slots[62])
	purego.RegisterFunc(&api.getTensorShapeElementCount, slots[64])
	purego.RegisterFunc(&api.getTensorTypeAndShape, slots[65])
	purego.RegisterFunc(&api.createCpuMemoryInfo, slots[69])
	purego.RegisterFunc(&api.allocatorFree, slots[76])
	purego.RegisterFunc(&api.getAllocatorWithDefaultOpts, slots[78])
	purego.RegisterFunc(&api.releaseEnv, slots[92])
	purego.RegisterFunc(&api.releaseStatus, slots[93])
	purego.RegisterFunc(&api.releaseMemoryInfo, slots[94])
	purego.RegisterFunc(&api.releaseSession, slots[95])
	purego.RegisterFunc(&api.releaseValue, slots[96])
	purego.RegisterFunc(&api.releaseTensorTypeAndShape, slots[99])
	purego.RegisterFunc(&api.releaseSessionOptions, slots[100])

	ortLoaded = api
	return api, nil
}

func (a *ortAPI) check(status uintptr, op string) error {
	if status == 0 {
		return nil
	}
	defer a.releaseStatus(status)
	msgPtr := a.getErrorMessage(status)
	if msgPtr == nil {
		return fmt.Errorf("onnxruntime %s failed", op)
	}
	return fmt.Errorf("onnxruntime %s: %s", op, goStringFromPtr(msgPtr))
}

func goStringFromPtr(p *byte) string {
	if p == nil {
		return ""
	}
	var out []byte
	for i := uintptr(0); ; i++ {
		b := *(*byte)(unsafe.Add(unsafe.Pointer(p), i))
		if b == 0 {
			break
		}
		out = append(out, b)
		if len(out) > 4096 {
			break
		}
	}
	return string(out)
}

func cStr(s string) []byte {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return b
}

type ortEmbedder struct {
	api        *ortAPI
	env        uintptr
	session    uintptr
	memInfo    uintptr
	inputNames []string
	outputName string
	mu         sync.Mutex
}

func newORTEmbedder(cfg config.Config, modelPath string) (*ortEmbedder, error) {
	api, err := loadORT(cfg)
	if err != nil {
		return nil, err
	}
	var env, opts, sess, memInfo, alloc uintptr
	logID := cStr("neorecall-embed")
	if err := api.check(api.createEnv(ortLoggingError, &logID[0], &env), "CreateEnv"); err != nil {
		return nil, err
	}
	cleanupEnv := true
	defer func() {
		if cleanupEnv && env != 0 {
			api.releaseEnv(env)
		}
	}()
	if err := api.check(api.createSessionOptions(&opts), "CreateSessionOptions"); err != nil {
		return nil, err
	}
	defer api.releaseSessionOptions(opts)
	_ = api.check(api.setGraphOptLevel(opts, 99), "SetGraphOptimizationLevel")
	_ = api.check(api.setIntraOpNumThreads(opts, 2), "SetIntraOpNumThreads")

	mPath := cStr(modelPath)
	if err := api.check(api.createSession(env, &mPath[0], opts, &sess), "CreateSession"); err != nil {
		return nil, err
	}
	if err := api.check(api.createCpuMemoryInfo(ortDeviceAllocator, ortMemTypeDefault, &memInfo), "CreateCpuMemoryInfo"); err != nil {
		api.releaseSession(sess)
		return nil, err
	}
	if err := api.check(api.getAllocatorWithDefaultOpts(&alloc), "GetAllocatorWithDefaultOptions"); err != nil {
		api.releaseMemoryInfo(memInfo)
		api.releaseSession(sess)
		return nil, err
	}

	var inCount, outCount uintptr
	if err := api.check(api.sessionGetInputCount(sess, &inCount), "SessionGetInputCount"); err != nil {
		api.releaseMemoryInfo(memInfo)
		api.releaseSession(sess)
		return nil, err
	}
	if err := api.check(api.sessionGetOutputCount(sess, &outCount), "SessionGetOutputCount"); err != nil || outCount == 0 {
		api.releaseMemoryInfo(memInfo)
		api.releaseSession(sess)
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("onnx model has no outputs")
	}

	inNames := make([]string, 0, int(inCount))
	for i := uintptr(0); i < inCount; i++ {
		var p *byte
		if err := api.check(api.sessionGetInputName(sess, i, alloc, &p), "SessionGetInputName"); err != nil {
			api.releaseMemoryInfo(memInfo)
			api.releaseSession(sess)
			return nil, err
		}
		inNames = append(inNames, goStringFromPtr(p))
		_ = api.check(api.allocatorFree(alloc, unsafe.Pointer(p)), "AllocatorFree")
	}
	var outP *byte
	if err := api.check(api.sessionGetOutputName(sess, 0, alloc, &outP), "SessionGetOutputName"); err != nil {
		api.releaseMemoryInfo(memInfo)
		api.releaseSession(sess)
		return nil, err
	}
	outName := goStringFromPtr(outP)
	_ = api.check(api.allocatorFree(alloc, unsafe.Pointer(outP)), "AllocatorFree")

	cleanupEnv = false
	return &ortEmbedder{
		api:        api,
		env:        env,
		session:    sess,
		memInfo:    memInfo,
		inputNames: inNames,
		outputName: outName,
	}, nil
}

func (e *ortEmbedder) Close() {
	if e == nil {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.memInfo != 0 {
		e.api.releaseMemoryInfo(e.memInfo)
		e.memInfo = 0
	}
	if e.session != 0 {
		e.api.releaseSession(e.session)
		e.session = 0
	}
	if e.env != 0 {
		e.api.releaseEnv(e.env)
		e.env = 0
	}
}

func (e *ortEmbedder) InferMeanPooled(inputIDs, attentionMask []int64) ([]float32, error) {
	if len(inputIDs) == 0 || len(inputIDs) != len(attentionMask) {
		return nil, fmt.Errorf("invalid token buffer lengths")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.session == 0 {
		return nil, fmt.Errorf("onnx session closed")
	}

	seqLen := int64(len(inputIDs))
	shape := [2]int64{1, seqLen}
	tokenTypeIDs := make([]int64, len(inputIDs))

	var inNameBytes [][]byte
	var inNamePtrs []*byte
	var inTensors []uintptr
	defer func() {
		for _, tv := range inTensors {
			if tv != 0 {
				e.api.releaseValue(tv)
			}
		}
	}()

	for _, name := range e.inputNames {
		var buf []int64
		switch strings.ToLower(name) {
		case "input_ids":
			buf = inputIDs
		case "attention_mask":
			buf = attentionMask
		case "token_type_ids":
			buf = tokenTypeIDs
		default:
			buf = tokenTypeIDs
		}
		var tv uintptr
		byteLen := uintptr(len(buf)) * unsafe.Sizeof(int64(0))
		if err := e.api.check(e.api.createTensorWithData(e.memInfo, unsafe.Pointer(&buf[0]), byteLen, &shape[0], 2, onnxTypeInt64, &tv), "CreateTensorWithData"); err != nil {
			return nil, err
		}
		nb := cStr(name)
		inNameBytes = append(inNameBytes, nb)
		inNamePtrs = append(inNamePtrs, &nb[0])
		inTensors = append(inTensors, tv)
	}

	outNameB := cStr(e.outputName)
	outNamePtr := &outNameB[0]
	var outTensor uintptr
	if err := e.api.check(e.api.run(
		e.session,
		0,
		&inNamePtrs[0],
		&inTensors[0],
		uintptr(len(inTensors)),
		&outNamePtr,
		1,
		&outTensor,
	), "Run"); err != nil {
		return nil, err
	}
	defer func() {
		if outTensor != 0 {
			e.api.releaseValue(outTensor)
		}
	}()

	var shapeInfo uintptr
	if err := e.api.check(e.api.getTensorTypeAndShape(outTensor, &shapeInfo), "GetTensorTypeAndShape"); err != nil {
		return nil, err
	}
	defer e.api.releaseTensorTypeAndShape(shapeInfo)

	var ndims uintptr
	if err := e.api.check(e.api.getDimensionsCount(shapeInfo, &ndims), "GetDimensionsCount"); err != nil {
		return nil, err
	}
	dims := make([]int64, int(ndims))
	if ndims > 0 {
		if err := e.api.check(e.api.getDimensions(shapeInfo, &dims[0], ndims), "GetDimensions"); err != nil {
			return nil, err
		}
	}
	var total uintptr
	if err := e.api.check(e.api.getTensorShapeElementCount(shapeInfo, &total), "GetTensorShapeElementCount"); err != nil {
		return nil, err
	}
	var rawDataPtr unsafe.Pointer
	if err := e.api.check(e.api.getTensorMutableData(outTensor, &rawDataPtr), "GetTensorMutableData"); err != nil {
		return nil, err
	}
	rawFloats := unsafe.Slice((*float32)(rawDataPtr), int(total))

	var pooled []float32
	switch len(dims) {
	case 3:
		// [1, seqLen, hidden] -> attention_mask weighted mean pooling
		tLen := int(dims[1])
		hidden := int(dims[2])
		if hidden <= 0 || tLen*hidden > len(rawFloats) {
			return nil, fmt.Errorf("unexpected output tensor shape %v", dims)
		}
		pooled = make([]float32, hidden)
		var maskSum float64
		for t := 0; t < tLen && t < len(attentionMask); t++ {
			if attentionMask[t] == 0 {
				continue
			}
			maskSum += 1
			base := t * hidden
			for h := 0; h < hidden; h++ {
				pooled[h] += rawFloats[base+h]
			}
		}
		if maskSum < 1e-9 {
			maskSum = 1e-9
		}
		for h := range pooled {
			pooled[h] = float32(float64(pooled[h]) / maskSum)
		}
	case 2:
		hidden := int(dims[1])
		pooled = append([]float32(nil), rawFloats[:min(hidden, len(rawFloats))]...)
	default:
		return nil, fmt.Errorf("unsupported output tensor rank %d (%v)", len(dims), dims)
	}

	// L2 normalize matching Transformers.js normalize: true
	var sumSq float64
	for _, v := range pooled {
		sumSq += float64(v) * float64(v)
	}
	norm := math.Sqrt(sumSq)
	if norm > 0 {
		for i := range pooled {
			pooled[i] = float32(float64(pooled[i]) / norm)
		}
	}
	runtime.KeepAlive(inputIDs)
	runtime.KeepAlive(attentionMask)
	runtime.KeepAlive(tokenTypeIDs)
	runtime.KeepAlive(inNameBytes)
	runtime.KeepAlive(outNameB)
	return pooled, nil
}
