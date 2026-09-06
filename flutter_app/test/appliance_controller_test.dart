import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/appliance/appliance_codec.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';

import 'support/appliance_test_support.dart';

typedef _Rig = ApplianceRig;

Map<String, Object?> status(Map<String, Object?> overrides) =>
    applianceStatusPayload(overrides);

void main() {
  late _Rig rig;

  setUp(() => rig = _Rig());
  tearDown(() => rig.controller.dispose());

  group('finding an appliance', () {
    test('reports one that advertises our service', () async {
      final scan = rig.controller.scanForAppliances(
        timeout: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();
      rig.transport.advertise(
        const GattPeripheral(
          id: 'desk-1',
          name: 'NeoRecall Desk',
          serviceUuids: <String>[ApplianceProtocol.serviceUuid],
        ),
      );
      await scan;

      expect(rig.controller.candidates.single.deviceId, 'desk-1');
    });

    test('ignores everything else in the room', () async {
      final scan = rig.controller.scanForAppliances(
        timeout: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();
      rig.transport.advertise(
        const GattPeripheral(id: 'watch', name: 'Someone Watch', serviceUuids: <String>[]),
      );
      await scan;

      expect(rig.controller.candidates, isEmpty);
    });

    test('recognises one by name when the platform hides service uuids', () async {
      // iOS and macOS routinely omit service uuids from an advertisement.
      final scan = rig.controller.scanForAppliances(
        timeout: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();
      rig.transport.advertise(
        const GattPeripheral(id: 'desk-2', name: 'NeoRecall Desk', serviceUuids: <String>[]),
      );
      await scan;

      expect(rig.controller.candidates.single.deviceId, 'desk-2');
    });

    test('does not list the same device twice', () async {
      final scan = rig.controller.scanForAppliances(
        timeout: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();
      for (var i = 0; i < 3; i++) {
        rig.transport.advertise(
          const GattPeripheral(
            id: 'desk-1',
            name: 'NeoRecall Desk',
            serviceUuids: <String>[ApplianceProtocol.serviceUuid],
          ),
        );
      }
      await scan;

      expect(rig.controller.candidates, hasLength(1));
    });
  });

  group('connecting', () {
    test('pairs only when the setup flow asks it to', () async {
      await rig.connect();
      expect(rig.transport.paired, isEmpty);

      await rig.connect(pair: true);
      expect(rig.transport.paired, <String>['desk-1']);
    });

    test('reads the current state immediately instead of waiting', () async {
      rig.transport.statusOnRead = cborEncode(status(<String, Object?>{'st': 'recording', 'el': 5000}));

      await rig.connect();

      expect(rig.controller.status!.isRecording, isTrue);
      expect(rig.controller.isConnected, isTrue);
    });
  });

  group('live status', () {
    test('follows the appliance as it changes', () async {
      await rig.connect();

      rig.transport.pushStatus(status(<String, Object?>{'st': 'recording', 'el': 61000}));
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.status!.isRecording, isTrue);
      expect(rig.controller.status!.recordingElapsed, const Duration(minutes: 1, seconds: 1));
    });

    test('keeps the last picture when the phone walks out of range', () async {
      await rig.connect();
      rig.transport.pushStatus(status(<String, Object?>{'st': 'recording', 'el': 61000}));
      await Future<void>.delayed(Duration.zero);

      rig.transport.dropConnection();
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.isConnected, isFalse);
      // The appliance did not stop recording just because the phone left.
      expect(rig.controller.status!.isRecording, isTrue);
    });

    test('an unreadable update does not blank the screen', () async {
      await rig.connect();
      rig.transport.pushStatus(status(<String, Object?>{'st': 'recording'}));
      await Future<void>.delayed(Duration.zero);

      rig.transport.pushRawStatus(Uint8List.fromList(<int>[0xff, 0xff]));
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.status!.isRecording, isTrue);
      expect(rig.controller.isConnected, isTrue);
    });

    test('surfaces the appliance’s own words about the last command', () async {
      await rig.connect();

      rig.transport.pushStatus(status(<String, Object?>{
        'res': <String, Object?>{
          'c': 'set_headset_mic',
          'ok': false,
          'm': 'These headphones do not offer a microphone the appliance can use.',
        },
      }));
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.messageIsError, isTrue);
      expect(
        rig.controller.message,
        'These headphones do not offer a microphone the appliance can use.',
      );
    });
  });

  group('commands', () {
    test('start and stop reach the appliance', () async {
      await rig.connect();

      await rig.controller.startRecording();
      expect(rig.lastCommand(), <String, Object?>{'c': 'start'});
      // The app never flips its own state: the appliance says when it started,
      // and until it does the screen keeps showing what is actually true.
      expect(rig.controller.status!.isRecording, isFalse);

      await rig.controller.stopRecording();
      expect(rig.lastCommand(), <String, Object?>{'c': 'stop'});
    });

    test('headphone actions carry the address', () async {
      await rig.connect();

      await rig.controller.connectHeadphones('AA:BB:CC:DD:EE:FF');

      expect(rig.lastCommand(), <String, Object?>{'c': 'bt_connect', 'a': 'AA:BB:CC:DD:EE:FF'});
    });

    test('a failed write becomes a sentence, never an exception on screen', () async {
      await rig.connect();
      rig.transport.writeFailure = Exception('GATT write failed: 0x0e');

      final ok = await rig.controller.startRecording();

      expect(ok, isFalse);
      expect(rig.controller.messageIsError, isTrue);
      expect(rig.controller.message, 'Could not start recording.');
    });

    test('a command sent before connecting fails quietly', () async {
      final ok = await rig.controller.startRecording();

      expect(ok, isFalse);
      expect(rig.controller.message, 'Could not start recording.');
    });
  });

  group('scanning from the appliance', () {
    test('networks arrive strongest first, as the appliance ordered them', () async {
      await rig.connect();
      await rig.controller.lookForNetworks();
      expect(rig.controller.isLookingForNetworks, isTrue);

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'wifi',
        'e': <Object?>[
          <String, Object?>{'ssid': 'Kitchen', 'signal': 71, 'secured': true},
          <String, Object?>{'ssid': 'Shed', 'signal': 34, 'secured': false},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.isLookingForNetworks, isFalse);
      expect(rig.controller.networks.map((WifiNetwork n) => n.ssid), <String>['Kitchen', 'Shed']);
    });

    test('headphones arrive with what is known about them', () async {
      await rig.connect();
      await rig.controller.lookForHeadphones();

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'bluetooth',
        'e': <Object?>[
          <String, Object?>{'address': 'AA:BB', 'name': 'Sony WH-1000XM5', 'paired': true, 'connected': false, 'battery': 72},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.headphones.single.name, 'Sony WH-1000XM5');
      expect(rig.controller.headphones.single.battery, 72);
    });
  });

  group('results that do not fit one notification', () {
    // Seven self-test verdicts encode to about 650 bytes against a 244-byte
    // packet. The appliance used to send them as one notification; BlueZ
    // delivered a fragment, the app could not decode it, and the sound check
    // appeared to do nothing whatsoever.
    test('a paged self-test is reassembled before anyone sees it', () async {
      await rig.connect();
      await rig.controller.runSelfTest();
      expect(rig.controller.isChecking, isTrue);

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'selftest',
        'p': 0,
        'n': 2,
        'e': <Object?>[
          <String, Object?>{'name': 'codec driver', 'ok': true, 'detail': 'clocked'},
          <String, Object?>{'name': 'usb gadget', 'ok': true, 'detail': 'bound'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      // Nothing is shown until the last page lands: a partial list would read
      // as a complete answer with four checks silently missing.
      expect(rig.controller.checks, isEmpty);
      expect(rig.controller.isChecking, isTrue);

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'selftest',
        'p': 1,
        'n': 2,
        'e': <Object?>[
          <String, Object?>{'name': 'speakers', 'ok': false, 'detail': 'nothing came back'},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.isChecking, isFalse);
      expect(
        rig.controller.checks.map((ApplianceCheck c) => c.name),
        <String>['codec driver', 'usb gadget', 'speakers'],
      );
      expect(rig.controller.checks.last.ok, isFalse);
    });

    test('an appliance that sends no page numbers is still understood', () async {
      // One that has not been updated yet. A single unnumbered payload is one
      // complete page by definition.
      await rig.connect();
      await rig.controller.lookForNetworks();

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'wifi',
        'e': <Object?>[
          <String, Object?>{'ssid': 'Kitchen', 'signal': 71, 'secured': true},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.networks.single.ssid, 'Kitchen');
    });

    test('a dropped page abandons the result rather than shortening it', () async {
      await rig.connect();
      await rig.controller.lookForHeadphones();

      // Page 0 arrives; page 1 is lost; page 2 turns up.
      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'bluetooth',
        'p': 0,
        'n': 3,
        'e': <Object?>[
          <String, Object?>{'address': 'AA:BB', 'name': 'First', 'paired': true, 'connected': false},
        ],
      });
      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'bluetooth',
        'p': 2,
        'n': 3,
        'e': <Object?>[
          <String, Object?>{'address': 'EE:FF', 'name': 'Third', 'paired': true, 'connected': false},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      // Two of three headphones presented as the whole room would be worse than
      // a scan the owner can simply run again.
      expect(rig.controller.headphones, isEmpty);
    });

    test('a second scan replaces the first rather than merging into it', () async {
      await rig.connect();
      await rig.controller.lookForHeadphones();

      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'bluetooth',
        'p': 0,
        'n': 2,
        'e': <Object?>[
          <String, Object?>{'address': 'AA:BB', 'name': 'Stale', 'paired': true, 'connected': false},
        ],
      });
      // A fresh scan starts before the first finished.
      rig.transport.pushDiscovery(<String, Object?>{
        'v': 1,
        'k': 'bluetooth',
        'p': 0,
        'n': 1,
        'e': <Object?>[
          <String, Object?>{'address': 'CC:DD', 'name': 'Fresh', 'paired': true, 'connected': false},
        ],
      });
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.headphones.single.name, 'Fresh');
    });
  });

  group('setup', () {
    test('mints a key and hands the appliance everything at once', () async {
      await rig.connect(pair: true);

      final ok = await rig.controller.completeSetup(
        wifiSsid: 'Kitchen',
        wifiPassword: 'hunter2hunter2',
        deviceName: 'Desk in the study',
      );

      expect(ok, isTrue);
      expect(rig.mintedNames, <String>['Desk in the study']);
      final sent = cborDecode(rig.transport.provisionWrites.single) as Map<String, Object?>;
      expect(sent['url'], 'https://recall.example.com');
      expect(sent['key'], 'nrk_minted_key');
      expect(sent['ssid'], 'Kitchen');
      expect(sent['psk'], 'hunter2hunter2');
      expect(sent['n'], 'Desk in the study');
    });

    test('sends the account timezone, not an abbreviation', () async {
      // Found against a real server: DateTime.timeZoneName yields "CEST", the
      // session endpoint requires an IANA name, and every recording the
      // appliance made stayed on the device with nothing explaining why.
      rig.timezone = 'Europe/Berlin';
      await rig.connect(pair: true);

      await rig.controller.completeSetup(wifiSsid: 'Kitchen', wifiPassword: 'hunter2hunter2');

      final sent = cborDecode(rig.transport.provisionWrites.single) as Map<String, Object?>;
      expect(sent['tz'], 'Europe/Berlin');
    });

    test('the device is remembered and reached again on the next launch', () async {
      // Reported after the first real setup: closing the app and reopening it
      // showed the Desk as "Out of range". Nothing was wrong with the device —
      // nothing had asked it anything, because nothing remembered it.
      await rig.connect(pair: true);
      expect(rig.rememberedDevice, isNotNull);

      final ApplianceRig relaunched = ApplianceRig()
        ..rememberedDevice = rig.rememberedDevice;
      expect(relaunched.controller.isConnected, isFalse);

      await relaunched.controller.reconnectToRemembered();

      expect(relaunched.controller.isConnected, isTrue);
    });

    test('a removed device is not reached for again', () async {
      await rig.connect(pair: true);
      expect(rig.rememberedDevice, isNotNull);

      await rig.controller.removeFromAccount();

      expect(rig.rememberedDevice, isNull);
    });

    test('connecting is direct, not queued in the background', () async {
      // Android's autoConnect waits for the device to come to it and says
      // nothing while it waits. Standing in front of a device that was
      // advertising the whole time, the app showed "Connecting…" for thirty
      // seconds and then a timeout.
      await rig.connect(pair: true);

      expect(rig.transport.lastAutoReconnect, isFalse);
    });

    test('a failure never shows the owner an exception', () async {
      // Seen on the device page: "TimeoutException after 0:00:30.000000:
      // Future not completed". The filter that was supposed to catch that only
      // looked for text starting with "Exception".
      rig.transport.connectError =
          TimeoutException('Future not completed', const Duration(seconds: 30));

      await rig.connect();

      expect(rig.controller.message, 'Could not connect to that device.');
      expect(rig.controller.message, isNot(contains('Exception')));
    });

    test('a drop the owner did not ask for is retried', () async {
      // Walking through a doorway used to cost the connection until the next
      // manual visit to the device page. The link now heals itself: a short
      // first retry for momentary drops, widening after that.
      await rig.connect(pair: true);
      rig.transport.dropConnection();

      // Attempt 1 fires after ~3 s.
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(rig.transport.connected.length, greaterThan(1));
    });

    test('an explicit disconnect stays disconnected', () async {
      await rig.connect(pair: true);

      await rig.controller.disconnect();
      rig.transport.dropConnection();
      await Future<void>.delayed(const Duration(seconds: 4));

      // Nothing reconnects behind the owner's back.
      expect(rig.transport.connected, isEmpty);
    });

    test('refuses to set up a device when the app is not signed in', () async {
      await rig.connect(pair: true);
      rig.backend = '';

      final ok = await rig.controller.completeSetup(wifiSsid: 'Kitchen');

      expect(ok, isFalse);
      expect(rig.controller.message, contains('not signed in'));
      expect(rig.transport.provisionWrites, isEmpty);
    });

    test('a wrong Wi-Fi password comes back in the appliance’s own words', () async {
      await rig.connect(pair: true);
      await rig.controller.completeSetup(wifiSsid: 'Kitchen', wifiPassword: 'wrong');

      rig.transport.pushStatus(status(<String, Object?>{
        'st': 'unconfigured',
        'res': <String, Object?>{'c': 'setup', 'ok': false, 'm': 'That password was not accepted.'},
      }));
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.setupSucceeded, isFalse);
      expect(rig.controller.setupFailure, 'That password was not accepted.');
    });

    test('success is the appliance confirming it, not the app assuming it', () async {
      await rig.connect(pair: true);
      await rig.controller.completeSetup(wifiSsid: 'Kitchen', wifiPassword: 'right');

      // Nothing has come back yet: the app must not claim success.
      expect(rig.controller.setupSucceeded, isFalse);

      rig.transport.pushStatus(status(<String, Object?>{
        'st': 'idle',
        'did': '44444444-4444-4444-8444-444444444444',
        'res': <String, Object?>{'c': 'setup', 'ok': true, 'm': ''},
      }));
      await Future<void>.delayed(Duration.zero);

      expect(rig.controller.setupSucceeded, isTrue);
      expect(rig.controller.boundDeviceId, '44444444-4444-4444-8444-444444444444');
      expect(rig.controller.isBoundTo('44444444-4444-4444-8444-444444444444'), isTrue);
    });

    test('no key is created when there is no server to create it on', () async {
      await rig.connect(pair: true);
      rig.backend = '';

      await rig.controller.completeSetup();

      expect(rig.mintedNames, isEmpty);
    });
  });
}
