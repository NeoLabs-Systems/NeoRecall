import 'dart:async';
import 'dart:typed_data';

import 'package:neorecall/src/devices/appliance/appliance_codec.dart';
import 'package:neorecall/src/devices/appliance/appliance_controller.dart';
import 'package:neorecall/src/devices/appliance/appliance_link.dart';
import 'package:neorecall/src/devices/appliance/appliance_protocol.dart';
import 'package:neorecall/src/devices/ble/gatt_transport.dart';

/// A Bluetooth stack a test can steer: what it finds, what it answers, and what
/// it refuses.
class FakeGattTransport implements GattTransport {
  final StreamController<GattPeripheral> _discoveries =
      StreamController<GattPeripheral>.broadcast();
  final Map<String, StreamController<Uint8List>> _notifications =
      <String, StreamController<Uint8List>>{};
  final StreamController<bool> _connections = StreamController<bool>.broadcast();

  final List<Uint8List> commandWrites = <Uint8List>[];

  /// A scripted device: called with each decoded command so a test can answer
  /// the way the appliance would (a listing, audio pages, a status).
  void Function(Map<String, Object?> command)? onCommandWrite;
  final List<Uint8List> provisionWrites = <Uint8List>[];
  final List<String> connected = <String>[];
  final List<String> paired = <String>[];

  Uint8List statusOnRead = cborEncode(<String, Object?>{'v': 1, 'st': 'idle'});
  Object? writeFailure;
  bool scanning = false;

  StreamController<Uint8List> _channel(String uuid) =>
      _notifications.putIfAbsent(uuid, () => StreamController<Uint8List>.broadcast());

  void advertise(GattPeripheral peripheral) => _discoveries.add(peripheral);

  void pushStatus(Map<String, Object?> payload) =>
      _channel(ApplianceProtocol.statusUuid).add(cborEncode(payload));

  void pushDiscovery(Map<String, Object?> payload) =>
      _channel(ApplianceProtocol.discoveryUuid).add(cborEncode(payload));

  void dropConnection() => _connections.add(false);

  /// Push bytes that are not a valid status, to prove the link survives them.
  void pushRawStatus(Uint8List payload) =>
      _channel(ApplianceProtocol.statusUuid).add(payload);

  @override
  Stream<GattPeripheral> get discoveries => _discoveries.stream;

  @override
  Stream<bool> connectionChanges(String deviceId) => _connections.stream;

  @override
  Future<GattAvailability> availability() async => GattAvailability.ready;

  @override
  Future<void> requestAccess() async {}

  @override
  Future<void> startScan(GattScanSpec spec, {Duration timeout = const Duration(seconds: 12)}) async {
    scanning = true;
  }

  @override
  Future<void> stopScan() async {
    scanning = false;
  }

  Object? connectError;
  bool? lastAutoReconnect;

  @override
  Future<void> connect(String deviceId, {bool autoReconnect = true, Duration timeout = const Duration(seconds: 30)}) async {
    lastAutoReconnect = autoReconnect;
    final Object? failure = connectError;
    if (failure != null) throw failure;
    connected.add(deviceId);
  }

  @override
  Future<int?> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<void> pair(String deviceId) async {
    paired.add(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    connected.remove(deviceId);
  }

  @override
  Future<List<String>> discoverServices(String deviceId) async =>
      <String>[ApplianceProtocol.serviceUuid];

  @override
  Future<List<GattDiscoveredCharacteristic>> discoverCharacteristics(String deviceId) async =>
      const <GattDiscoveredCharacteristic>[];

  @override
  Future<Uint8List> read(String deviceId, String serviceUuid, String characteristicUuid) async =>
      statusOnRead;

  @override
  Future<void> write(String deviceId, String serviceUuid, String characteristicUuid, Uint8List value, {bool withoutResponse = false}) async {
    final failure = writeFailure;
    if (failure != null) throw failure;
    if (characteristicUuid == ApplianceProtocol.commandUuid) {
      commandWrites.add(value);
      final void Function(Map<String, Object?>)? script = onCommandWrite;
      if (script != null) {
        // Answer asynchronously, the way a device does: never inside the write.
        scheduleMicrotask(
          () => script(cborDecode(value) as Map<String, Object?>),
        );
      }
    } else if (characteristicUuid == ApplianceProtocol.provisionUuid) {
      provisionWrites.add(value);
    }
  }

  @override
  Future<Stream<Uint8List>> subscribe(String deviceId, String serviceUuid, String characteristicUuid) async =>
      _channel(characteristicUuid).stream;

  @override
  Future<void> unsubscribe(String deviceId, String serviceUuid, String characteristicUuid) async {}

  @override
  Future<void> dispose() async {
    await _discoveries.close();
    await _connections.close();
    for (final controller in _notifications.values) {
      await controller.close();
    }
  }
}

/// A connected appliance with a scripted Bluetooth stack behind it.
class ApplianceRig {
  String timezone = 'Europe/Berlin';
  String? rememberedDevice;

  ApplianceRig() {
    link = ApplianceLink(transport: transport);
    controller = ApplianceController(
      link: link,
      mintApiKey: (String name) async {
        mintedNames.add(name);
        final failure = mintFailure;
        if (failure != null) throw failure;
        return 'nrk_minted_key';
      },
      backendUrl: () => backend,
      timezone: () => timezone,
      rememberedDevice: () => rememberedDevice,
      rememberDevice: (String? id) async => rememberedDevice = id,
    );
  }

  final FakeGattTransport transport = FakeGattTransport();
  final List<String> mintedNames = <String>[];
  late final ApplianceLink link;
  late final ApplianceController controller;
  String backend = 'https://recall.example.com';
  Object? mintFailure;

  Future<void> connect({bool pair = false}) => controller.connectTo(
    const ApplianceCandidate(deviceId: 'desk-1', name: 'NeoRecall Desk'),
    pair: pair,
  );

  Map<String, Object?> lastCommand() =>
      cborDecode(transport.commandWrites.last) as Map<String, Object?>;

  /// Every command of one name this rig has seen, decoded, in order.
  List<Map<String, Object?>> commandsNamed(String name) => transport
      .commandWrites
      .map((Uint8List raw) => cborDecode(raw) as Map<String, Object?>)
      .where((Map<String, Object?> c) => c['c'] == name)
      .toList(growable: false);
}

/// Encode a status payload the way the appliance would.
Uint8List cborEncodeStatus(Map<String, Object?> payload) => cborEncode(payload);

/// A status payload with sensible defaults, so a test only states what it cares
/// about.
Map<String, Object?> applianceStatusPayload([
  Map<String, Object?> overrides = const <String, Object?>{},
]) => <String, Object?>{'v': 1, 'st': 'idle', 'net': true, ...overrides};
