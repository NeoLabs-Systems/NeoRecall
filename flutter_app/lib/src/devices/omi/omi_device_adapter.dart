import 'dart:async';
import 'dart:typed_data';

import '../audio_codec_decoder.dart';
import '../audio_device_adapter.dart';
import '../ble/gatt_connector_transport.dart';
import '../ble/gatt_transport.dart';
import '../../diagnostics/client_diagnostic_log.dart';
import 'base_connector.dart';
import 'device_factory.dart';
import 'device_models.dart';

/// Shared GATT adapter for the capture-capable protocols derived from Omi.
///
/// There is deliberately one scanner and connection owner for the complete
/// family. This avoids competing browser choosers/native scans while keeping
/// every device's wire protocol in its own connector.
class OmiDeviceAdapter implements AudioDeviceAdapter {
  OmiDeviceAdapter({GattTransport? gatt})
    : _gatt = gatt ?? createGattTransport();

  static const List<String> _serviceUuids = <String>[
    WearableDeviceUuids.omiService,
    WearableDeviceUuids.plaudService,
    WearableDeviceUuids.fieldyService,
    WearableDeviceUuids.limitlessService,
  ];

  final GattTransport _gatt;
  final StreamController<AudioDeviceDescriptor> _discoveries =
      StreamController<AudioDeviceDescriptor>.broadcast();
  final StreamController<DeviceControlEvent> _controlEvents =
      StreamController<DeviceControlEvent>.broadcast();
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();
  final Map<String, DiscoveredWearable> _found = <String, DiscoveredWearable>{};

  StreamSubscription<GattPeripheral>? _scanSub;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _buttonSub;
  StreamSubscription<int>? _batterySub;
  WearableConnector? _connector;
  WearableAudioDecoder? _decoder;
  WearableAudioDecoder? _frameDecoder;
  OmiFrameAssembler? _assembler;
  DeviceTransportState _state = DeviceTransportState.disconnected;
  bool _initialized = false;
  bool _disposed = false;
  bool _resumeRecordingAfterReconnect = false;
  bool _intentionalDisconnect = false;

  @override
  String get id => 'omi_family';
  @override
  String get displayName => 'Bluetooth audio devices';
  @override
  String get transport => 'bluetooth_le';
  @override
  Stream<AudioDeviceDescriptor> get discoveries => _discoveries.stream;
  @override
  Stream<DeviceControlEvent> get controlEvents => _controlEvents.stream;
  @override
  Stream<Uint8List> get pcm16Stream => _pcm.stream;
  @override
  Stream<DeviceTransportState> get transportStates => _states.stream;

  void _setState(DeviceTransportState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    if (_disposed) throw StateError('OmiDeviceAdapter is already disposed.');
    final availability = await _gatt.availability();
    if (availability == GattAvailability.unsupported) {
      throw UnsupportedError('Bluetooth LE is unavailable on this platform.');
    }
    _initialized = true;
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await initialize();
    await _gatt.requestAccess();
    final availability = await _gatt.availability();
    if (availability == GattAvailability.poweredOff) {
      throw StateError('Bluetooth is turned off.');
    }
    if (availability == GattAvailability.unauthorized) {
      throw StateError('Bluetooth permission was not granted.');
    }
    await stopScan();
    _found.clear();
    _scanSub = _gatt.discoveries.listen(
      _handlePeripheral,
      onError: _discoveries.addError,
    );
    await _gatt.startScan(
      const GattScanSpec(
        serviceUuids: _serviceUuids,
        // PLAUD firmware versions do not consistently advertise their primary
        // service, so the documented product prefix is included.
        namePrefixes: <String>[
          'PLAUD',
          'Compass',
          'Fieldy',
          'Limitless',
          'Pendant',
          'Pocket',
        ],
      ),
      timeout: timeout,
    );
  }

  void _handlePeripheral(GattPeripheral peripheral) {
    final name = peripheral.name.trim();
    if (name.isEmpty) return;
    final services = peripheral.serviceUuids
        .map((value) => value.toLowerCase())
        .toList(growable: false);
    final type = DiscoveredWearable.classify(
      name: name,
      serviceUuids: services,
    );
    final wearable = DiscoveredWearable(
      id: peripheral.id,
      name: name,
      type: type,
      rssi: peripheral.rssi ?? 0,
      serviceUuids: services,
    );
    final old = _found[wearable.id];
    if (old != null && old.rssi == wearable.rssi) return;
    final identityValidated = _hasValidatedIdentity(wearable);
    final locallyDecodable = _hasLocalDecoder(type);
    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'peripheral_discovered',
      details: <String, Object?>{
        'name': name,
        'classifiedType': type.name,
        'advertisedServices': services,
        'identityValidated': identityValidated,
        'locallyDecodable': locallyDecodable,
      },
    );
    if ((!identityValidated || !locallyDecodable) &&
        type != WearableDeviceType.custom) {
      return;
    }
    _found[wearable.id] = wearable;
    if (!_discoveries.isClosed) _discoveries.add(_toDescriptor(wearable));
  }

  bool _hasValidatedIdentity(DiscoveredWearable device) {
    bool has(String uuid) => device.serviceUuids.contains(uuid.toLowerCase());
    final name = device.name.toLowerCase();
    return switch (device.type) {
      WearableDeviceType.omi => has(WearableDeviceUuids.omiService),
      WearableDeviceType.omiGlass =>
        has(WearableDeviceUuids.omiService) &&
            (name.startsWith('omiglass') || name.startsWith('openglass')),
      WearableDeviceType.bee =>
        has(WearableDeviceUuids.beeService) || name.startsWith('bee'),
      WearableDeviceType.plaud =>
        has(WearableDeviceUuids.plaudService) || name.startsWith('plaud'),
      WearableDeviceType.fieldy =>
        has(WearableDeviceUuids.fieldyService) ||
            name == 'fieldy' ||
            name == 'compass',
      WearableDeviceType.friendPendant =>
        has(WearableDeviceUuids.friendService) || name.startsWith('friend_'),
      WearableDeviceType.limitless =>
        has(WearableDeviceUuids.limitlessService) ||
            name.startsWith('limitless') ||
            name == 'pendant',
      WearableDeviceType.custom => false,
    };
  }

  bool _hasLocalDecoder(WearableDeviceType type) {
    return switch (type) {
      WearableDeviceType.omi ||
      WearableDeviceType.omiGlass ||
      WearableDeviceType.plaud ||
      WearableDeviceType.fieldy ||
      WearableDeviceType.limitless => true,
      WearableDeviceType.bee ||
      WearableDeviceType.friendPendant ||
      WearableDeviceType.custom => false,
    };
  }

  AudioDeviceDescriptor _toDescriptor(DiscoveredWearable device) {
    return AudioDeviceDescriptor(
      adapterId: id,
      deviceKey: device.id,
      displayName: device.name,
      transport: transport,
      supportsHardwareButtons:
          device.type == WearableDeviceType.omi ||
          device.type == WearableDeviceType.omiGlass ||
          device.type == WearableDeviceType.limitless,
      supportsMicrophone: device.type != WearableDeviceType.custom,
      metadata: <String, Object?>{
        'type': device.type.name,
        'rssi': device.rssi,
        'serviceUuids': device.serviceUuids,
        'compatibilityUnknown': device.type == WearableDeviceType.custom,
      },
    );
  }

  @override
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    await _gatt.stopScan();
  }

  @override
  Future<void> connect(AudioDeviceDescriptor device) async {
    await initialize();
    if (device.adapterId != id) {
      throw ArgumentError.value(device.adapterId, 'device.adapterId');
    }
    await stopScan();
    final resumeRecording = _resumeRecordingAfterReconnect;
    await _disconnectProtocol(clearResumeIntent: false);
    var wearable = _found[device.deviceKey] ?? _restoreDescriptor(device);
    if (wearable.type == WearableDeviceType.custom) {
      wearable = await _probeProtocol(wearable);
    }
    if (!_hasValidatedIdentity(wearable) || !_hasLocalDecoder(wearable.type)) {
      throw UnsupportedError(
        '${wearable.name} has no fully local, validated capture pipeline.',
      );
    }

    ClientDiagnosticLog.instance.record(
      'bluetooth',
      'connection_started',
      details: <String, Object?>{
        'name': wearable.name,
        'type': wearable.type.name,
      },
    );
    _setState(DeviceTransportState.connecting);
    final wearableTransport = GattConnectorTransport(
      gatt: _gatt,
      deviceId: wearable.id,
    );
    final connector = createWearableConnector(wearable, wearableTransport);
    _connectionSub = wearableTransport.connectionStateStream.listen((
      connected,
    ) {
      if (!connected &&
          !_intentionalDisconnect &&
          _state != DeviceTransportState.connecting) {
        if (_state == DeviceTransportState.recording) {
          _resumeRecordingAfterReconnect = true;
        }
        _setState(DeviceTransportState.disconnected);
      }
    });

    try {
      await connector.connect(
        requiresPairing: wearable.type == WearableDeviceType.limitless,
      );
      _connector = connector;
      final omiFraming =
          wearable.type == WearableDeviceType.omi ||
          wearable.type == WearableDeviceType.omiGlass;
      _decoder = WearableAudioDecoder(
        codec: connector.codec,
        stripBleHeader: omiFraming,
      );
      _frameDecoder = WearableAudioDecoder(
        codec: connector.codec,
        stripBleHeader: false,
      );
      _assembler = omiFraming ? OmiFrameAssembler() : null;
      _audioSub = connector.audioBytes.stream.listen(_handleAudioPacket);
      _buttonSub = connector.buttonEvents.stream.listen(_handleButton);
      _batterySub = connector.batteryLevels.stream.listen(_handleBattery);
      _setState(DeviceTransportState.connectedStandby);
      ClientDiagnosticLog.instance.record(
        'bluetooth',
        'connection_ready',
        details: <String, Object?>{
          'name': wearable.name,
          'type': wearable.type.name,
          'codec': connector.codec.name,
        },
      );
      if (resumeRecording) {
        await connector.startRecording();
        _setState(DeviceTransportState.recording);
      }
    } catch (error) {
      ClientDiagnosticLog.instance.record(
        'bluetooth',
        'connection_failed',
        level: 'error',
        details: <String, Object?>{
          'name': wearable.name,
          'type': wearable.type.name,
          'error': error.toString(),
        },
      );
      try {
        await connector.dispose();
      } catch (_) {
        // Preserve the connection/setup error while still clearing local state.
      }
      await _clearProtocolState();
      _setState(DeviceTransportState.faulted);
      rethrow;
    }
  }

  Future<DiscoveredWearable> _probeProtocol(DiscoveredWearable device) async {
    var connected = false;
    try {
      await _gatt.connect(device.id, autoReconnect: false);
      connected = true;
      var services = await _gatt.discoverServices(device.id);
      var type = DiscoveredWearable.classify(
        name: device.name,
        serviceUuids: services,
      );
      var paired = false;
      if (type == WearableDeviceType.custom) {
        try {
          await _gatt.pair(device.id);
          paired = true;
          services = await _gatt.discoverServices(device.id);
          type = DiscoveredWearable.classify(
            name: device.name,
            serviceUuids: services,
          );
        } catch (error) {
          ClientDiagnosticLog.instance.record(
            'bluetooth',
            'pairing_failed',
            level: 'warning',
            details: <String, Object?>{
              'name': device.name,
              'error': error.toString(),
            },
          );
        }
      }
      final probed = DiscoveredWearable(
        id: device.id,
        name: device.name,
        type: type,
        rssi: device.rssi,
        serviceUuids: services,
      );
      ClientDiagnosticLog.instance.record(
        'bluetooth',
        'compatibility_checked',
        details: <String, Object?>{
          'name': device.name,
          'classifiedType': probed.type.name,
          'services': services,
          'paired': paired,
        },
      );
      return probed;
    } finally {
      if (connected) {
        try {
          await _gatt.disconnect(device.id);
        } catch (_) {}
      }
    }
  }

  DiscoveredWearable _restoreDescriptor(AudioDeviceDescriptor device) {
    final typeName = device.metadata['type'] as String?;
    final type = WearableDeviceType.values.firstWhere(
      (value) => value.name == typeName,
      orElse: () => WearableDeviceType.custom,
    );
    return DiscoveredWearable(
      id: device.deviceKey,
      name: device.displayName,
      type: type,
      rssi: device.metadata['rssi'] as int? ?? 0,
      serviceUuids: List<String>.from(
        device.metadata['serviceUuids'] as List? ?? const <String>[],
      ),
    );
  }

  void _handleAudioPacket(List<int> packet) {
    final decoder = _decoder;
    if (decoder == null) return;
    final assembled = _assembler?.accept(packet);
    if (_assembler != null && assembled == null) return;
    final activeDecoder = assembled == null ? decoder : _frameDecoder!;
    final pcm = activeDecoder.decodePacket(assembled ?? packet);
    if (pcm != null && pcm.isNotEmpty && !_pcm.isClosed) {
      _pcm.add(pcm);
    } else if (activeDecoder.lastWarning != null) {
      _emitProtocolWarning(activeDecoder.lastWarning!);
    }
  }

  void _handleButton(List<int> value) {
    final code = value.isEmpty ? 0 : value.first;
    final type = switch (code) {
      1 => DeviceControlEventType.singlePress,
      2 => DeviceControlEventType.doublePress,
      3 => DeviceControlEventType.longPress,
      5 => DeviceControlEventType.buttonRelease,
      _ => DeviceControlEventType.custom,
    };
    if (!_controlEvents.isClosed) {
      _controlEvents.add(
        DeviceControlEvent(
          type: type,
          payload: <String, Object?>{'raw': value},
          receivedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  void _handleBattery(int level) {
    if (!_controlEvents.isClosed) {
      _controlEvents.add(
        DeviceControlEvent(
          type: DeviceControlEventType.battery,
          payload: <String, Object?>{'level': level},
          receivedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  void _emitProtocolWarning(String warning) {
    ClientDiagnosticLog.instance.record(
      'bluetooth_audio',
      'decode_warning',
      level: 'warning',
      details: <String, Object?>{'warning': warning},
    );
    if (!_controlEvents.isClosed) {
      _controlEvents.add(
        DeviceControlEvent(
          type: DeviceControlEventType.custom,
          payload: <String, Object?>{'warning': warning},
          receivedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  @override
  Future<void> requestStartRecording() async {
    final connector = _connector;
    if (connector == null || _state != DeviceTransportState.connectedStandby) {
      throw StateError('No ready Bluetooth audio device is connected.');
    }
    if (!(_decoder?.isSupported ?? false)) {
      throw UnsupportedError(
        '${connector.codec.name} cannot be decoded locally on this platform.',
      );
    }
    await connector.startRecording();
    _resumeRecordingAfterReconnect = true;
    _setState(DeviceTransportState.recording);
  }

  @override
  Future<void> requestStopRecording() async {
    _resumeRecordingAfterReconnect = false;
    final connector = _connector;
    if (connector == null || _state != DeviceTransportState.recording) return;
    await connector.stopRecording();
    _setState(DeviceTransportState.connectedStandby);
  }

  @override
  Future<void> disconnect() async {
    await _disconnectProtocol(clearResumeIntent: true);
  }

  Future<void> _disconnectProtocol({required bool clearResumeIntent}) async {
    if (clearResumeIntent) _resumeRecordingAfterReconnect = false;
    final connector = _connector;
    _connector = null;
    _intentionalDisconnect = true;
    try {
      if (connector != null) await connector.dispose();
    } finally {
      try {
        await _clearProtocolState();
        _setState(DeviceTransportState.disconnected);
      } finally {
        _intentionalDisconnect = false;
      }
    }
  }

  Future<void> _clearProtocolState() async {
    await _cancelSafely(_audioSub);
    await _cancelSafely(_buttonSub);
    await _cancelSafely(_batterySub);
    await _cancelSafely(_connectionSub);
    _audioSub = null;
    _buttonSub = null;
    _batterySub = null;
    _connectionSub = null;
    _decoder?.dispose();
    _frameDecoder?.dispose();
    _decoder = null;
    _frameDecoder = null;
    _assembler?.reset();
    _assembler = null;
  }

  Future<void> _cancelSafely(StreamSubscription<dynamic>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (_) {
      // Cleanup must continue after a transport/plugin failure.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopScan();
    await disconnect();
    await _gatt.dispose();
    _disposed = true;
    await _discoveries.close();
    await _controlEvents.close();
    await _pcm.close();
    await _states.close();
  }
}
