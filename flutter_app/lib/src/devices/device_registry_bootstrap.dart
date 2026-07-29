import 'audio_device_adapter.dart';
import 'omi/omi_device_adapter.dart';

/// Registers all built-in wearable adapters.
AudioDeviceAdapterRegistry createDefaultDeviceRegistry() {
  final registry = AudioDeviceAdapterRegistry();
  registry.register(OmiDeviceAdapter());
  return registry;
}
