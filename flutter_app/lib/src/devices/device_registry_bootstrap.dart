import 'audio_device_adapter.dart';
import 'omi/omi_device_adapter.dart';

/// Application-level registry bootstrap.
///
/// Concrete device protocols are registered here only after their wire format,
/// lifecycle, and button semantics have been validated. Keeping the default
/// empty prevents an unknown Bluetooth device from being treated as a
/// compatible audio source.
AudioDeviceAdapterRegistry createDefaultDeviceRegistry() {
  return AudioDeviceAdapterRegistry()..register(OmiDeviceAdapter());
}
