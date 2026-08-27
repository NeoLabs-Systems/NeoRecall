import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/appliance/appliance_codec.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';

/// Bytes produced by the appliance itself.
///
/// The same array is pinned on the device side in
/// `hardware/neorecall-desk/tests/test_wire_compatibility.py`, which asserts its
/// encoder still produces exactly these bytes. Two independent CBOR
/// implementations agreeing in the abstract is not the same as them agreeing on
/// the wire, and the failure mode — a device that pairs and then shows nothing —
/// would be miserable to diagnose from a bug report.
///
/// If the payload legitimately changes, update both files in the same commit.
final Uint8List realStatusFromTheDevice = Uint8List.fromList(<int>[
  177, 97, 118, 1, 98, 115, 116, 105, 114, 101, 99, 111, 114, 100, 105, 110,
  103, 98, 101, 108, 26, 0, 12, 220, 248, 98, 112, 99, 12, 98, 110, 97,
  1, 99, 111, 117, 116, 106, 104, 101, 97, 100, 112, 104, 111, 110, 101, 115,
  99, 109, 105, 99, 103, 104, 101, 97, 100, 115, 101, 116, 98, 104, 99, 245,
  98, 104, 110, 111, 83, 111, 110, 121, 32, 87, 72, 45, 49, 48, 48, 48,
  88, 77, 53, 98, 104, 98, 24, 72, 99, 110, 101, 116, 244, 100, 97, 117,
  116, 104, 244, 99, 114, 101, 118, 244, 99, 101, 114, 114, 96, 98, 102, 119,
  101, 48, 46, 49, 46, 48, 99, 100, 105, 100, 120, 36, 52, 52, 52, 52,
  52, 52, 52, 52, 45, 52, 52, 52, 52, 45, 52, 52, 52, 52, 45, 56,
  52, 52, 52, 45, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52,
  99, 114, 101, 115, 163, 97, 99, 111, 115, 101, 116, 95, 104, 101, 97, 100,
  115, 101, 116, 95, 109, 105, 99, 98, 111, 107, 245, 97, 109, 120, 45, 83,
  111, 117, 110, 100, 32, 113, 117, 97, 108, 105, 116, 121, 32, 100, 114, 111,
  112, 115, 32, 97, 32, 108, 105, 116, 116, 108, 101, 32, 119, 104, 105, 108,
  101, 32, 114, 101, 99, 111, 114, 100, 105, 110, 103, 46,
]);

final Uint8List realDiscoveryFromTheDevice = Uint8List.fromList(<int>[
  163, 97, 118, 1, 97, 107, 105, 98, 108, 117, 101, 116, 111, 111, 116, 104, 97, 101, 129,
  165, 103, 97, 100, 100, 114, 101, 115, 115, 113, 65, 65, 58, 66, 66, 58, 67, 67, 58, 68,
  68, 58, 69, 69, 58, 70, 70, 100, 110, 97, 109, 101, 111, 83, 111, 110, 121, 32, 87, 72,
  45, 49, 48, 48, 48, 88, 77, 53, 102, 112, 97, 105, 114, 101, 100, 245, 105, 99, 111, 110,
  110, 101, 99, 116, 101, 100, 245, 103, 98, 97, 116, 116, 101, 114, 121, 24, 72,
]);

void main() {
  test('the app reads a status the appliance actually produced', () {
    final status = ApplianceStatus.decode(realStatusFromTheDevice);

    expect(status.isRecording, isTrue);
    expect(status.recordingElapsed, const Duration(milliseconds: 843000));
    expect(status.pendingRecordings, 12);
    expect(status.needsAttention, 1);
    expect(status.output, ApplianceOutput.headphones);
    // Derived, not transmitted: with headphones selected the output is the
    // headset, whose name is already in the payload.
    expect(status.outputName, 'Sony WH-1000XM5');
    expect(status.deviceId, '44444444-4444-4444-8444-444444444444');
    expect(status.micSource, ApplianceMicSource.headset);
    expect(status.headsetConnected, isTrue);
    expect(status.headsetBattery, 72);
    expect(status.networkOnline, isFalse);
    expect(status.firmware, '0.1.0');
    expect(status.lastResult!.command, 'set_headset_mic');
    // The headset name has to survive the packet budget: it is read far more
    // often than an update state, and the shrinker once sacrificed it when two
    // new fields were added unconditionally.
    expect(status.headsetName, 'Sony WH-1000XM5');
    expect(status.updateState, 'idle');
    expect(status.autoUpdate, isTrue);
    expect(status.isUpdating, isFalse);
    expect(status.lastResult!.ok, isTrue);
    // The direct answer to what the user just did survives intact; the ambient
    // error was the field the appliance trimmed to fit one packet, because its
    // substance is already carried by the counters and flags.
    expect(status.lastResult!.message, 'Sound quality drops a little while recording.');
    expect(status.error, isEmpty);
    expect(status.pendingRecordings, 12);
    expect(status.networkOnline, isFalse);
  });

  test('a real status update fits in one Bluetooth packet', () {
    expect(realStatusFromTheDevice.length, lessThanOrEqualTo(244));
  });

  test('the app reads a headphone scan the appliance actually produced', () {
    final discovery = ApplianceDiscovery.decode(realDiscoveryFromTheDevice);

    expect(discovery.isBluetooth, isTrue);
    final headphone = ApplianceHeadphone.from(discovery.entries.single);
    expect(headphone.address, 'AA:BB:CC:DD:EE:FF');
    expect(headphone.name, 'Sony WH-1000XM5');
    expect(headphone.paired, isTrue);
    expect(headphone.connected, isTrue);
    expect(headphone.battery, 72);
  });

  test('what the app sends is what the appliance parses', () {
    // Mirrors the assertions in test_protocol.py, from the other side.
    expect(
      cborDecode(ApplianceCommand.useHeadsetMicrophone(false).encode()),
      <String, Object?>{'c': 'set_headset_mic', 'on': false},
    );
    expect(
      cborDecode(
        const ApplianceProvisioning(
          backendUrl: 'https://recall.example.com',
          apiKey: 'nrk_ab12cd_secret',
          wifiSsid: 'Kitchen',
          wifiPassword: 'hunter2hunter2',
        ).encode(),
      ),
      <String, Object?>{
        'url': 'https://recall.example.com',
        'key': 'nrk_ab12cd_secret',
        'tls': true,
        'ssid': 'Kitchen',
        'psk': 'hunter2hunter2',
      },
    );
  });
}
