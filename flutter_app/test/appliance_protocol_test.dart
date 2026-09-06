import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/appliance/appliance_codec.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';

Uint8List statusPayload(Map<String, Object?> overrides) => cborEncode(<String, Object?>{
  'v': 1,
  'st': 'idle',
  'el': 0,
  'pc': 0,
  'na': 0,
  'out': 'speaker',
  'mic': 'built_in',
  'hc': false,
  'hn': '',
  'hb': null,
  'net': true,
  'auth': false,
  'rev': false,
  'err': '',
  'fw': '0.1.0',
  ...overrides,
});

void main() {
  group('the CBOR the appliance speaks', () {
    test('round-trips every shape the contract uses', () {
      final value = <String, Object?>{
        'text': 'Sony WH-1000XM5',
        'small': 7,
        'medium': 4242,
        'large': 300000,
        'negative': -12,
        'yes': true,
        'no': false,
        'nothing': null,
        'list': <Object?>[1, 'two', false],
        'nested': <String, Object?>{'a': 1},
      };

      expect(cborDecode(cborEncode(value)), value);
    });

    test('decodes an empty map and an empty string', () {
      expect(cborDecode(cborEncode(<String, Object?>{})), <String, Object?>{});
      expect(cborDecode(cborEncode('')), '');
    });

    test('handles text that is not ASCII', () {
      const text = 'Kein Netzwerk — 12 Aufnahmen warten … 🎧';
      expect(cborDecode(cborEncode(text)), text);
    });

    test('refuses a truncated message rather than guessing', () {
      final full = cborEncode(<String, Object?>{'name': 'headphones'});
      final cut = Uint8List.sublistView(full, 0, full.length - 3);

      expect(() => cborDecode(cut), throwsA(isA<CborFormatException>()));
    });

    test('refuses trailing rubbish after a complete value', () {
      final builder = BytesBuilder()
        ..add(cborEncode(<String, Object?>{'a': 1}))
        ..addByte(0x01);

      expect(() => cborDecode(builder.takeBytes()), throwsA(isA<CborFormatException>()));
    });

    test('refuses values of unknown length', () {
      // Indefinite-length encoding: nothing the appliance emits, so accepting it
      // would only widen what this channel has to defend against.
      expect(
        () => cborDecode(Uint8List.fromList(<int>[0x9f, 0x01, 0xff])),
        throwsA(isA<CborFormatException>()),
      );
    });

    test('refuses map keys that are not text', () {
      expect(
        () => cborDecode(Uint8List.fromList(<int>[0xa1, 0x01, 0x01])),
        throwsA(isA<CborFormatException>()),
      );
    });
  });

  group('a status update', () {
    test('decodes a device that is quietly ready', () {
      final status = ApplianceStatus.decode(statusPayload(const <String, Object?>{}));

      expect(status.state, ApplianceState.idle);
      expect(status.isRecording, isFalse);
      expect(status.needsSetup, isFalse);
      expect(status.summary, 'Ready');
      expect(status.firmware, '0.1.0');
    });

    test('decodes a device that is recording, with its elapsed time', () {
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'st': 'recording', 'el': 843000}),
      );

      expect(status.isRecording, isTrue);
      expect(status.recordingElapsed, const Duration(minutes: 14, seconds: 3));
      expect(status.summary, 'Recording · 14:03');
    });

    test('decodes headphones with their battery', () {
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{
          'out': 'headphones',
          'hc': true,
          'hn': 'Sony WH-1000XM5',
          'hb': 72,
          'mic': 'headset',
        }),
      );

      expect(status.output, ApplianceOutput.headphones);
      expect(status.outputName, 'Sony WH-1000XM5');
      expect(status.headsetConnected, isTrue);
      expect(status.headsetBattery, 72);
      expect(status.micSource, ApplianceMicSource.headset);
      expect(status.summary, 'Ready · Sony WH-1000XM5');
    });

    test('says a queue is waiting when there is no network', () {
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'pc': 12, 'net': false}),
      );

      expect(status.isSyncing, isFalse);
      expect(status.summary, '12 recordings waiting to be sent');
    });

    test('says it is sending once the network is back', () {
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'pc': 1, 'net': true}),
      );

      expect(status.isSyncing, isTrue);
      expect(status.summary, 'Sending 1 recording');
    });

    test('treats a lost account as needing setup again', () {
      final revoked = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'rev': true}),
      );
      final expired = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'auth': true}),
      );

      expect(revoked.needsSetup, isTrue);
      expect(expired.needsSetup, isTrue);
      expect(revoked.summary, 'Not set up yet');
    });

    test('carries the outcome of the last command', () {
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{
          'res': <String, Object?>{'c': 'setup', 'ok': false, 'm': 'That password was not accepted.'},
        }),
      );

      expect(status.lastResult, isNotNull);
      expect(status.lastResult!.ok, isFalse);
      expect(status.lastResult!.message, 'That password was not accepted.');
    });

    test('survives a field it has never seen before', () {
      // A newer appliance talking to an older app must not brick the screen.
      final status = ApplianceStatus.decode(
        statusPayload(const <String, Object?>{'somethingNew': 'from the future'}),
      );

      expect(status.state, ApplianceState.idle);
    });

    test('refuses a payload that is not a status at all', () {
      expect(
        () => ApplianceStatus.decode(cborEncode(<Object?>['nope'])),
        throwsA(isA<CborFormatException>()),
      );
    });
  });

  group('scan results', () {
    test('decode Wi-Fi networks', () {
      final discovery = ApplianceDiscovery.decode(
        cborEncode(<String, Object?>{
          'v': 1,
          'k': 'wifi',
          'e': <Object?>[
            <String, Object?>{'ssid': 'Kitchen', 'signal': 71, 'secured': true},
          ],
        }),
      );

      expect(discovery.isWifi, isTrue);
      final network = WifiNetwork.from(discovery.entries.first);
      expect(network.ssid, 'Kitchen');
      expect(network.signal, 71);
      expect(network.secured, isTrue);
    });

    test('decode headphones', () {
      final discovery = ApplianceDiscovery.decode(
        cborEncode(<String, Object?>{
          'v': 1,
          'k': 'bluetooth',
          'e': <Object?>[
            <String, Object?>{
              'address': 'AA:BB:CC:DD:EE:FF',
              'name': 'Sony WH-1000XM5',
              'paired': true,
              'connected': false,
              'battery': 72,
            },
          ],
        }),
      );

      expect(discovery.isBluetooth, isTrue);
      final headphone = ApplianceHeadphone.from(discovery.entries.first);
      expect(headphone.name, 'Sony WH-1000XM5');
      expect(headphone.paired, isTrue);
      expect(headphone.connected, isFalse);
      expect(headphone.battery, 72);
    });

    test('an empty scan is an empty list, not an error', () {
      final discovery = ApplianceDiscovery.decode(
        cborEncode(<String, Object?>{'v': 1, 'k': 'wifi', 'e': <Object?>[]}),
      );

      expect(discovery.entries, isEmpty);
    });
  });

  group('commands', () {
    test('encode to exactly what the appliance decodes', () {
      expect(cborDecode(ApplianceCommand.start.encode()), <String, Object?>{'c': 'start'});
      expect(cborDecode(ApplianceCommand.stop.encode()), <String, Object?>{'c': 'stop'});
      expect(
        cborDecode(ApplianceCommand.useOutput(ApplianceOutput.headphones).encode()),
        <String, Object?>{'c': 'set_output', 't': 'headphones'},
      );
      expect(
        cborDecode(ApplianceCommand.useHeadsetMicrophone(true).encode()),
        <String, Object?>{'c': 'set_headset_mic', 'on': true},
      );
      expect(
        cborDecode(ApplianceCommand.connectHeadphones('AA:BB:CC:DD:EE:FF').encode()),
        <String, Object?>{'c': 'bt_connect', 'a': 'AA:BB:CC:DD:EE:FF'},
      );
      expect(
        cborDecode(ApplianceCommand.renameTo('Desk in the study').encode()),
        <String, Object?>{'c': 'rename', 'n': 'Desk in the study'},
      );
    });
  });

  group('setup', () {
    test('sends everything the appliance needs and nothing it does not', () {
      const provisioning = ApplianceProvisioning(
        backendUrl: 'https://recall.example.com',
        apiKey: 'nrk_ab12cd_secret',
        wifiSsid: 'Kitchen',
        wifiPassword: 'hunter2hunter2',
        timezone: 'Europe/Berlin',
        deviceName: 'Desk in the study',
      );

      expect(cborDecode(provisioning.encode()), <String, Object?>{
        'url': 'https://recall.example.com',
        'key': 'nrk_ab12cd_secret',
        'tls': true,
        'ssid': 'Kitchen',
        'psk': 'hunter2hunter2',
        'tz': 'Europe/Berlin',
        'n': 'Desk in the study',
      });
    });

    test('omits Wi-Fi entirely for a device that already has a network', () {
      const provisioning = ApplianceProvisioning(
        backendUrl: 'https://recall.example.com',
        apiKey: 'nrk_key',
      );

      final decoded = cborDecode(provisioning.encode()) as Map<String, Object?>;
      expect(decoded.containsKey('ssid'), isFalse);
      expect(decoded.containsKey('psk'), isFalse);
    });
  });

  group('elapsed time', () {
    test('reads as minutes and seconds until it needs hours', () {
      expect(formatElapsed(const Duration(seconds: 9)), '00:09');
      expect(formatElapsed(const Duration(minutes: 4, seconds: 12)), '04:12');
      expect(formatElapsed(const Duration(hours: 1, minutes: 23, seconds: 45)), '1:23:45');
    });
  });
}
