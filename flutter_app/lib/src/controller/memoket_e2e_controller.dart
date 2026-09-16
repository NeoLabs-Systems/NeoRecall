part of '../../main_controller.dart';

/// ADB-triggered Memoket Gem hardware probe.
///
/// Stands the ordinary capture/sync loops down so the probe owns the radio,
/// then restores them. There is no UI entry: the request is persisted natively
/// and claimed here the same way a widget tap is.
mixin MemoketE2eController on ChangeNotifier {
  RecallRecorder get recorder;
  AudioDeviceAdapterRegistry get audioDeviceRegistry;
  DeviceSessionController get audioDeviceSessions;
  DeviceStorageSyncScheduler get deviceStorageSync;
  bool get isRecording;
  bool get initialized;
  Future<void> stopRecording();

  bool _memoketHardwareProbeActive = false;

  bool get memoketHardwareProbeActive => _memoketHardwareProbeActive;

  Future<void> consumePendingMemoketE2eRequest() async {
    if (!initialized || _memoketHardwareProbeActive) return;
    final mobile = recorder;
    if (mobile is! MobileRecallRecorder) return;
    // Claim before the native round-trip so a second resume/event cannot
    // observe the same persisted request.
    _memoketHardwareProbeActive = true;
    notifyListeners();
    var handedOff = false;
    try {
      final pending = await mobile.background.takePendingMemoketE2eRequest();
      if (pending == null) return;
      handedOff = true;
      await _runMemoketHardwareProbe(MemoketE2eRequest.fromMap(pending).config);
    } finally {
      if (!handedOff) {
        _memoketHardwareProbeActive = false;
        notifyListeners();
      }
    }
  }

  Future<void> _runMemoketHardwareProbe(MemoketE2eConfig config) async {
    final adapter = audioDeviceRegistry['omi_family'];
    if (adapter is! DeviceAdapter) {
      _memoketHardwareProbeActive = false;
      notifyListeners();
      throw StateError('The Bluetooth wearable adapter is not available.');
    }
    final previousAutoReconnect = audioDeviceSessions.autoReconnect;
    audioDeviceSessions.autoReconnect = false;
    deviceStorageSync.stop();
    try {
      if (isRecording) await stopRecording();
      await audioDeviceSessions.disconnect();
      BackgroundCaptureService? background;
      final mobile = recorder;
      if (mobile is MobileRecallRecorder) {
        background = mobile.background;
        mobile.hardwareProbeHolds = true;
        await mobile.applyBackgroundHolds();
      }
      try {
        final report = await MemoketE2eHarness(
          adapter: adapter,
          config: config,
          background: background,
          knownDevice: audioDeviceSessions.preferredDevice,
        ).run();
        ClientDiagnosticLog.instance.record(
          'memoket_e2e',
          report.passed ? 'controller_passed' : 'controller_failed',
          level: report.passed ? 'info' : 'error',
          details: <String, Object?>{
            'passed': report.passed,
            'steps': report.steps.length,
            'reportPath': report.reportPath,
          },
        );
      } finally {
        if (mobile is MobileRecallRecorder) {
          mobile.hardwareProbeHolds = false;
          await mobile.applyBackgroundHolds();
        }
      }
    } finally {
      audioDeviceSessions.autoReconnect = previousAutoReconnect;
      _memoketHardwareProbeActive = false;
      deviceStorageSync.start();
      if (previousAutoReconnect && audioDeviceSessions.hasPreferredDevice) {
        unawaited(audioDeviceSessions.connectPreferred());
      }
      notifyListeners();
    }
  }
}
