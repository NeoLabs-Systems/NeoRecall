import '../ble/ble_transport.dart';
import 'base_connector.dart';
import 'custom_command_connector.dart';
import 'device_models.dart';
import 'friend_connector.dart';
import 'limitless_connector.dart';
import 'omi_connector.dart';
import 'plaud_connector.dart';

WearableConnector createWearableConnector(DiscoveredWearable device) {
  final transport = BleTransport(
    device.id,
    requiresBond: device.type == WearableDeviceType.limitless,
  );
  switch (device.type) {
    case WearableDeviceType.omi:
      return OmiConnector(device: device, transport: transport);
    case WearableDeviceType.omiGlass:
      return OmiGlassConnector(device: device, transport: transport);
    case WearableDeviceType.bee:
      return BeeConnector(device: device, transport: transport);
    case WearableDeviceType.fieldy:
      return FieldyConnector(device: device, transport: transport);
    case WearableDeviceType.plaud:
      return PlaudConnector(device: device, transport: transport);
    case WearableDeviceType.friendPendant:
      return FriendPendantConnector(device: device, transport: transport);
    case WearableDeviceType.limitless:
      return LimitlessConnector(device: device, transport: transport);
    case WearableDeviceType.custom:
      return OmiConnector(device: device, transport: transport);
  }
}
