import 'dart:async';
import 'dart:typed_data';

/// Physical / transport button and lifecycle states for external recorders.
enum DeviceTransportState {
  unknown,
  disconnected,
  connecting,
  connectedStandby,
  recording,
  faulted,
}

enum DeviceControlEventType {
  powerOn,
  powerOff,
  startRecording,
  stopRecording,
  standby,
  wake,
  battery,
  singlePress,
  doublePress,
  longPress,
  buttonRelease,
  custom,
}

class DeviceControlEvent {
  const DeviceControlEvent({
    required this.type,
    this.payload = const <String, Object?>{},
    this.receivedAt,
  });

  final DeviceControlEventType type;
  final Map<String, Object?> payload;
  final DateTime? receivedAt;
}

class AudioDeviceDescriptor {
  const AudioDeviceDescriptor({
    required this.adapterId,
    required this.deviceKey,
    required this.displayName,
    required this.transport,
    this.supportsMicrophone = true,
    this.supportsSystemAudio = false,
    this.supportsHardwareButtons = false,
    this.metadata = const <String, Object?>{},
  });

  final String adapterId;
  final String deviceKey;
  final String displayName;
  final String transport;
  final bool supportsMicrophone;
  final bool supportsSystemAudio;
  final bool supportsHardwareButtons;
  final Map<String, Object?> metadata;
}

/// A validated protocol adapter paired with the descriptor it discovered.
///
/// Recorder implementations consume this platform-neutral value, so mobile,
/// desktop, and web all use the same device flow without importing a concrete
/// Bluetooth package or vendor protocol.
class ExternalAudioCaptureDevice {
  const ExternalAudioCaptureDevice({
    required this.adapter,
    required this.descriptor,
  });

  final AudioDeviceAdapter adapter;
  final AudioDeviceDescriptor descriptor;
}

/// One transport-specific integration (BLE classic, BLE GATT, Wi-Fi, USB, …).
abstract class AudioDeviceAdapter {
  String get id;
  String get displayName;
  String get transport;

  Stream<AudioDeviceDescriptor> get discoveries;
  Stream<DeviceControlEvent> get controlEvents;
  Stream<Uint8List> get pcm16Stream;
  Stream<DeviceTransportState> get transportStates;

  Future<void> initialize();
  Future<void> startScan({Duration timeout = const Duration(seconds: 12)});
  Future<void> stopScan();
  Future<void> connect(AudioDeviceDescriptor device);
  Future<void> disconnect();
  Future<void> requestStartRecording();
  Future<void> requestStopRecording();
  Future<void> dispose();
}

/// Registry so new wearable brands can be added without rewriting mobile UI.
class AudioDeviceAdapterRegistry {
  final Map<String, AudioDeviceAdapter> _adapters =
      <String, AudioDeviceAdapter>{};

  void register(AudioDeviceAdapter adapter) {
    _adapters[adapter.id] = adapter;
  }

  List<AudioDeviceAdapter> get adapters =>
      List<AudioDeviceAdapter>.unmodifiable(_adapters.values);

  AudioDeviceAdapter? operator [](String id) => _adapters[id];

  Future<void> initializeAll() async {
    for (final adapter in _adapters.values) {
      await adapter.initialize();
    }
  }

  Future<void> disposeAll() async {
    for (final adapter in _adapters.values) {
      await adapter.dispose();
    }
    _adapters.clear();
  }
}
