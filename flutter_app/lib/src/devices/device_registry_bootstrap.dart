import 'audio_device_adapter.dart';
import 'omi/device_adapter.dart';
import 'plaud/plaud_adapter.dart';
import 'plaud/plaud_session.dart';

AudioDeviceAdapterRegistry createDefaultDeviceRegistry({
  PlaudSessionFetcher? plaudSession,
}) {
  final plaud = PlaudAdapter(fetchSession: plaudSession);
  return AudioDeviceAdapterRegistry()
    ..register(DeviceAdapter())
    ..register(plaud);
}

void bindPlaudSessionFetcher(
  AudioDeviceAdapterRegistry registry,
  PlaudSessionFetcher fetchSession,
) {
  final adapter = registry[PlaudAdapter.adapterId];
  if (adapter is PlaudAdapter) adapter.attachSessionFetcher(fetchSession);
}
