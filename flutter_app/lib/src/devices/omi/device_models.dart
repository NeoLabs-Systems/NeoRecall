import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Device types supported by the Omi connector port.
enum WearableDeviceType {
  omi,
  omiGlass,
  bee,
  plaud,
  fieldy,
  friendPendant,
  limitless,
  custom,
}

enum WearableAudioCodec { pcm8, pcm16, opus, opusFs320, aac, lc3, unknown }

class WearableDeviceUuids {
  static const omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const omiAudioData = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const omiAudioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  static const buttonService = '23ba7924-0000-1000-7450-346eac492e92';
  static const buttonTrigger = '23ba7925-0000-1000-7450-346eac492e92';
  static const timeSyncService = '19b10030-e8f2-537e-4f6c-d104768a1214';
  static const timeSyncWrite = '19b10031-e8f2-537e-4f6c-d104768a1214';
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  static const plaudService = '00001910-0000-1000-8000-00805f9b34fb';
  static const plaudWrite = '00002bb1-0000-1000-8000-00805f9b34fb';
  static const plaudNotify = '00002bb0-0000-1000-8000-00805f9b34fb';
  static const beeService = '03d5d5c4-a86c-11ee-9d89-8f2089a49e7e';
  static const beeControl = '05e1f93c-d8d0-5ed8-dd88-379e4c1a3e3e';
  static const beeAudio = 'b189a505-a86c-11ee-a5fb-8f2089a49e7e';
  static const fieldyService = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const fieldyAudio = '82a48422-3ca9-4156-ae67-4170f58666e0';
  static const friendService = '1a3fd0e7-b1f3-ac9e-2e49-b647b2c4f8da';
  static const friendAudio = '01000000-1111-1111-1111-111111111111';
  static const limitlessService = '632de001-604c-446b-a80f-7963e950f3fb';
  static const limitlessTx = '632de002-604c-446b-a80f-7963e950f3fb';
  static const limitlessRx = '632de003-604c-446b-a80f-7963e950f3fb';
}

class DiscoveredWearable {
  const DiscoveredWearable({
    required this.id,
    required this.name,
    required this.type,
    required this.rssi,
    this.serviceUuids = const <String>[],
  });

  final String id;
  final String name;
  final WearableDeviceType type;
  final int rssi;
  final List<String> serviceUuids;

  factory DiscoveredWearable.fromScanResult(ScanResult result) {
    final name = result.advertisementData.advName.isNotEmpty
        ? result.advertisementData.advName
        : (result.device.platformName.isNotEmpty
              ? result.device.platformName
              : 'Unknown device');
    final services = result.advertisementData.serviceUuids
        .map((uuid) => uuid.str128.toLowerCase())
        .toList(growable: false);
    return DiscoveredWearable(
      id: result.device.remoteId.str,
      name: name,
      type: classify(name: name, serviceUuids: services),
      rssi: result.rssi,
      serviceUuids: services,
    );
  }

  static WearableDeviceType classify({
    required String name,
    required List<String> serviceUuids,
  }) {
    final lower = name.toLowerCase();
    final upper = name.toUpperCase();
    bool has(String uuid) =>
        serviceUuids.any((value) => value.toLowerCase() == uuid.toLowerCase());

    if (lower.contains('bee') || has(WearableDeviceUuids.beeService)) {
      return WearableDeviceType.bee;
    }
    if (upper.startsWith('PLAUD') || has(WearableDeviceUuids.plaudService)) {
      return WearableDeviceType.plaud;
    }
    if (lower == 'compass' ||
        lower == 'fieldy' ||
        has(WearableDeviceUuids.fieldyService)) {
      return WearableDeviceType.fieldy;
    }
    if (lower.startsWith('friend_') || has(WearableDeviceUuids.friendService)) {
      return WearableDeviceType.friendPendant;
    }
    if (lower.contains('limitless') ||
        lower.contains('pendant') ||
        has(WearableDeviceUuids.limitlessService)) {
      return WearableDeviceType.limitless;
    }
    if (lower.contains('openglass') ||
        lower.contains('omiglass') ||
        lower.contains('glass')) {
      return WearableDeviceType.omiGlass;
    }
    if (has(WearableDeviceUuids.omiService) || lower.contains('omi')) {
      return WearableDeviceType.omi;
    }
    return WearableDeviceType.custom;
  }
}
