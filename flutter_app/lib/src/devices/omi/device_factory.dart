import '../ble/gatt_connector_transport.dart';
import 'base_connector.dart';
import 'device_models.dart';
import 'heypocket_connector.dart';
import 'omi_connector.dart';

WearableConnector createWearableConnector(
  DiscoveredWearable device,
  WearableTransport transport,
) {
  switch (device.type) {
    case WearableDeviceType.omi:
      return OmiConnector(device: device, transport: transport);
    case WearableDeviceType.omiGlass:
      return OmiGlassConnector(device: device, transport: transport);
    case WearableDeviceType.heyPocket:
      return HeyPocketConnector(device: device, transport: transport);
    case WearableDeviceType.custom:
      throw UnsupportedError(
        'No validated wearable protocol matches ${device.name}.',
      );
  }
}
