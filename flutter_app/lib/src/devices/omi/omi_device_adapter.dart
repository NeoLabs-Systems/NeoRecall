import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../audio_codec_decoder.dart';
import '../audio_device_adapter.dart';
import '../ble/ble_transport.dart';
import 'base_connector.dart';
import 'device_factory.dart';
import 'device_models.dart';

/// Integrates all supported Omi-family wearable connectors into NeoRecall.
class OmiDeviceAdapter implements AudioDeviceAdapter {
  final StreamController<AudioDeviceDescriptor> _discoveries =
      StreamController<AudioDeviceDescriptor>.broadcast();
  final StreamController<DeviceControlEvent> _controlEvents =
      StreamController<DeviceControlEvent>.broadcast();
  final StreamController<Uint8List> _pcm =
      StreamController<Uint8List>.broadcast();
  final StreamController<DeviceTransportState> _states =
      StreamController<DeviceTransportState>.broadcast();

  final Map<String, DiscoveredWearable> _found = <String, DiscoveredWearable>{};
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<List<int>>? _audioSub;
  StreamSubscription<List<int>>? _buttonSub;
  StreamSubscription<int>? _batterySub;
  WearableConnector? _connector;
  WearableAudioDecoder? _decoder;
  WearableAudioDecoder? _frameDecoder;
  OmiFrameAssembler? _assembler;
  DeviceTransportState state = DeviceTransportState.disconnected;
  bool _initialized = false;

  @override
  String get id => 'omi_family';
  @override
  String get displayName => 'Omi-compatible wearables';
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
    state = next;
    if (!_states.isClosed) _states.add(next);
  }

  AudioDeviceDescriptor _toDescriptor(DiscoveredWearable device) {
    return AudioDeviceDescriptor(
      adapterId: id,
      deviceKey: device.id,
      displayName: device.name,
      transport: transport,
      supportsMicrophone: true,
      supportsSystemAudio: false,
      supportsHardwareButtons: true,
      metadata: <String, Object?>{
        'type': device.type.name,
        'rssi': device.rssi,
        'serviceUuids': device.serviceUuids,
      },
    );
  }

  bool _isSupported(DiscoveredWearable wearable) {
    switch (wearable.type) {
      case WearableDeviceType.omi:
      case WearableDeviceType.omiGlass:
      case WearableDeviceType.bee:
      case WearableDeviceType.plaud:
      case WearableDeviceType.fieldy:
      case WearableDeviceType.friendPendant:
      case WearableDeviceType.limitless:
        return true;
      case WearableDeviceType.custom:
        return wearable.serviceUuids.isNotEmpty;
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized || kIsWeb) {
      _initialized = true;
      return;
    }
    _initialized = true;
  }

  @override
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await initialize();
    if (kIsWeb) return;
    await BleTransport.ensurePermissions();
    if (!await BleTransport.isAdapterOn()) {
      throw StateError('Bluetooth is turned off.');
    }
    await stopScan();
    _found.clear();
    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidUsesFineLocation: true,
    );
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final wearable = DiscoveredWearable.fromScanResult(result);
        if (!_isSupported(wearable) || wearable.name.trim().isEmpty) continue;
        final previous = _found[wearable.id];
        if (previous != null && previous.rssi == wearable.rssi) continue;
        _found[wearable.id] = wearable;
        if (!_discoveries.isClosed) {
          _discoveries.add(_toDescriptor(wearable));
        }
      }
    });
  }

  @override
  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  @override
  Future<void> connect(AudioDeviceDescriptor device) async {
    await initialize();
    await BleTransport.ensurePermissions();
    await stopScan();
    final discovered =
        _found[device.deviceKey] ??
        DiscoveredWearable(
          id: device.deviceKey,
          name: device.displayName,
          type: WearableDeviceType.values.firstWhere(
            (value) =>
                value.name == (device.metadata['type'] as String? ?? 'omi'),
            orElse: () => WearableDeviceType.omi,
          ),
          rssi: device.metadata['rssi'] as int? ?? 0,
          serviceUuids: List<String>.from(
            device.metadata['serviceUuids'] as List? ?? const <String>[],
          ),
        );

    _setState(DeviceTransportState.connecting);
    final connector = createWearableConnector(discovered);
    try {
      await connector.connect();
      _connector = connector;
      final isOmiFamily =
          discovered.type == WearableDeviceType.omi ||
          discovered.type == WearableDeviceType.omiGlass;
      _decoder = WearableAudioDecoder(
        codec: connector.codec,
        // Direct packets may still include transport headers for non-assembled paths.
        stripBleHeader: isOmiFamily,
      );
      _frameDecoder = WearableAudioDecoder(
        codec: connector.codec,
        stripBleHeader: false,
      );
      _assembler = isOmiFamily ? OmiFrameAssembler() : null;

      await _audioSub?.cancel();
      await _buttonSub?.cancel();
      await _batterySub?.cancel();

      _audioSub = connector.audioBytes.stream.listen((packet) {
        _handleAudioPacket(packet);
      });
      _buttonSub = connector.buttonEvents.stream.listen((value) {
        final code = value.isNotEmpty ? value.first : 0;
        final type = switch (code) {
          1 => DeviceControlEventType.startRecording,
          2 => DeviceControlEventType.stopRecording,
          3 => DeviceControlEventType.standby,
          4 => DeviceControlEventType.wake,
          _ => DeviceControlEventType.custom,
        };
        _controlEvents.add(
          DeviceControlEvent(
            type: type,
            payload: <String, Object?>{'raw': value},
            receivedAt: DateTime.now().toUtc(),
          ),
        );
      });
      _batterySub = connector.batteryLevels.stream.listen((level) {
        _controlEvents.add(
          DeviceControlEvent(
            type: DeviceControlEventType.battery,
            payload: <String, Object?>{'level': level},
            receivedAt: DateTime.now().toUtc(),
          ),
        );
      });
      _setState(DeviceTransportState.connectedStandby);
    } catch (error) {
      await connector.dispose();
      _connector = null;
      _decoder?.dispose();
      _decoder = null;
      _assembler = null;
      _setState(DeviceTransportState.faulted);
      rethrow;
    }
  }

  void _handleAudioPacket(List<int> packet) {
    final decoder = _decoder;
    if (decoder == null) return;

    if (_assembler != null) {
      final assembled = _assembler!.accept(packet);
      if (assembled == null) return;
      final frameDecoder = _frameDecoder ?? decoder;
      final pcm = frameDecoder.decodePacket(assembled);
      if (pcm != null && pcm.isNotEmpty && !_pcm.isClosed) {
        _pcm.add(pcm);
      } else if (frameDecoder.lastWarning != null) {
        _controlEvents.add(
          DeviceControlEvent(
            type: DeviceControlEventType.custom,
            payload: <String, Object?>{'warning': frameDecoder.lastWarning},
            receivedAt: DateTime.now().toUtc(),
          ),
        );
      }
      return;
    }

    final pcm = decoder.decodePacket(packet);
    if (pcm != null && pcm.isNotEmpty) {
      if (!_pcm.isClosed) _pcm.add(pcm);
    } else if (decoder.lastWarning != null) {
      _controlEvents.add(
        DeviceControlEvent(
          type: DeviceControlEventType.custom,
          payload: <String, Object?>{'warning': decoder.lastWarning},
          receivedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  @override
  Future<void> disconnect() async {
    await _audioSub?.cancel();
    await _buttonSub?.cancel();
    await _batterySub?.cancel();
    _audioSub = null;
    _buttonSub = null;
    _batterySub = null;
    await _connector?.dispose();
    _connector = null;
    _decoder?.dispose();
    _decoder = null;
    _frameDecoder?.dispose();
    _frameDecoder = null;
    _assembler?.reset();
    _assembler = null;
    _setState(DeviceTransportState.disconnected);
  }

  @override
  Future<void> requestStartRecording() async {
    final connector = _connector;
    if (connector == null) {
      throw StateError('No wearable is connected.');
    }
    if (!_decoder!.isSupported) {
      throw StateError(
        'Connected device codec (${connector.codec.name}) is not decodable yet.',
      );
    }
    await connector.startRecording();
    _setState(DeviceTransportState.recording);
  }

  @override
  Future<void> requestStopRecording() async {
    final connector = _connector;
    if (connector == null) return;
    await connector.stopRecording();
    _setState(DeviceTransportState.connectedStandby);
  }

  @override
  Future<void> dispose() async {
    await stopScan();
    await disconnect();
    await _discoveries.close();
    await _controlEvents.close();
    await _pcm.close();
    await _states.close();
  }
}
