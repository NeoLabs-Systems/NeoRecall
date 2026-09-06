/// Reasons the mobile runtime must keep running while no UI is attached.
///
/// A hold is a *claim* on the always-on host, not a capture mode: several can be
/// active at once (phone microphone plus a wearable, or a wearable link while
/// nothing is recording). The native host derives its foreground-service types
/// and its notification from the union of the active holds, so adding a new
/// always-on capability means adding a hold — not another parallel service path.
enum BackgroundHold {
  /// Live capture from the phone microphone.
  microphoneCapture,

  /// Live audio streamed from a connected wearable over BLE.
  wearableCapture,

  /// A paired wearable stays linked with no capture running, so reconnect,
  /// on-device recording sync, and upload keep working with the UI gone.
  wearableLink,

  /// Recordings are being transferred off a wearable right now. Held only for
  /// the duration of a transfer: unlike [wearableLink] it keeps the CPU awake,
  /// so a long BLE drain and its upload are not stretched across sleep cycles.
  wearableSync,

  /// A durable phone-side queue is actively uploading. This is separate from
  /// capture and wearable sync so uploads after recording stops still own an
  /// Android data-sync foreground service and wake lock for the drain only.
  audioUpload,
}

extension BackgroundHoldWire on BackgroundHold {
  /// Stable identifier exchanged with the native host and persisted by it.
  /// Never derive this from [Enum.name] so a rename cannot silently invalidate
  /// state the platform already wrote to disk.
  String get wireName => switch (this) {
    BackgroundHold.microphoneCapture => 'microphoneCapture',
    BackgroundHold.wearableCapture => 'wearableCapture',
    BackgroundHold.wearableLink => 'wearableLink',
    BackgroundHold.wearableSync => 'wearableSync',
    BackgroundHold.audioUpload => 'audioUpload',
  };
}

/// Parses a hold identifier written by the native host. Unknown values (state
/// persisted by a newer build) are ignored rather than crashing startup.
BackgroundHold? backgroundHoldFromWire(String value) {
  for (final hold in BackgroundHold.values) {
    if (hold.wireName == value) return hold;
  }
  return null;
}

/// The complete set of holds the runtime currently wants, plus the user-visible
/// text that describes it.
///
/// This value is the single contract between the Dart runtime and every platform
/// host: platform code decides *how* to stay alive, this decides *why* and *what
/// the user is told*.
class BackgroundRuntimeRequest {
  const BackgroundRuntimeRequest({
    this.holds = const <BackgroundHold>{},
    this.deviceLabel,
    this.deviceConnected = false,
  });

  /// Nothing needs the host; it may shut down.
  static const BackgroundRuntimeRequest idle = BackgroundRuntimeRequest();

  final Set<BackgroundHold> holds;

  /// Display name of the wearable involved, when one is.
  final String? deviceLabel;

  /// Live transport truth, not merely whether a wearable is preferred.
  ///
  /// The link hold remains active while reconnecting, so the hold by itself
  /// cannot support user-facing claims that the device "stays linked".
  final bool deviceConnected;

  bool get isEmpty => holds.isEmpty;
  bool get isNotEmpty => holds.isNotEmpty;

  bool get needsMicrophone => holds.contains(BackgroundHold.microphoneCapture);

  /// True when any hold depends on a connected external device. The live
  /// wearable stream, an in-flight sync, and the idle link all map to the same
  /// platform capability.
  bool get needsConnectedDevice => holds.any(
    const <BackgroundHold>{
      BackgroundHold.wearableCapture,
      BackgroundHold.wearableLink,
      BackgroundHold.wearableSync,
    }.contains,
  );

  /// True while audio is actually being captured, which is what the notification
  /// calls "recording".
  bool get isCapturing =>
      needsMicrophone || holds.contains(BackgroundHold.wearableCapture);

  /// True while work would be stretched out or interrupted by the CPU sleeping:
  /// live capture, and a transfer that is moving audio off a device right now.
  /// A device that is merely linked deliberately does not qualify — holding a
  /// wake lock around the clock for an idle link would cost battery for nothing.
  bool get needsWakeLock =>
      isCapturing ||
      holds.contains(BackgroundHold.wearableSync) ||
      holds.contains(BackgroundHold.audioUpload);

  /// Sorted so an unchanged request always produces an identical wire payload.
  List<String> get wireHolds =>
      holds.map((hold) => hold.wireName).toList(growable: false)..sort();

  String get statusDetail {
    final device = deviceLabel?.trim();
    final label = device == null || device.isEmpty ? 'your device' : device;
    if (needsMicrophone && holds.contains(BackgroundHold.wearableCapture)) {
      return 'Capturing $label and the phone microphone';
    }
    if (holds.contains(BackgroundHold.wearableCapture)) {
      return 'Capturing audio from $label';
    }
    if (needsMicrophone) return 'Capturing phone microphone audio';
    if (holds.contains(BackgroundHold.wearableSync)) {
      return 'Syncing recordings from $label';
    }
    if (holds.contains(BackgroundHold.audioUpload)) {
      return 'Uploading protected recordings';
    }
    if (holds.contains(BackgroundHold.wearableLink)) {
      return deviceConnected
          ? '$label stays linked so recordings sync on their own'
          : 'Waiting for $label to reconnect';
    }
    return 'NeoRecall is idle';
  }

  /// Compatibility accessors for callers that still need a compact fallback.
  /// Native hosts no longer receive these independently; live UI uses the
  /// structured [BackgroundLiveStatus] payload instead.
  String get notificationTitle {
    if (isCapturing) return 'NeoRecall is recording';
    if (holds.contains(BackgroundHold.wearableLink) &&
        !holds.contains(BackgroundHold.wearableSync) &&
        !holds.contains(BackgroundHold.audioUpload) &&
        !deviceConnected) {
      return 'NeoRecall is reconnecting';
    }
    return 'NeoRecall stays connected';
  }

  String get notificationText => statusDetail;

  BackgroundRuntimeRequest copyWith({
    Set<BackgroundHold>? holds,
    String? deviceLabel,
    bool? deviceConnected,
  }) => BackgroundRuntimeRequest(
    holds: holds ?? this.holds,
    deviceLabel: deviceLabel ?? this.deviceLabel,
    deviceConnected: deviceConnected ?? this.deviceConnected,
  );

  @override
  bool operator ==(Object other) =>
      other is BackgroundRuntimeRequest &&
      other.deviceLabel == deviceLabel &&
      other.deviceConnected == deviceConnected &&
      other.holds.length == holds.length &&
      other.holds.containsAll(holds);

  @override
  int get hashCode =>
      Object.hash(deviceLabel, deviceConnected, Object.hashAllUnordered(holds));

  @override
  String toString() =>
      'BackgroundRuntimeRequest(${wireHolds.join('+')}'
      '${deviceLabel == null ? '' : ', $deviceLabel'}'
      '${deviceConnected ? ', connected' : ''})';
}

/// What the native host reports about itself at startup.
///
/// [foreground] tells the runtime whether a UI is attached. A process that the
/// system started on its own (boot, sticky service restart) has none, and mobile
/// platforms refuse microphone access to such a process — so the runtime must be
/// able to tell that case apart instead of starting a capture that cannot work.
class BackgroundRuntimeState {
  const BackgroundRuntimeState({
    this.running = false,
    this.holds = const <BackgroundHold>{},
    this.foreground = false,
    this.microphoneUnavailable = false,
  });

  final bool running;
  final Set<BackgroundHold> holds;
  final bool foreground;

  /// True when the host had to drop a microphone hold because the platform
  /// forbids it for the way this process was started (typically after a reboot).
  final bool microphoneUnavailable;

  static BackgroundRuntimeState fromMap(Map<Object?, Object?> payload) {
    final rawHolds = payload['holds'];
    final holds = <BackgroundHold>{};
    if (rawHolds is List) {
      for (final value in rawHolds) {
        if (value is! String) continue;
        final hold = backgroundHoldFromWire(value);
        if (hold != null) holds.add(hold);
      }
    }
    return BackgroundRuntimeState(
      running: payload['running'] == true,
      holds: holds,
      foreground: payload['foreground'] == true,
      microphoneUnavailable: payload['microphoneUnavailable'] == true,
    );
  }
}
