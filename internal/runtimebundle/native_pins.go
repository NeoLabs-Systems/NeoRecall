package runtimebundle

// The native code NeoRecall loads or runs but does not build: sherpa-onnx (with
// the ONNX Runtime it was built against, which local embeddings use too) and a
// static ffmpeg. Every digest is the one GitHub publishes for the release asset.
//
// The sherpa-onnx version must match the C structs in
// internal/transcription/sherpa.go; change both together. 1.13.5 is the newest
// release that does: 1.13.6 added fields. Do not use the 1.13.4 macOS archives,
// whose arm64 ONNX Runtime has a broken signature and is killed on load.
const (
	sherpaVersion = "1.13.5"
	ffmpegRelease = "b6.1.1"

	sherpaBase = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v" + sherpaVersion + "/sherpa-onnx-v" + sherpaVersion + "-"
	ffmpegBase = "https://github.com/eugeneware/ffmpeg-static/releases/download/" + ffmpegRelease + "/"
)

var natives = map[string]native{
	"linux-x64": {
		libraries:     pin{sherpaBase + "linux-x64-shared-no-tts-lib.tar.bz2", "5ade70b563dc0cbc1851d5726dcdd91958a50322f61185b95ac65c8033a2938a"},
		libraryNames:  []string{"libsherpa-onnx-c-api.so", "libonnxruntime.so"},
		ffmpeg:        pin{ffmpegBase + "ffmpeg-linux-x64.gz", "bfe8a8fc511530457b528c48d77b5737527b504a3797a9bc4866aeca69c2dffa"},
		ffmpegLicense: pin{ffmpegBase + "linux-x64.LICENSE", "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"},
		ffmpegReadme:  pin{ffmpegBase + "linux-x64.README", "72f4b1b06d419d22ace6e7cc75f06826f90737345aa0b1736158929f4aacc537"},
	},
	"linux-arm64": {
		libraries:     pin{sherpaBase + "linux-aarch64-shared-cpu-lib.tar.bz2", "e9e284e887c67959f45b2cad834d9b2fae281bb4e8e596928ffe371506d803ac"},
		libraryNames:  []string{"libsherpa-onnx-c-api.so", "libonnxruntime.so"},
		ffmpeg:        pin{ffmpegBase + "ffmpeg-linux-arm64.gz", "754a678672298bc68156adff58aa7385a592c2b30b1d0ae8750c45c915c4bac0"},
		ffmpegLicense: pin{ffmpegBase + "linux-arm64.LICENSE", "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"},
		ffmpegReadme:  pin{ffmpegBase + "linux-arm64.README", "d6777d2fd276b23f0ac6666fa619e88ffe4826521881c7ff83836e30cb4acec2"},
	},
	"macos-x64": {
		libraries:     pin{sherpaBase + "osx-x64-shared-no-tts-lib.tar.bz2", "c1a65c52458a59ac0fc861733a42bd2c870940e6b23a77eb528aa3c3e6f0b85f"},
		libraryNames:  []string{"libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"},
		ffmpeg:        pin{ffmpegBase + "ffmpeg-darwin-x64.gz", "929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106"},
		ffmpegLicense: pin{ffmpegBase + "darwin-x64.LICENSE", "2e1d16c72fd74e12063776371da757322f8b77589386532f4fd8634bde7de1af"},
		ffmpegReadme:  pin{ffmpegBase + "darwin-x64.README", "e88a0325f8e5b75210355e37341824f074d3cd82def2125be54c914b62848a36"},
	},
	"macos-arm64": {
		libraries:     pin{sherpaBase + "osx-arm64-shared-no-tts-lib.tar.bz2", "bd0e13f42eb1e2aa7174a2816198f2cff3b586fa09a7140f5504d8c1ab1cb19e"},
		libraryNames:  []string{"libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"},
		ffmpeg:        pin{ffmpegBase + "ffmpeg-darwin-arm64.gz", "8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa"},
		ffmpegLicense: pin{ffmpegBase + "darwin-arm64.LICENSE", "cb48bf09a11f5fb576cddb0431c8f5ed0a60157a9ec942adffc13907cbe083f2"},
		ffmpegReadme:  pin{ffmpegBase + "darwin-arm64.README", "05ba4b92c96605434b1aaae3eedf5a2c280c9607bf78ffca9a5b536d9af2dc6a"},
	},
	"windows-x64": {
		libraries:     pin{sherpaBase + "win-x64-shared-MD-Release-no-tts-lib.tar.bz2", "db28ba9200eadeac073cb4aae77210a866e713d464fd8270f4f245041bcee1f4"},
		libraryNames:  []string{"sherpa-onnx-c-api.dll", "onnxruntime.dll", "onnxruntime_providers_shared.dll"},
		ffmpeg:        pin{ffmpegBase + "ffmpeg-win32-x64.gz", "8883a3dffbd0a16cf4ef95206ea05283f78908dbfb118f73c83f4951dcc06d77"},
		ffmpegLicense: pin{ffmpegBase + "win32-x64.LICENSE", "8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903"},
		ffmpegReadme:  pin{ffmpegBase + "win32-x64.README", "a636a7183c58006351acbaf35303c0ed85c6e1320fd4e80de453ba6157de6311"},
	},
}
