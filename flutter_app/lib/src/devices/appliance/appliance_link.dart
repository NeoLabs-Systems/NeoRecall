import 'dart:async';
import 'dart:typed_data';

import '../../diagnostics/client_diagnostic_log.dart';
import '../ble/gatt_transport.dart';
import 'appliance_codec.dart';
import 'appliance_protocol.dart';

/// The Bluetooth control channel to a NeoRecall Desk appliance.
///
/// This is a *control* link, not an audio transport. The appliance records,
/// buffers and uploads entirely on its own; everything here is a view onto state
/// it owns anyway. Losing this connection mid-meeting costs the live status
/// display and nothing else, which is why reconnecting simply reads the truth
/// again rather than trying to resynchronise anything.
///
/// It deliberately does not implement [AudioDeviceAdapter]. That interface is
/// for devices that stream PCM into the app so `CapturePipeline` can chunk it,
/// and registering an appliance there would offer it as a capture source and
/// start a second, competing recording of the same conversation.
class ApplianceLink {
  ApplianceLink({required GattTransport transport}) : _transport = transport;

  final GattTransport _transport;

  final StreamController<ApplianceStatus> _statuses =
      StreamController<ApplianceStatus>.broadcast();
  final StreamController<ApplianceDiscovery> _discoveries =
      StreamController<ApplianceDiscovery>.broadcast();
  final StreamController<bool> _connections =
      StreamController<bool>.broadcast();
  final StreamController<ApplianceCandidate> _found =
      StreamController<ApplianceCandidate>.broadcast();

  StreamSubscription<Uint8List>? _statusSubscription;
  StreamSubscription<Uint8List>? _discoverySubscription;
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<GattPeripheral>? _scanSubscription;

  String? _deviceId;
  bool _connected = false;
  bool _intentionalDisconnect = false;

  Stream<ApplianceStatus> get statuses => _statuses.stream;
  Stream<ApplianceDiscovery> get discoveries => _discoveries.stream;
  Stream<bool> get connections => _connections.stream;
  Stream<ApplianceCandidate> get found => _found.stream;

  bool get isConnected => _connected;
  String? get deviceId => _deviceId;

  static const GattScanSpec _scanSpec = GattScanSpec(
    serviceUuids: <String>[ApplianceProtocol.serviceUuid],
    namePrefixes: <String>[ApplianceProtocol.advertisedNamePrefix],
    optionalServiceUuids: <String>[ApplianceProtocol.serviceUuid],
  );

  Future<GattAvailability> availability() => _transport.availability();

  Future<void> requestAccess() => _transport.requestAccess();

  /// Look for appliances in range.
  ///
  /// Only devices advertising our own service are reported. An appliance that is
  /// not in setup mode does not advertise at all, so an empty scan usually means
  /// "hold the button for five seconds", which is what the setup screen says.
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    await _scanSubscription?.cancel();
    _scanSubscription = _transport.discoveries.listen((
      GattPeripheral peripheral,
    ) {
      // What the scan actually saw, kept for support: a device that does not
      // show up, or one that shows up and should not, is otherwise impossible
      // to tell apart from a filter that is wrong.
      ClientDiagnosticLog.instance.record(
        'appliance',
        'scan_saw',
        details: <String, Object?>{
          'name': peripheral.name,
          'services': peripheral.serviceUuids,
          'accepted': _looksLikeAppliance(peripheral),
        },
      );
      if (!_looksLikeAppliance(peripheral)) return;
      _found.add(
        ApplianceCandidate(
          deviceId: peripheral.id,
          name: _displayName(peripheral),
          signal: peripheral.rssi,
        ),
      );
    });
    ClientDiagnosticLog.instance.record('appliance', 'scan_started');
    await _transport.startScan(_scanSpec, timeout: timeout);
  }

  Future<void> stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _transport.stopScan();
  }

  /// What to call a device we have already identified.
  ///
  /// Android remembers a name and a service list per bonded address and merges
  /// them into later scan results. A Pi that once ran something else therefore
  /// arrives under that older name, and the setup screen ended up offering
  /// "WirelessAADongle-neo" as a NeoRecall Desk. Its own advertisement is the
  /// thing we trust: if it carries our service, we know what it is, and the
  /// cached label is worse than useless — it makes people think they are about
  /// to pair the wrong device.
  static String _displayName(GattPeripheral peripheral) {
    final String advertised = peripheral.name.trim();
    if (advertised.startsWith(ApplianceProtocol.advertisedNamePrefix)) {
      return advertised;
    }
    return ApplianceProtocol.advertisedNamePrefix;
  }

  static bool _looksLikeAppliance(GattPeripheral peripheral) {
    final advertisesService = peripheral.serviceUuids.any(
      (String uuid) => uuid.toLowerCase() == ApplianceProtocol.serviceUuid,
    );
    final namedLikeOne = peripheral.name.startsWith(
      ApplianceProtocol.advertisedNamePrefix,
    );
    // Some platforms omit service UUIDs from the advertisement, so the name is a
    // fallback rather than a second requirement.
    return advertisesService || namedLikeOne;
  }

  Future<void> connect(String deviceId, {bool pair = false}) async {
    _intentionalDisconnect = false;
    _deviceId = deviceId;
    ClientDiagnosticLog.instance.record('appliance', 'connection_started');

    // A direct connection, not Android's background one. With autoConnect the
    // platform waits for the device to come to it and reports nothing in the
    // meantime, so a user standing in front of a device that was advertising
    // the whole time watched "Connecting…" for thirty seconds and then got a
    // timeout. Somebody is waiting for this: succeed or fail, but do it now.
    await _transport.connect(deviceId, autoReconnect: false);
    await _transport.requestMtu(deviceId, 247);
    if (pair) {
      // Writing to the command or setup characteristic needs an encrypted link.
      // The appliance only accepts pairing while somebody is holding its button,
      // so this is where the physical confirmation happens.
      await _transport.pair(deviceId);
    }
    await _transport.discoverCharacteristics(deviceId);

    await _connectionSubscription?.cancel();
    _connectionSubscription = _transport
        .connectionChanges(deviceId)
        .listen(_onConnectionChanged);

    await _subscribeAll(deviceId);
    _connected = true;
    _connections.add(true);
    ClientDiagnosticLog.instance.record('appliance', 'connection_ready');
  }

  Future<void> _subscribeAll(String deviceId) async {
    await _statusSubscription?.cancel();
    final statusStream = await _transport.subscribe(
      deviceId,
      ApplianceProtocol.serviceUuid,
      ApplianceProtocol.statusUuid,
    );
    _statusSubscription = statusStream.listen(_onStatusBytes);

    await _discoverySubscription?.cancel();
    final discoveryStream = await _transport.subscribe(
      deviceId,
      ApplianceProtocol.serviceUuid,
      ApplianceProtocol.discoveryUuid,
    );
    _discoverySubscription = discoveryStream.listen(_onDiscoveryBytes);
  }

  void _onStatusBytes(Uint8List payload) {
    try {
      _statuses.add(ApplianceStatus.decode(payload));
    } on CborFormatException catch (error) {
      // A status we cannot read is a bug, not a reason to drop the link: the
      // next update is a second away and the recording never depended on this.
      ClientDiagnosticLog.instance.record(
        'appliance',
        'status_unreadable',
        level: 'warn',
        details: <String, Object?>{'reason': error.message},
      );
    }
  }

  /// Pages of the result currently arriving, and what it is a result of.
  ///
  /// Held here rather than in the controller so that everything above the link
  /// keeps seeing one complete result per scan, exactly as it did when a result
  /// still fitted in a single notification.
  final List<Map<String, Object?>> _partial = <Map<String, Object?>>[];
  String _partialKind = '';
  int _nextPage = 0;

  void _onDiscoveryBytes(Uint8List payload) {
    final ApplianceDiscovery page;
    try {
      page = ApplianceDiscovery.decode(payload);
    } on CborFormatException catch (error) {
      ClientDiagnosticLog.instance.record(
        'appliance',
        'scan_result_unreadable',
        level: 'warn',
        details: <String, Object?>{'reason': error.message},
      );
      return;
    }

    // A first page, or a result of a different kind, replaces whatever was
    // being collected. Two scans can overlap — tapping Find twice is enough —
    // and merging their pages would show headphones among Wi-Fi networks.
    if (page.page == 0 || page.kind != _partialKind) {
      _partial.clear();
      _partialKind = page.kind;
      _nextPage = 0;
    }

    if (page.page != _nextPage) {
      // A page went missing. Emitting a partial list would show a shorter
      // answer as if it were the whole one, so the result is abandoned and the
      // owner can ask again — the scan button never became unavailable.
      ClientDiagnosticLog.instance.record(
        'appliance',
        'scan_result_incomplete',
        level: 'warn',
        details: <String, Object?>{
          'kind': page.kind,
          'expected': _nextPage,
          'received': page.page,
        },
      );
      _partial.clear();
      _partialKind = '';
      _nextPage = 0;
      return;
    }

    _partial.addAll(page.entries);
    _nextPage += 1;
    if (!page.isLastPage) return;

    _discoveries.add(
      page.withEntries(List<Map<String, Object?>>.unmodifiable(_partial)),
    );
    _partial.clear();
    _partialKind = '';
    _nextPage = 0;
  }

  void _onConnectionChanged(bool connected) {
    if (connected == _connected) return;
    _connected = connected;
    _connections.add(connected);
    if (!connected && !_intentionalDisconnect) {
      ClientDiagnosticLog.instance.record(
        'appliance',
        'connection_lost',
        level: 'warn',
      );
    }
  }

  /// Read the current status once, without waiting for the next notification.
  ///
  /// Returns it directly as well as publishing it, so a caller that has just
  /// connected has something to show on the very next frame instead of after a
  /// stream round trip.
  Future<ApplianceStatus?> refresh() async {
    final deviceId = _deviceId;
    if (deviceId == null) return null;
    try {
      final payload = await _transport.read(
        deviceId,
        ApplianceProtocol.serviceUuid,
        ApplianceProtocol.statusUuid,
      );
      final status = ApplianceStatus.decode(payload);
      _statuses.add(status);
      return status;
    } on CborFormatException {
      return null;
    }
  }

  Future<void> send(ApplianceCommand command) async {
    final deviceId = _deviceId;
    if (deviceId == null) {
      throw StateError('not connected to an appliance');
    }
    await _transport.write(
      deviceId,
      ApplianceProtocol.serviceUuid,
      ApplianceProtocol.commandUuid,
      command.encode(),
    );
  }

  Future<void> provision(ApplianceProvisioning provisioning) async {
    final deviceId = _deviceId;
    if (deviceId == null) {
      throw StateError('not connected to an appliance');
    }
    await _transport.write(
      deviceId,
      ApplianceProtocol.serviceUuid,
      ApplianceProtocol.provisionUuid,
      provisioning.encode(),
    );
  }

  Future<void> disconnect() async {
    _intentionalDisconnect = true;
    final deviceId = _deviceId;
    await _statusSubscription?.cancel();
    await _discoverySubscription?.cancel();
    await _connectionSubscription?.cancel();
    _statusSubscription = null;
    _discoverySubscription = null;
    _connectionSubscription = null;
    if (deviceId != null) {
      await _transport.disconnect(deviceId);
    }
    _connected = false;
    _connections.add(false);
  }

  Future<void> dispose() async {
    await disconnect();
    await _scanSubscription?.cancel();
    await _statuses.close();
    await _discoveries.close();
    await _connections.close();
    await _found.close();
  }
}

/// An appliance seen in a scan, before anything is known about it.
class ApplianceCandidate {
  const ApplianceCandidate({
    required this.deviceId,
    required this.name,
    this.signal,
  });

  final String deviceId;
  final String name;
  final int? signal;
}
