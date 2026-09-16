# plaud_sdk

Vendored Flutter bridge for Plaud's Embedded SDK.

- iOS: xcframeworks under `ios/Frameworks` (arm64 device; no simulator slice)
- Android: `android/m2/.../plaud-sdk-1.0.0.aar`, resolved as `systems.neolabs.plaud:plaud-sdk` from the file-based repository beside it (physical phone; handshake over HTTPS)

There is no Plaud SDK for macOS, Windows, Linux, or the browser. NeoRecall uses
BLE file export only — it does not call Plaud's upload or transcription APIs.
