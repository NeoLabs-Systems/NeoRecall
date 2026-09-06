import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/appliance/appliance_link.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';

/// What the setup screen calls a device it has already identified.
///
/// Found on a real phone: a Raspberry Pi that had once run other software was
/// offered as "WirelessAADongle-neo" in the Add-a-Desk list. Android keeps a
/// name and a service list per bonded address and merges them into later scan
/// results, so the cached label wins over the current advertisement. The user
/// sees a stranger's name on the device they are about to pair.
void main() {
  late _FakeTransport transport;
  late ApplianceLink link;

  setUp(() {
    transport = _FakeTransport();
    link = ApplianceLink(transport: transport);
  });

  tearDown(() async {
    await link.dispose();
  });

  Future<ApplianceCandidate> firstCandidate(GattPeripheral peripheral) async {
    final Future<ApplianceCandidate> candidate = link.found.first;
    await link.startScan();
    transport.emit(peripheral);
    return candidate;
  }

  test('a stale cached name is replaced by the product name', () async {
    final ApplianceCandidate candidate = await firstCandidate(
      const GattPeripheral(
        id: 'B8:27:EB:64:A0:5B',
        name: 'WirelessAADongle-neo',
        rssi: -52,
        serviceUuids: <String>[
          '00001108-0000-1000-8000-00805f9b34fb',
          ApplianceProtocol.serviceUuid,
        ],
      ),
    );

    // Its own advertisement carries our service, so its identity is not in
    // doubt — only the label the phone remembered for that address is.
    expect(candidate.name, ApplianceProtocol.advertisedNamePrefix);
  });

  test('a device that names itself keeps the name it broadcasts', () async {
    final ApplianceCandidate candidate = await firstCandidate(
      const GattPeripheral(
        id: 'B8:27:EB:64:A0:5B',
        name: 'NeoRecall Desk (kitchen)',
        rssi: -40,
        serviceUuids: <String>[ApplianceProtocol.serviceUuid],
      ),
    );

    // A renamed appliance still says who it is, and that name is the useful
    // one when somebody owns more than one.
    expect(candidate.name, 'NeoRecall Desk (kitchen)');
  });

  test('an unnamed appliance is still shown as one', () async {
    final ApplianceCandidate candidate = await firstCandidate(
      const GattPeripheral(
        id: 'B8:27:EB:64:A0:5B',
        name: '',
        rssi: -70,
        serviceUuids: <String>[ApplianceProtocol.serviceUuid],
      ),
    );

    expect(candidate.name, ApplianceProtocol.advertisedNamePrefix);
  });

  test('a device that is not ours is not offered at all', () async {
    final List<ApplianceCandidate> seen = <ApplianceCandidate>[];
    final StreamSubscription<ApplianceCandidate> subscription = link.found
        .listen(seen.add);
    await link.startScan();

    transport.emit(
      const GattPeripheral(
        id: 'AA:BB:CC:DD:EE:FF',
        name: 'Somebody Else',
        rssi: -60,
        serviceUuids: <String>['00001108-0000-1000-8000-00805f9b34fb'],
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();

    expect(seen, isEmpty);
  });
}

class _FakeTransport implements GattTransport {
  final StreamController<GattPeripheral> _discoveries =
      StreamController<GattPeripheral>.broadcast();

  void emit(GattPeripheral peripheral) => _discoveries.add(peripheral);

  @override
  Stream<GattPeripheral> get discoveries => _discoveries.stream;

  @override
  Future<void> startScan(GattScanSpec spec, {Duration? timeout}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<GattAvailability> availability() async => GattAvailability.ready;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
