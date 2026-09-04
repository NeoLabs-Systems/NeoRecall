import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/audio_device_adapter.dart';
import 'package:neorecall/src/devices/plaud/plaud_adapter.dart';
import 'package:neorecall/src/devices/plaud/plaud_hardware.dart';
import 'package:neorecall/src/devices/plaud/plaud_session.dart';

void main() {
  test('scan and connect bind through Embedded hardware, not a cloud file poll', () async {
    final hardware = _FakePlaudHardware();
    final adapter = PlaudAdapter(
      hardware: hardware,
      fetchSession: () async => PlaudEmbeddedSession(
        accessToken: 'user-jwt',
        customDomain: 'platform-us.plaud.ai',
        userId: 'neouser',
        expiresAt: DateTime.now().add(const Duration(hours: 12)),
      ),
      connectTimeout: const Duration(seconds: 2),
    );
    final seen = <AudioDeviceDescriptor>[];
    adapter.discoveries.listen(seen.add);
    await adapter.startScan(timeout: const Duration(milliseconds: 20));
    expect(seen, isNotEmpty);
    expect(seen.first.metadata['type'], 'plaud');
    expect(hardware.initialized, isTrue);

    await adapter.connect(seen.first);
    expect(adapter.offlineSyncConnector, isNotNull);
    await adapter.dispose();
  });

  test('drain exports locally, ingest first, then deletes on the device', () async {
    final hardware = _FakePlaudHardware();
    final adapter = PlaudAdapter(
      hardware: hardware,
      fetchSession: () async => PlaudEmbeddedSession(
        accessToken: 'user-jwt',
        customDomain: 'platform-us.plaud.ai',
        userId: 'neouser',
        expiresAt: DateTime.now().add(const Duration(hours: 12)),
      ),
      connectTimeout: const Duration(seconds: 2),
      fileListTimeout: const Duration(seconds: 2),
      exportTimeout: const Duration(seconds: 2),
      deleteTimeout: const Duration(seconds: 2),
    );
    await adapter.startScan(timeout: const Duration(milliseconds: 10));
    await adapter.connect(
      AudioDeviceDescriptor(
        adapterId: PlaudAdapter.adapterId,
        deviceKey: 'uuid-1',
        displayName: 'Note Pro',
        transport: 'bluetooth_le',
        metadata: const <String, Object?>{
          'type': 'plaud',
          'uuid': 'uuid-1',
          'serialNumber': '8811',
        },
      ),
    );

    final ingested = <String>[];
    final order = <String>[];
    hardware.onExport = () => order.add('export');
    hardware.onDelete = () => order.add('delete');
    await adapter.drainStoredAudio((recording) async {
      order.add('ingest');
      ingested.add(recording.id);
      expect(recording.contentType, 'audio/mpeg');
      expect(recording.bytes, isNotEmpty);
    });
    expect(ingested, ['plaud:8811:1700000000']);
    expect(order, ['export', 'ingest', 'delete']);
    expect(hardware.deleted, [1700000000]);
    await adapter.dispose();
  });

  test('a failed ingest leaves the recording on the device', () async {
    final hardware = _FakePlaudHardware();
    final adapter = PlaudAdapter(
      hardware: hardware,
      fetchSession: () async => PlaudEmbeddedSession(
        accessToken: 'user-jwt',
        customDomain: 'platform-us.plaud.ai',
        userId: 'neouser',
        expiresAt: DateTime.now().add(const Duration(hours: 12)),
      ),
      connectTimeout: const Duration(seconds: 2),
      fileListTimeout: const Duration(seconds: 2),
    );
    await adapter.startScan(timeout: const Duration(milliseconds: 10));
    await adapter.connect(
      AudioDeviceDescriptor(
        adapterId: PlaudAdapter.adapterId,
        deviceKey: 'uuid-1',
        displayName: 'Note Pro',
        transport: 'bluetooth_le',
        metadata: const <String, Object?>{
          'uuid': 'uuid-1',
          'serialNumber': '8811',
        },
      ),
    );
    await expectLater(
      adapter.drainStoredAudio((_) async {
        throw StateError('ingest failed');
      }),
      throwsStateError,
    );
    expect(hardware.deleted, isEmpty);
    await adapter.dispose();
  });

  test('unavailable hardware tells the user to use iOS or Android', () async {
    final adapter = PlaudAdapter(
      hardware: UnavailablePlaudHardware(),
      fetchSession: () async => PlaudEmbeddedSession(
        accessToken: 'user-jwt',
        customDomain: 'platform-us.plaud.ai',
        userId: 'neouser',
        expiresAt: DateTime.now().add(const Duration(hours: 12)),
      ),
    );
    await expectLater(
      adapter.connect(
        AudioDeviceDescriptor(
          adapterId: PlaudAdapter.adapterId,
          deviceKey: 'uuid-1',
          displayName: 'Note Pro',
          transport: 'bluetooth_le',
        ),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('iOS and Android'),
        ),
      ),
    );
    await adapter.dispose();
  });
}

class _FakePlaudHardware implements PlaudHardware {
  final _scan = StreamController<List<PlaudDiscoveredDevice>>.broadcast();
  final _connect = StreamController<PlaudConnectUpdate>.broadcast();
  final _files = StreamController<List<PlaudStoredFile>>.broadcast();
  final _export = StreamController<PlaudExportUpdate>.broadcast();
  final _battery = StreamController<int>.broadcast();
  final _deletes = StreamController<({int sessionId, bool ok})>.broadcast();

  bool initialized = false;
  final List<int> deleted = <int>[];
  void Function()? onExport;
  void Function()? onDelete;

  static const _device = PlaudDiscoveredDevice(
    name: 'Note Pro',
    uuid: 'uuid-1',
    serialNumber: '8811',
    rssi: -40,
  );

  @override
  bool get isAvailable => true;
  @override
  Stream<List<PlaudDiscoveredDevice>> get scanResults => _scan.stream;
  @override
  Stream<PlaudConnectUpdate> get connectUpdates => _connect.stream;
  @override
  Stream<List<PlaudStoredFile>> get fileLists => _files.stream;
  @override
  Stream<PlaudExportUpdate> get exportProgress => _export.stream;
  @override
  Stream<int> get batteryLevels => _battery.stream;
  @override
  Stream<({int sessionId, bool ok})> get deleteResults => _deletes.stream;

  @override
  Future<void> initialize({
    required String accessToken,
    required String customDomain,
    required String userId,
  }) async {
    initialized = true;
  }

  @override
  Future<void> startScan() async {
    _scan.add(const [_device]);
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect({
    String? uuid,
    String? serialNumber,
    String? deviceToken,
  }) async {
    _connect.add(const PlaudConnectUpdate(connected: true, failed: false));
  }

  @override
  Future<void> disconnect() async {
    _connect.add(const PlaudConnectUpdate(connected: false, failed: false));
  }

  @override
  Future<void> getFileList({int startSessionId = 0}) async {
    _files.add(const [
      PlaudStoredFile(
        sessionId: 1700000000,
        size: 2048,
        durationSeconds: 12,
        serialNumber: '8811',
      ),
    ]);
  }

  @override
  Future<Uint8List> exportAudio(int sessionId) async {
    onExport?.call();
    return Uint8List.fromList(List<int>.filled(64, 0xff));
  }

  @override
  Future<void> deleteFile(int sessionId) async {
    onDelete?.call();
    deleted.add(sessionId);
    _deletes.add((sessionId: sessionId, ok: true));
  }
}
