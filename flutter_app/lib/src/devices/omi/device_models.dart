/// Device types supported by the Omi connector port.
enum WearableDeviceType { omi, omiGlass, heyPocket, custom }

enum WearableAudioCodec { pcm8, pcm16, opus, opusFs320, aac, lc3, mp3, unknown }

class WearableDeviceUuids {
  static const omiService = '19b10000-e8f2-537e-4f6c-d104768a1214';
  static const omiAudioData = '19b10001-e8f2-537e-4f6c-d104768a1214';
  static const omiAudioCodec = '19b10002-e8f2-537e-4f6c-d104768a1214';
  // On-board storage (SD ring buffer / multi-file), fw 3.0.20+.
  static const omiStorageService = '30295780-4301-eabd-2904-2849adfeae43';
  static const omiStorageData = '30295781-4301-eabd-2904-2849adfeae43';
  static const omiStorageControl = '30295782-4301-eabd-2904-2849adfeae43';
  static const buttonService = '23ba7924-0000-1000-7450-346eac492e92';
  static const buttonTrigger = '23ba7925-0000-1000-7450-346eac492e92';
  static const timeSyncService = '19b10030-e8f2-537e-4f6c-d104768a1214';
  static const timeSyncWrite = '19b10031-e8f2-537e-4f6c-d104768a1214';
  static const batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';
  // HeyPocket (also labelled PKT01 / Pocket). Control frames are ASCII text and
  // audio is an MP3 stream delivered over the audio-notify characteristic.
  static const heyPocketService = '001120a0-2233-4455-6677-889912345678';
  static const heyPocketControlNotify = '001120a1-2233-4455-6677-889912345678';
  static const heyPocketControlWrite = '001120a2-2233-4455-6677-889912345678';
  static const heyPocketAudioNotify = '001120a3-2233-4455-6677-889912345678';
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

  /// Advertised-name selectors used only when a platform omits service UUIDs.
  /// The final identity decision is still repeated after discovery, so a broad
  /// native scan callback cannot leak unrelated BLE peripherals into the UI.
  static const List<String> heyPocketNamePrefixes = <String>[
    'HeyPocket',
    'PKT01',
    'PK01',
    'Pocket',
  ];

  static bool hasHeyPocketName(String name) {
    final lower = name.trim().toLowerCase();
    return lower.startsWith('heypocket') ||
        lower.startsWith('pkt01') ||
        lower.startsWith('pk01') ||
        lower == 'pocket';
  }

  static WearableDeviceType classify({
    required String name,
    required List<String> serviceUuids,
  }) {
    final lower = name.toLowerCase();
    bool has(String uuid) =>
        serviceUuids.any((value) => value.toLowerCase() == uuid.toLowerCase());

    if (has(WearableDeviceUuids.heyPocketService) || hasHeyPocketName(name)) {
      return WearableDeviceType.heyPocket;
    }
    if (lower.startsWith('openglass') || lower.startsWith('omiglass')) {
      return WearableDeviceType.omiGlass;
    }
    if (has(WearableDeviceUuids.omiService) || lower.startsWith('omi')) {
      return WearableDeviceType.omi;
    }
    return WearableDeviceType.custom;
  }
}
