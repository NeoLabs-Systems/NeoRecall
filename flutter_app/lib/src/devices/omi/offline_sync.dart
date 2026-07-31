import 'dart:typed_data';

/// A complete recording pulled from a device's on-board storage, ready to be
/// ingested through the durable import pipeline.
class WearableRecording {
  const WearableRecording({
    required this.id,
    required this.bytes,
    required this.contentType,
    required this.filename,
    this.capturedAt,
  });

  /// Stable identifier, unique within the device, used to derive a deterministic
  /// import id so a re-synced recording never duplicates.
  final String id;

  /// The recording's raw bytes, in [contentType] format.
  final Uint8List bytes;

  /// MIME type of [bytes] (e.g. `audio/mpeg`, `audio/wav`).
  final String contentType;

  /// Suggested filename for the import (informational/server-side only).
  final String filename;

  /// When the recording was captured, if the device encodes it — fed into the
  /// import so the timeline places it correctly.
  final DateTime? capturedAt;
}

/// Optional capability a wearable connector implements when the device keeps an
/// on-board store of recordings that can be pulled over BLE and ingested after
/// the fact — the offline/durable counterpart to the live audio stream.
///
/// A single drain method keeps the app-side flow identical for every device
/// regardless of the underlying protocol shape (discrete file list + download +
/// delete, ring-buffer read + advance, or bulk flash-page batch dump): the
/// connector owns its protocol and simply hands back complete recordings.
abstract mixin class WearableOfflineSync {
  /// Drains the device's on-board store, invoking [onRecording] once per
  /// complete recording.
  ///
  /// [onRecording] resolves only after the recording has been durably ingested,
  /// so the connector may safely delete/advance past it on the device afterwards
  /// — nothing is removed from the device until it is safe elsewhere. Recordings
  /// smaller than [minBytes] are skipped. Returns the number emitted.
  Future<int> drainStoredAudio(
    Future<void> Function(WearableRecording recording) onRecording, {
    int minBytes = 0,
  });

  /// Aborts an in-flight drain so the device can return to idle/live capture.
  Future<void> cancelStoredSync();

  /// Protocol-level facts about the last drain, recorded in the diagnostics log
  /// alongside the sync outcome.
  ///
  /// A drain that returns zero recordings is ambiguous on its own — an empty
  /// device and a device that never answered look identical to the user. Each
  /// connector reports what it actually observed (handshake acknowledged, list
  /// received, packets pending) so a failing sync can be diagnosed from a user's
  /// exported log instead of requiring the hardware in hand. Values must contain
  /// no audio, transcripts or secrets.
  Map<String, Object?> get syncDiagnostics => const <String, Object?>{};
}

/// Implemented by a device adapter whose currently-connected device may expose
/// offline storage, so the app can drive a sync sweep without knowing the
/// concrete adapter or protocol. Returns null when the connected device (if any)
/// has no offline store.
abstract class StorageSyncCapableAdapter {
  WearableOfflineSync? get offlineSyncConnector;
}
