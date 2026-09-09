import 'dart:async';
import 'dart:developer' as developer;

import '../../background/background_capture_service.dart';
import '../../background/background_hold.dart';
import '../../diagnostics/client_diagnostic_log.dart';
import '../audio_codec_decoder.dart';
import '../audio_device_adapter.dart';
import 'device_adapter.dart';
import 'device_models.dart';
import 'memoket_connector.dart';
import 'memoket_e2e_report_sink.dart'
    if (dart.library.io) 'memoket_e2e_report_sink_io.dart';

/// Durations and pass/fail floors for an on-device Memoket Gem probe.
///
/// Kept in one place so a longer soak is a config change, not a new scenario.
class MemoketE2eConfig {
  const MemoketE2eConfig({
    this.scanTimeout = const Duration(seconds: 40),
    this.connectTimeout = const Duration(seconds: 30),
    this.idleHold = const Duration(seconds: 12),
    this.liveDuration = const Duration(seconds: 120),
    this.firstAudioTimeout = const Duration(seconds: 8),
    this.pcmGapLimit = const Duration(seconds: 3),
    this.minPcmFraction = 0.7,
    this.reconnectGap = const Duration(seconds: 10),
    this.dropLivePrefix = const Duration(seconds: 15),
    this.dropDisconnected = const Duration(seconds: 12),
    this.dropLiveSuffix = const Duration(seconds: 15),
    this.pcmSampleRate = 16000,
  });

  final Duration scanTimeout;
  final Duration connectTimeout;
  final Duration idleHold;
  final Duration liveDuration;
  final Duration firstAudioTimeout;
  final Duration pcmGapLimit;
  final double minPcmFraction;
  final Duration reconnectGap;
  final Duration dropLivePrefix;
  final Duration dropDisconnected;
  final Duration dropLiveSuffix;
  final int pcmSampleRate;

  static const int _minLiveMs = 30 * 1000;
  static const int _maxLiveMs = 10 * 60 * 1000;
  static const int _defaultLiveMs = 120 * 1000;

  factory MemoketE2eConfig.fromHost({
    int? liveMs,
    int? reconnectGapMs,
    int? idleMs,
  }) {
    final live = (liveMs == null || liveMs <= 0)
        ? _defaultLiveMs
        : liveMs.clamp(_minLiveMs, _maxLiveMs);
    final reconnect = (reconnectGapMs == null || reconnectGapMs <= 0)
        ? 8000
        : reconnectGapMs.clamp(2000, 60000);
    final idle = (idleMs == null || idleMs <= 0)
        ? 12000
        : idleMs.clamp(8000, 60000);
    return MemoketE2eConfig(
      liveDuration: Duration(milliseconds: live),
      reconnectGap: Duration(milliseconds: reconnect),
      idleHold: Duration(milliseconds: idle),
    );
  }

  int expectedPcmBytes(Duration live) =>
      (live.inMilliseconds * pcmSampleRate * 2) ~/ 1000;

  bool pcmCovers(int bytes, Duration live) {
    final expected = expectedPcmBytes(live);
    if (expected <= 0) return bytes > 0;
    return bytes >= expected * minPcmFraction;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'scanTimeoutMs': scanTimeout.inMilliseconds,
    'connectTimeoutMs': connectTimeout.inMilliseconds,
    'idleHoldMs': idleHold.inMilliseconds,
    'liveDurationMs': liveDuration.inMilliseconds,
    'firstAudioTimeoutMs': firstAudioTimeout.inMilliseconds,
    'pcmGapLimitMs': pcmGapLimit.inMilliseconds,
    'minPcmFraction': minPcmFraction,
    'reconnectGapMs': reconnectGap.inMilliseconds,
    'dropLivePrefixMs': dropLivePrefix.inMilliseconds,
    'dropDisconnectedMs': dropDisconnected.inMilliseconds,
    'dropLiveSuffixMs': dropLiveSuffix.inMilliseconds,
    'pcmSampleRate': pcmSampleRate,
  };
}

enum MemoketE2eStepStatus { passed, failed, skipped }

class MemoketE2eStepResult {
  const MemoketE2eStepResult({
    required this.name,
    required this.status,
    required this.durationMs,
    this.details = const <String, Object?>{},
    this.error,
  });

  final String name;
  final MemoketE2eStepStatus status;
  final int durationMs;
  final Map<String, Object?> details;
  final String? error;

  bool get ok => status != MemoketE2eStepStatus.failed;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'status': status.name,
    'durationMs': durationMs,
    if (details.isNotEmpty) 'details': details,
    if (error != null) 'error': error,
  };
}

class MemoketE2eReport {
  MemoketE2eReport({
    required this.config,
    required this.startedAt,
    this.finishedAt,
    this.running = true,
    this.passed = false,
    this.reportPath,
    List<MemoketE2eStepResult>? steps,
  }) : steps = steps ?? <MemoketE2eStepResult>[];

  final MemoketE2eConfig config;
  final DateTime startedAt;
  DateTime? finishedAt;
  bool running;
  bool passed;
  String? reportPath;
  final List<MemoketE2eStepResult> steps;

  bool get allRequiredPassed =>
      steps.isNotEmpty &&
      steps.every((step) => step.status != MemoketE2eStepStatus.failed);

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'running': running,
    'passed': passed,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'elapsedMs': (finishedAt ?? DateTime.now())
        .difference(startedAt)
        .inMilliseconds,
    'reportPath': reportPath,
    'config': config.toJson(),
    'steps': steps.map((step) => step.toJson()).toList(growable: false),
  };
}

class MemoketE2eRequest {
  const MemoketE2eRequest({this.liveMs, this.reconnectGapMs, this.idleMs});

  final int? liveMs;
  final int? reconnectGapMs;
  final int? idleMs;

  factory MemoketE2eRequest.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const MemoketE2eRequest();
    return MemoketE2eRequest(
      liveMs: _asInt(raw['liveMs']),
      reconnectGapMs: _asInt(raw['reconnectGapMs']),
      idleMs: _asInt(raw['idleMs']),
    );
  }

  MemoketE2eConfig get config => MemoketE2eConfig.fromHost(
    liveMs: liveMs,
    reconnectGapMs: reconnectGapMs,
    idleMs: idleMs,
  );

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Walks the real GATT adapter against a nearby powered-on Memoket Gem.
class MemoketE2eHarness {
  MemoketE2eHarness({
    required this.adapter,
    required this.config,
    this.background,
    this.knownDevice,
  });

  final DeviceAdapter adapter;
  final MemoketE2eConfig config;
  final BackgroundCaptureService? background;
  final AudioDeviceDescriptor? knownDevice;
  final Set<String> _probeTakeIds = <String>{};

  static const _logName = 'NeoRecallMemoketE2E';
  static const Duration _postStopSettle = Duration(seconds: 3);

  Future<MemoketE2eReport> run() async {
    final report = MemoketE2eReport(
      config: config,
      startedAt: DateTime.now().toUtc(),
    );
    await _persist(report);
    await initializeWearableAudioCodecs();
    await _holdRuntime();
    try {
      await _step(report, 'radio', _radio);
      if (!_stepOk(report, 'radio')) return await _finish(report);
      final known = knownDevice;
      AudioDeviceDescriptor? device;
      if (known != null && _isMemoket(known)) {
        device = await _stepValue(report, 'known_device', () async => known);
      } else {
        device = await _stepValue(report, 'scan', _scan);
      }
      if (device == null) return await _finish(report);
      final target = device;
      await _step(report, 'connect', () => _connect(target));
      if (!_stepOk(report, 'connect')) return await _finish(report);
      await _step(report, 'handshake', () => _handshake(target));
      await _step(report, 'idle_link', () => _idleLink(target));
      await _step(report, 'live_soak', () => _liveSoak(target));
      await _step(report, 'stop', _stop);
      await _step(report, 'list_files', _listFiles);
      await _step(report, 'drain_soak_take', _drainProbeTakes);
      await _step(report, 'reconnect_idle', () => _reconnectIdle(target));
      await _step(report, 'drop_reconnect', () => _dropReconnect(target));
      await _step(report, 'drain_drop_take', _drainProbeTakes);
    } catch (error) {
      _log('fatal $error');
      report.steps.add(
        MemoketE2eStepResult(
          name: 'fatal',
          status: MemoketE2eStepStatus.failed,
          durationMs: 0,
          error: error.toString(),
        ),
      );
    } finally {
      try {
        await adapter.requestStopRecording();
      } catch (_) {}
      try {
        await adapter.disconnect();
      } catch (_) {}
    }
    report.passed = report.allRequiredPassed;
    return _finish(report);
  }

  Future<void> _radio() async {
    await adapter.initialize();
    if (!await adapter.radioIsReady()) {
      throw StateError('Bluetooth is not ready.');
    }
  }

  Future<AudioDeviceDescriptor> _scan() async {
    // A Gem that was just disconnected is still in the phone's connection
    // table and often does not advertise for a few seconds.
    await Future<void>.delayed(const Duration(seconds: 8));
    final found = Completer<AudioDeviceDescriptor>();
    final seen = <String, AudioDeviceDescriptor>{};
    final sub = adapter.discoveries.listen((device) {
      if (!_isMemoket(device)) return;
      seen[device.deviceKey] = device;
      if (!found.isCompleted) found.complete(device);
    });
    try {
      await adapter.startScan(timeout: config.scanTimeout);
      try {
        return await found.future.timeout(config.scanTimeout);
      } on TimeoutException {
        throw StateError(
          'No Memoket Gem advertised within ${config.scanTimeout.inSeconds}s. '
          'Seen: ${seen.values.map((d) => d.displayName).join(', ')}',
        );
      }
    } finally {
      await sub.cancel();
      await adapter.stopScan();
    }
  }

  Future<void> _connect(AudioDeviceDescriptor device) async {
    await adapter
        .connect(device)
        .timeout(
          config.connectTimeout,
          onTimeout: () => throw TimeoutException(
            'GATT connect timed out after ${config.connectTimeout.inSeconds}s.',
          ),
        );
    await _waitForStates(const <DeviceTransportState>{
      DeviceTransportState.connectedStandby,
      DeviceTransportState.recording,
    }, config.connectTimeout);
    if (!await adapter.hasLiveLink()) {
      throw StateError(
        'Adapter reported connected but the GATT link is not live.',
      );
    }
  }

  Future<Map<String, Object?>> _handshake(AudioDeviceDescriptor device) async {
    final sync = adapter.offlineSyncConnector;
    final diagnostics = Map<String, Object?>.from(sync?.syncDiagnostics ?? {});
    if (diagnostics['deviceResponded'] != true &&
        diagnostics['ready'] != true) {
      throw StateError(
        'Gem did not answer the control handshake. $diagnostics',
      );
    }
    final battery = await _waitForBattery(const Duration(seconds: 4));
    if (battery != null && (battery < 0 || battery > 100)) {
      throw StateError('Battery reading $battery is not a percent.');
    }
    return <String, Object?>{
      ...diagnostics,
      'battery': battery,
      'device': device.displayName,
      'deviceKey': device.deviceKey,
    };
  }

  Future<Map<String, Object?>> _idleLink(AudioDeviceDescriptor device) async {
    final started = DateTime.now();
    while (DateTime.now().difference(started) < config.idleHold) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!await adapter.hasLiveLink()) {
        throw StateError(
          'Link dropped during the ${config.idleHold.inSeconds}s idle hold.',
        );
      }
    }
    return <String, Object?>{
      'heldMs': DateTime.now().difference(started).inMilliseconds,
      'device': device.displayName,
    };
  }

  Future<Map<String, Object?>> _liveSoak(AudioDeviceDescriptor device) async {
    await _ensureStandby();
    await adapter.requestStartRecording();
    await _waitForStates(const <DeviceTransportState>{
      DeviceTransportState.recording,
    }, config.firstAudioTimeout);
    final stats = await _collectPcm(config.liveDuration, requireFirst: true);
    if (!await adapter.hasLiveLink()) {
      throw StateError('GATT link dropped during the live soak.');
    }
    _assertPcm(stats, config.liveDuration);
    return stats.toJson(config.pcmSampleRate);
  }

  Future<Map<String, Object?>> _stop() async {
    await adapter.requestStopRecording();
    await _waitForStates(const <DeviceTransportState>{
      DeviceTransportState.connectedStandby,
    }, const Duration(seconds: 8));
    await Future<void>.delayed(_postStopSettle);
    final filename = _memoket?.lastTakeFilename;
    _rememberTake(filename);
    return <String, Object?>{
      'state': 'connectedStandby',
      'lastTakeFilename': filename,
      'probeTakeIds': _probeTakeIds.toList(growable: false),
      'liveLink': await adapter.hasLiveLink(),
      ...?_memoket?.syncDiagnostics,
    };
  }

  Future<Map<String, Object?>> _listFiles() async {
    final sync = adapter.offlineSyncConnector;
    if (sync == null) {
      throw StateError('Connected device has no offline-sync connector.');
    }
    final pending = await sync.peekPending();
    _rememberTake(_memoket?.lastTakeFilename);
    return <String, Object?>{
      'pendingSeconds': pending?.pendingSeconds ?? 0,
      'listed': pending?.total ?? 0,
      'lastTakeFilename': _memoket?.lastTakeFilename,
      'probeTakeIds': _probeTakeIds.toList(growable: false),
      ...sync.syncDiagnostics,
    };
  }

  Future<Map<String, Object?>> _reconnectIdle(
    AudioDeviceDescriptor device,
  ) async {
    await adapter.disconnect();
    await _waitForStates(const <DeviceTransportState>{
      DeviceTransportState.disconnected,
    }, const Duration(seconds: 6));
    await Future<void>.delayed(config.reconnectGap);
    // A Gem that was just an LE client does not advertise. Reconnect by the
    // bonded deviceKey the same way a real radio-loss recovery does.
    await _connect(device);
    await _handshake(device);
    return <String, Object?>{
      'gapMs': config.reconnectGap.inMilliseconds,
      'liveLink': await adapter.hasLiveLink(),
    };
  }

  Future<Map<String, Object?>> _dropReconnect(
    AudioDeviceDescriptor device,
  ) async {
    await _ensureStandby();
    await Future<void>.delayed(_postStopSettle);
    await adapter.requestStartRecording();
    final before = await _collectPcm(config.dropLivePrefix, requireFirst: true);
    _assertPcm(before, config.dropLivePrefix);
    _rememberTake(_memoket?.lastTakeFilename);
    await adapter.disconnectPreservingCaptureIntent();
    await Future<void>.delayed(config.dropDisconnected);
    await _connect(device);
    if (adapter.currentState != DeviceTransportState.recording) {
      await _ensureStandby();
      await Future<void>.delayed(_postStopSettle);
      await adapter.requestStartRecording();
    }
    final after = await _collectPcm(config.dropLiveSuffix, requireFirst: true);
    _assertPcm(after, config.dropLiveSuffix);
    await adapter.requestStopRecording();
    await _waitForStates(const <DeviceTransportState>{
      DeviceTransportState.connectedStandby,
    }, const Duration(seconds: 8));
    await Future<void>.delayed(_postStopSettle);
    final filename = _memoket?.lastTakeFilename;
    _rememberTake(filename);
    return <String, Object?>{
      'prefix': before.toJson(config.pcmSampleRate),
      'suffix': after.toJson(config.pcmSampleRate),
      'disconnectedMs': config.dropDisconnected.inMilliseconds,
      'lastTakeFilename': filename,
      'stateAfterReconnect': adapter.currentState.name,
    };
  }

  Future<Map<String, Object?>> _drainProbeTakes() async {
    await _ensureStandby();
    await Future<void>.delayed(_postStopSettle);
    _rememberTake(_memoket?.lastTakeFilename);
    final connector = _memoket;
    final sync = adapter.offlineSyncConnector;
    if (connector == null || sync == null) {
      throw StateError(
        'No Memoket connector available to drain the test take.',
      );
    }
    final takeIds = Set<String>.from(_probeTakeIds);
    if (takeIds.isEmpty) {
      return <String, Object?>{
        'skipped': true,
        'reason':
            'The Gem did not name a probe take, so drain would risk other files.',
      };
    }
    var downloaded = 0;
    var bytes = 0;
    String? contentType;
    final transferred = <String>[];
    final count = await connector.drainStoredAudio((recording) async {
      downloaded += 1;
      bytes += recording.bytes.length;
      contentType = recording.contentType;
      transferred.add(recording.id);
    }, shouldTransfer: (id) => takeIds.contains(id));
    if (downloaded == 0) {
      return <String, Object?>{
        'skipped': true,
        'reason':
            'No matching probe take remained on the Gem '
            '(live coverage may already have cleared it).',
        'takeIds': takeIds.toList(growable: false),
        ...sync.syncDiagnostics,
      };
    }
    for (final id in transferred) {
      _probeTakeIds.remove(id);
    }
    return <String, Object?>{
      'takeIds': takeIds.toList(growable: false),
      'transferred': transferred,
      'downloaded': downloaded,
      'returned': count,
      'bytes': bytes,
      'contentType': contentType,
      ...sync.syncDiagnostics,
    };
  }

  void _rememberTake(String? filename) {
    if (filename == null || filename.isEmpty) return;
    _probeTakeIds.add(filename);
  }

  MemoketConnector? get _memoket {
    final sync = adapter.offlineSyncConnector;
    return sync is MemoketConnector ? sync : null;
  }

  Future<void> _ensureStandby() async {
    if (adapter.currentState == DeviceTransportState.recording) {
      await adapter.requestStopRecording();
      await _waitForStates(const <DeviceTransportState>{
        DeviceTransportState.connectedStandby,
      }, const Duration(seconds: 8));
    }
  }

  Future<_PcmStats> _collectPcm(
    Duration window, {
    required bool requireFirst,
  }) async {
    final stats = _PcmStats();
    DateTime? lastPacketAt;
    final sub = adapter.pcm16Stream.listen((chunk) {
      final now = DateTime.now();
      stats.packets += 1;
      stats.bytes += chunk.length;
      stats.first ??= now;
      stats.last = now;
      if (lastPacketAt != null) {
        final gap = now.difference(lastPacketAt!);
        if (gap > stats.longestGap) stats.longestGap = gap;
        if (gap > config.pcmGapLimit) stats.gapsOverLimit += 1;
      }
      lastPacketAt = now;
    });
    try {
      if (requireFirst) {
        final firstDeadline = DateTime.now().add(config.firstAudioTimeout);
        while (stats.packets == 0 && DateTime.now().isBefore(firstDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (stats.packets == 0) {
          throw StateError(
            'No decoded PCM arrived within ${config.firstAudioTimeout.inSeconds}s of live capture.',
          );
        }
        _log(
          'pcm first packet bytes=${stats.bytes} '
          'pcmMs=${stats.pcmMs(config.pcmSampleRate)}',
        );
      }
      final windowEnd = DateTime.now().add(window);
      while (DateTime.now().isBefore(windowEnd)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final last = lastPacketAt;
        if (last == null) continue;
        final stall = DateTime.now().difference(last);
        if (stall > stats.longestGap) stats.longestGap = stall;
        if (stall > config.pcmGapLimit) {
          stats.gapsOverLimit += 1;
          stats.trailingSilenceMs = stall.inMilliseconds;
          break;
        }
      }
    } finally {
      await sub.cancel();
    }
    return stats;
  }

  void _assertPcm(_PcmStats stats, Duration window) {
    if (!config.pcmCovers(stats.bytes, window)) {
      throw StateError(
        'Live PCM covered ${stats.pcmMs(config.pcmSampleRate)}ms of '
        '${window.inMilliseconds}ms expected '
        '(${stats.bytes} bytes, ${stats.packets} packets).',
      );
    }
    if (stats.gapsOverLimit > 0) {
      throw StateError(
        'Live stream had ${stats.gapsOverLimit} gap(s) longer than '
        '${config.pcmGapLimit.inSeconds}s (longest ${stats.longestGap.inMilliseconds}ms).',
      );
    }
  }

  Future<int?> _waitForBattery(Duration timeout) async {
    final existing = Completer<int>();
    final sub = adapter.controlEvents.listen((event) {
      if (event.type != DeviceControlEventType.battery) return;
      final level = event.payload['level'];
      if (level is int && !existing.isCompleted) existing.complete(level);
    });
    try {
      return await existing.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _waitForStates(
    Set<DeviceTransportState> wanted,
    Duration timeout,
  ) async {
    final done = Completer<void>();
    final sub = adapter.transportStates.listen((state) {
      if (wanted.contains(state) && !done.isCompleted) done.complete();
    });
    try {
      if (wanted.contains(adapter.currentState)) return;
      await done.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Timed out waiting for ${wanted.map((s) => s.name).join('/')} '
          '(was ${adapter.currentState.name}) after ${timeout.inSeconds}s.',
        ),
      );
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _holdRuntime() async {
    final host = background;
    if (host == null) return;
    await host.apply(
      const BackgroundRuntimeRequest(
        holds: <BackgroundHold>{
          BackgroundHold.wearableLink,
          BackgroundHold.wearableCapture,
          BackgroundHold.wearableSync,
        },
        deviceLabel: 'Memoket E2E',
        deviceConnected: true,
      ),
    );
  }

  bool _stepOk(MemoketE2eReport report, String name) {
    return report.steps.any(
      (step) => step.name == name && step.status == MemoketE2eStepStatus.passed,
    );
  }

  Future<void> _step(
    MemoketE2eReport report,
    String name,
    Future<Object?> Function() body,
  ) async {
    await _stepValue(report, name, body);
  }

  Future<T?> _stepValue<T>(
    MemoketE2eReport report,
    String name,
    Future<T> Function() body,
  ) async {
    _log('BEGIN $name');
    ClientDiagnosticLog.instance.record(
      'memoket_e2e',
      'step_begin',
      details: <String, Object?>{'step': name},
    );
    final started = DateTime.now();
    try {
      final value = await body();
      final details = value is Map<String, Object?>
          ? value
          : value is AudioDeviceDescriptor
          ? <String, Object?>{
              'name': value.displayName,
              'id': value.deviceKey,
              'rssi': value.metadata['rssi'],
            }
          : const <String, Object?>{};
      final result = MemoketE2eStepResult(
        name: name,
        status: MemoketE2eStepStatus.passed,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        details: details,
      );
      report.steps.add(result);
      _log('PASS $name ${result.durationMs}ms');
      await _persist(report);
      return value;
    } catch (error) {
      final result = MemoketE2eStepResult(
        name: name,
        status: MemoketE2eStepStatus.failed,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: error.toString(),
      );
      report.steps.add(result);
      _log('FAIL $name $error');
      ClientDiagnosticLog.instance.record(
        'memoket_e2e',
        'step_failed',
        level: 'error',
        details: <String, Object?>{'step': name, 'error': error.toString()},
      );
      await _persist(report);
      return null;
    }
  }

  Future<MemoketE2eReport> _finish(MemoketE2eReport report) async {
    report.running = false;
    report.finishedAt = DateTime.now().toUtc();
    report.passed = report.allRequiredPassed;
    final path = await MemoketE2eReportSink.writeReport(report.toJson());
    report.reportPath = path;
    await _persist(report);
    final failed = report.steps
        .where((step) => step.status == MemoketE2eStepStatus.failed)
        .map((step) => step.name)
        .join(',');
    _log(
      '${report.passed ? 'PASSED' : 'FAILED'} '
      'steps=${report.steps.length}'
      '${failed.isEmpty ? '' : ' failed=$failed'} '
      'path=${path ?? ''}',
    );
    ClientDiagnosticLog.instance.record(
      'memoket_e2e',
      report.passed ? 'passed' : 'failed',
      level: report.passed ? 'info' : 'error',
      details: <String, Object?>{
        'elapsedMs': report.finishedAt!
            .difference(report.startedAt)
            .inMilliseconds,
        'steps': report.steps.length,
        'reportPath': path,
      },
    );
    return report;
  }

  Future<void> _persist(MemoketE2eReport report) async {
    await MemoketE2eReportSink.writeStatus(report.toJson());
  }

  void _log(String message) {
    developer.log(message, name: _logName);
  }

  static bool _isMemoket(AudioDeviceDescriptor device) {
    final type = device.metadata['type']?.toString();
    if (type == WearableDeviceType.memoket.name) return true;
    return DiscoveredWearable.hasMemoketName(device.displayName);
  }
}

class _PcmStats {
  int bytes = 0;
  int packets = 0;
  int gapsOverLimit = 0;
  int trailingSilenceMs = 0;
  Duration longestGap = Duration.zero;
  DateTime? first;
  DateTime? last;

  int pcmMs(int sampleRate) =>
      sampleRate <= 0 ? 0 : (bytes * 1000) ~/ (sampleRate * 2);

  Map<String, Object?> toJson(int sampleRate) => <String, Object?>{
    'bytes': bytes,
    'packets': packets,
    'pcmMs': pcmMs(sampleRate),
    'wallMs': first == null || last == null
        ? 0
        : last!.difference(first!).inMilliseconds,
    'gapsOverLimit': gapsOverLimit,
    'longestGapMs': longestGap.inMilliseconds,
    'trailingSilenceMs': trailingSilenceMs,
  };
}
