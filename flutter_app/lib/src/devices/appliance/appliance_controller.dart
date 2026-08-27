import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../diagnostics/client_diagnostic_log.dart';
import '../ble/gatt_transport.dart';
import 'appliance_link.dart';
import 'appliance_protocol.dart';

/// Creates an access key for the appliance and returns it.
///
/// The user never sees this: the app mints a scoped key on their behalf during
/// setup, which is what replaces typing a server address and a token into a
/// device with no keyboard.
typedef ApiKeyMinter = Future<String> Function(String name);

/// Drives one NeoRecall Desk appliance from the app.
///
/// It holds the live picture while the phone is nearby, and nothing more than
/// that. The appliance records, buffers and uploads on its own, so this
/// controller never owns a recording — losing it mid-meeting costs the display
/// and nothing else.
class ApplianceController extends ChangeNotifier {
  ApplianceController({
    required ApplianceLink link,
    required ApiKeyMinter mintApiKey,
    required String Function() backendUrl,
    required String Function() timezone,
    required String? Function() rememberedDevice,
    required Future<void> Function(String?) rememberDevice,
  }) : _link = link,
       _mintApiKey = mintApiKey,
       _backendUrl = backendUrl,
       _timezone = timezone,
       _rememberedDevice = rememberedDevice,
       _rememberDevice = rememberDevice {
    _statusSubscription = _link.statuses.listen(_onStatus);
    _discoverySubscription = _link.discoveries.listen(_onDiscovery);
    _connectionSubscription = _link.connections.listen(_onConnection);
    _foundSubscription = _link.found.listen(_onCandidate);
  }

  final ApplianceLink _link;
  final ApiKeyMinter _mintApiKey;
  final String Function() _backendUrl;
  final String Function() _timezone;
  final String? Function() _rememberedDevice;
  final Future<void> Function(String?) _rememberDevice;

  late final StreamSubscription<ApplianceStatus> _statusSubscription;
  late final StreamSubscription<ApplianceDiscovery> _discoverySubscription;
  late final StreamSubscription<bool> _connectionSubscription;
  late final StreamSubscription<ApplianceCandidate> _foundSubscription;

  ApplianceStatus? _status;
  bool _connected = false;
  bool _busy = false;
  bool _scanning = false;
  bool _lookingForNetworks = false;
  bool _lookingForHeadphones = false;
  String _message = '';
  bool _messageIsError = false;

  final List<ApplianceCandidate> _candidates = <ApplianceCandidate>[];
  List<WifiNetwork> _networks = const <WifiNetwork>[];
  List<ApplianceHeadphone> _headphones = const <ApplianceHeadphone>[];
  List<ApplianceCheck> _checks = const <ApplianceCheck>[];
  bool _checking = false;
  Timer? _checkDeadline;

  /// Longer than the check takes — it stops the relay, plays a two-second tone,
  /// records it and starts the relay again — and short enough that a device
  /// that has stopped answering does not leave a spinner up indefinitely.
  static const Duration _checkTimeout = Duration(seconds: 45);

  ApplianceStatus? get status => _status;
  bool get isConnected => _connected;
  bool get isBusy => _busy;
  bool get isScanning => _scanning;
  bool get isLookingForNetworks => _lookingForNetworks;
  bool get isLookingForHeadphones => _lookingForHeadphones;
  String get message => _message;
  bool get messageIsError => _messageIsError;
  List<ApplianceCandidate> get candidates =>
      List<ApplianceCandidate>.unmodifiable(_candidates);
  List<WifiNetwork> get networks => _networks;
  List<ApplianceHeadphone> get headphones => _headphones;

  /// The device's own verdicts on its sound, newest first run wins.
  List<ApplianceCheck> get checks => _checks;
  bool get isChecking => _checking;

  /// The server device id of the appliance currently on the link, if it has one.
  String? get boundDeviceId {
    final deviceId = _status?.deviceId ?? '';
    return deviceId.isEmpty ? null : deviceId;
  }

  bool isBoundTo(String deviceId) => boundDeviceId == deviceId;

  // ------------------------------------------------------------------ events

  void _onStatus(ApplianceStatus status) {
    _status = status;
    final result = status.lastResult;
    if (result != null && result.message.isNotEmpty) {
      _message = result.message;
      _messageIsError = !result.ok;
    } else if (result != null && !result.ok) {
      _message = 'That did not work.';
      _messageIsError = true;
    }
    notifyListeners();
  }

  void _onDiscovery(ApplianceDiscovery discovery) {
    if (discovery.isWifi) {
      _networks = discovery.entries
          .map(WifiNetwork.from)
          .toList(growable: false);
      _lookingForNetworks = false;
    } else if (discovery.isSelfTest) {
      _checks = discovery.entries
          .map(ApplianceCheck.from)
          .toList(growable: false);
      _checkDeadline?.cancel();
      _checkDeadline = null;
      _checking = false;
    } else if (discovery.isBluetooth) {
      _headphones = discovery.entries
          .map(ApplianceHeadphone.from)
          .toList(growable: false);
      _lookingForHeadphones = false;
    }
    notifyListeners();
  }

  void _onConnection(bool connected) {
    _connected = connected;
    if (!connected) {
      // Keep the last status on screen rather than blanking it. The appliance
      // has not changed what it is doing just because the phone walked away.
      _networks = const <WifiNetwork>[];
      _headphones = const <ApplianceHeadphone>[];
    }
    notifyListeners();
  }

  void _onCandidate(ApplianceCandidate candidate) {
    final existing = _candidates.indexWhere(
      (ApplianceCandidate other) => other.deviceId == candidate.deviceId,
    );
    if (existing >= 0) {
      _candidates[existing] = candidate;
    } else {
      _candidates.add(candidate);
      _sawCandidate?.call();
    }
    notifyListeners();
  }

  /// Called once per newly seen device while a scan is waiting on one.
  VoidCallback? _sawCandidate;

  /// Wait only as long as the scan is still telling us something new.
  Future<void> _waitForCandidates({
    required Duration timeout,
    required Duration settleFor,
  }) async {
    final String? wanted = _rememberedDevice();
    final done = Completer<void>();
    Timer? settle;

    void finish() {
      settle?.cancel();
      if (!done.isCompleted) done.complete();
    }

    bool haveWanted() =>
        wanted != null &&
        wanted.isNotEmpty &&
        _candidates.any((ApplianceCandidate c) => c.deviceId == wanted);

    _sawCandidate = () {
      // The device this account set up is the answer; nothing found later
      // changes it, so there is no reason to keep looking.
      if (haveWanted()) {
        finish();
        return;
      }
      // Otherwise give the room a moment to finish answering, restarting the
      // grace period each time somebody new does.
      settle?.cancel();
      settle = Timer(settleFor, finish);
    };

    final Timer ceiling = Timer(timeout, finish);
    try {
      if (haveWanted()) finish();
      await done.future;
    } finally {
      ceiling.cancel();
      settle?.cancel();
      _sawCandidate = null;
    }
  }

  // ----------------------------------------------------------------- finding

  Future<GattAvailability> bluetoothAvailability() => _link.availability();

  /// Look for appliances in range.
  ///
  /// Returns as soon as the device this account already set up answers, rather
  /// than sitting out the whole timeout. The scan used to wait the full twelve
  /// seconds every time — including the one on app start, where the appliance
  /// typically advertises within a second — so opening the app to a Desk that
  /// was sitting right there took twelve seconds to admit it.
  ///
  /// [settleFor] is the grace period after the *first* unknown device appears.
  /// A first-time setup wants a moment to collect the others in the room; a
  /// reconnection to a known device does not, and takes the fast path above.
  Future<void> scanForAppliances({
    Duration timeout = const Duration(seconds: 12),
    Duration settleFor = const Duration(seconds: 2),
  }) async {
    if (_scanning) return;
    _candidates.clear();
    _scanning = true;
    _clearMessage();
    notifyListeners();
    try {
      await _link.requestAccess();
      await _link.startScan(timeout: timeout);
      await _waitForCandidates(timeout: timeout, settleFor: settleFor);
    } on Object catch (error) {
      ClientDiagnosticLog.instance.record(
        'appliance',
        'scan_failed',
        level: 'error',
        details: <String, Object?>{'error': error.toString()},
      );
      _fail('Could not look for devices.');
    } finally {
      await _link.stopScan();
      _scanning = false;
      notifyListeners();
    }
  }

  Future<bool> connectTo(
    ApplianceCandidate candidate, {
    bool pair = false,
  }) async {
    return _guard(() async {
      await _link.connect(candidate.deviceId, pair: pair);
      // Read the state straight away and keep it here, rather than waiting for
      // it to come back around through the notification stream. A device page
      // that opens blank for a frame reads as a device that is not answering.
      final status = await _link.refresh();
      if (status != null) _status = status;
      _connected = _link.isConnected;
      // Remember it, so the next time this app opens the device is not a
      // stranger. Without this the Desk read "Out of range" after every app
      // restart — the device was fine, nothing had asked it anything.
      await _rememberDevice(candidate.deviceId);
      return true;
    }, 'Could not connect to that device.');
  }

  /// Reconnect to the device this account set up, if there is one.
  ///
  /// Called when the app opens. Failure is silent on purpose: the device being
  /// switched off is an ordinary situation, not an error to report.
  Future<void> reconnectToRemembered() async {
    final String? deviceId = _rememberedDevice();
    if (deviceId == null || deviceId.isEmpty || _connected) return;
    try {
      await _link.connect(deviceId);
      final status = await _link.refresh();
      if (status != null) _status = status;
      _connected = _link.isConnected;
    } catch (_) {
      _connected = false;
    }
    notifyListeners();
  }

  Future<void> disconnect() => _link.disconnect();

  Future<void> refresh() async {
    final status = await _link.refresh();
    if (status != null) {
      _status = status;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- commands

  Future<bool> startRecording() =>
      _send(ApplianceCommand.start, 'Could not start recording.');

  Future<bool> stopRecording() =>
      _send(ApplianceCommand.stop, 'Could not stop recording.');

  Future<bool> useOutput(ApplianceOutput output) => _send(
    ApplianceCommand.useOutput(output),
    'Could not change the sound output.',
  );

  Future<bool> useHeadsetMicrophone(bool enabled) => _send(
    ApplianceCommand.useHeadsetMicrophone(enabled),
    'Could not change the microphone.',
  );

  Future<bool> connectHeadphones(String address) => _send(
    ApplianceCommand.connectHeadphones(address),
    'Could not connect those headphones.',
  );

  Future<bool> disconnectHeadphones(String address) => _send(
    ApplianceCommand.disconnectHeadphones(address),
    'Could not disconnect those headphones.',
  );

  Future<bool> forgetHeadphones(String address) => _send(
    ApplianceCommand.forgetHeadphones(address),
    'Could not forget those headphones.',
  );

  /// Ask the appliance to test its own speakers and microphones.
  ///
  /// It answers by publishing verdicts, not by returning them: the test plays a
  /// tone and listens for several seconds, and the link has to stay answerable
  /// throughout. [isChecking] stays true until they arrive, so a device that
  /// goes quiet mid-check leaves a spinner rather than a wrong verdict — see
  /// [_checkTimeout] for how long that is allowed to last.
  Future<void> runSelfTest() async {
    _checks = const <ApplianceCheck>[];
    _checking = true;
    notifyListeners();
    final sent = await _send(
      ApplianceCommand.runSelfTest,
      'Could not start the check.',
    );
    if (!sent) {
      _stopChecking();
      return;
    }
    // The appliance stops the audio relay, plays a tone and listens for it. If
    // it never reports back — it was unplugged, the link dropped — the spinner
    // has to end anyway, or the button it replaced never returns.
    _checkDeadline?.cancel();
    _checkDeadline = Timer(_checkTimeout, () {
      if (!_checking) return;
      _fail('The device did not finish the check.');
      _stopChecking();
    });
  }

  void _stopChecking() {
    _checkDeadline?.cancel();
    _checkDeadline = null;
    _checking = false;
    notifyListeners();
  }

  /// Ask the appliance to look for a new version now.
  ///
  /// It refuses while a recording is running and updates afterwards instead —
  /// the appliance decides that, not the app, because only it knows whether
  /// something is being recorded at this moment.
  Future<bool> checkForUpdate() =>
      _send(ApplianceCommand.updateNow, 'Could not start the update.');

  Future<bool> useAutomaticUpdates(bool enabled) => _send(
    ApplianceCommand.useAutomaticUpdates(enabled),
    'Could not change automatic updates.',
  );

  Future<bool> rename(String name) =>
      _send(ApplianceCommand.renameTo(name), 'Could not rename the device.');

  Future<bool> removeFromAccount() async {
    final bool sent = await _send(
      ApplianceCommand.forgetAccount,
      'Could not remove the device from your account.',
    );
    // Forget it here too, or the app would keep reaching for a device the
    // owner just removed.
    await _rememberDevice(null);
    return sent;
  }

  Future<void> lookForNetworks() async {
    _lookingForNetworks = true;
    notifyListeners();
    final sent = await _send(
      ApplianceCommand.scanWifi,
      'Could not look for networks.',
    );
    if (!sent) {
      _lookingForNetworks = false;
      notifyListeners();
    }
  }

  Future<void> lookForHeadphones() async {
    _lookingForHeadphones = true;
    notifyListeners();
    final sent = await _send(
      ApplianceCommand.scanBluetooth,
      'Could not look for headphones.',
    );
    if (!sent) {
      _lookingForHeadphones = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------- setup

  /// Finish setting up the appliance: mint a key, then hand it everything.
  ///
  /// The key is created first and deliberately scoped to ingest only. If the
  /// appliance then refuses the settings — a wrong Wi-Fi password is the common
  /// case — the key exists but is unused, which is recoverable; sending
  /// credentials the account cannot back would not be.
  Future<bool> completeSetup({
    String wifiSsid = '',
    String wifiPassword = '',
    String deviceName = '',
  }) async {
    return _guard(() async {
      final backend = _backendUrl();
      if (backend.isEmpty) {
        _fail('This app is not signed in to a NeoRecall server yet.');
        return false;
      }
      final apiKey = await _mintApiKey(
        deviceName.isEmpty ? 'NeoRecall Desk' : deviceName,
      );
      await _link.provision(
        ApplianceProvisioning(
          backendUrl: backend,
          apiKey: apiKey,
          wifiSsid: wifiSsid,
          wifiPassword: wifiPassword,
          // The account's IANA zone, the same one this app stamps on its own
          // recordings. DateTime.timeZoneName gives an abbreviation — "CEST" —
          // and the server rejects the session with "Invalid IANA timezone",
          // so every recording the appliance made stayed on the device.
          timezone: _timezone(),
          deviceName: deviceName,
        ),
      );
      // The appliance answers through its next status update, so the caller
      // waits for that rather than assuming success here.
      return true;
    }, 'Setup could not be completed.');
  }

  /// True once the appliance has confirmed the setup it was sent.
  bool get setupSucceeded {
    final status = _status;
    if (status == null) return false;
    final result = status.lastResult;
    if (result == null || result.command != ApplianceProtocol.setup) {
      return false;
    }
    return result.ok && !status.needsSetup;
  }

  /// The appliance's own words about why setup failed, if it did.
  String? get setupFailure {
    final result = _status?.lastResult;
    if (result == null ||
        result.command != ApplianceProtocol.setup ||
        result.ok) {
      return null;
    }
    return result.message.isEmpty
        ? 'Setup could not be completed.'
        : result.message;
  }

  // ------------------------------------------------------------------ plumbing

  Future<bool> _send(ApplianceCommand command, String fallback) =>
      _guard(() async {
        await _link.send(command);
        return true;
      }, fallback);

  Future<bool> _guard(Future<bool> Function() action, String fallback) async {
    if (_busy) return false;
    _busy = true;
    _clearMessage();
    notifyListeners();
    try {
      return await action();
    } on Object catch (error) {
      // The owner gets the plain sentence the caller wrote; the exception goes
      // where exceptions belong. A filter that tried to decide which exception
      // texts were readable enough let "TimeoutException after 0:00:30.000000:
      // Future not completed" onto the device page.
      ClientDiagnosticLog.instance.record(
        'appliance',
        'operation_failed',
        level: 'error',
        details: <String, Object?>{'error': error.toString()},
      );
      _fail(fallback);
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void _clearMessage() {
    _message = '';
    _messageIsError = false;
  }

  void _fail(String message) {
    _message = message;
    _messageIsError = true;
  }

  @override
  void dispose() {
    _checkDeadline?.cancel();
    unawaited(_statusSubscription.cancel());
    unawaited(_discoverySubscription.cancel());
    unawaited(_connectionSubscription.cancel());
    unawaited(_foundSubscription.cancel());
    unawaited(_link.dispose());
    super.dispose();
  }
}
