# plaud_sdk

Vendored Flutter bridge for Plaud's Embedded SDK.

- iOS: xcframeworks under `ios/Frameworks` (arm64 device; no simulator slice)
- Android: `android/libs/plaud-sdk.aar` (physical phone; handshake over HTTPS)

There is no Plaud SDK for macOS, Windows, Linux, or the browser. NeoRecall uses
BLE file export only — it does not call Plaud's upload or transcription APIs.
