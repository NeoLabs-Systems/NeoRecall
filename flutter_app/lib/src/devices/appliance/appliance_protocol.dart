import 'dart:typed_data';

import 'appliance_codec.dart';

/// The contract with the NeoRecall Desk appliance.
///
/// The Dart side of `hardware/neorecall-desk/src/neorecall_desk/control/protocol.py`.
/// Keys are short because a status notification has to fit in one Bluetooth
/// packet; everything the user actually reads is a full sentence the appliance
/// already phrased for them, so nothing here needs translating for display.
class ApplianceProtocol {
  const ApplianceProtocol._();

  static const int version = 1;

  static const String serviceUuid = '6e4d0001-9b3f-4f2a-8d21-1c7a5f0b9e11';
  static const String statusUuid = '6e4d0002-9b3f-4f2a-8d21-1c7a5f0b9e11';
  static const String commandUuid = '6e4d0003-9b3f-4f2a-8d21-1c7a5f0b9e11';
  static const String provisionUuid = '6e4d0004-9b3f-4f2a-8d21-1c7a5f0b9e11';
  static const String discoveryUuid = '6e4d0005-9b3f-4f2a-8d21-1c7a5f0b9e11';

  static const String advertisedNamePrefix = 'NeoRecall Desk';

  static const String start = 'start';
  static const String stop = 'stop';
  static const String setOutput = 'set_output';
  static const String setHeadsetMic = 'set_headset_mic';
  static const String wifiScan = 'wifi_scan';
  static const String drainList = 'drain_list';
  static const String drainPull = 'drain_pull';
  static const String drainAck = 'drain_ack';
  static const String bluetoothScan = 'bt_scan';
  static const String bluetoothConnect = 'bt_connect';
  static const String bluetoothDisconnect = 'bt_disconnect';
  static const String bluetoothForget = 'bt_forget';
  static const String rename = 'rename';
  static const String forgetAccount = 'forget_account';
  static const String updateNow = 'update_now';
  static const String setAutoUpdate = 'set_auto_update';
  static const String selfTest = 'selftest';
  static const String setup = 'setup';
}

enum ApplianceState { unconfigured, idle, recording }

enum ApplianceOutput { speaker, headphones }

enum ApplianceMicSource { builtIn, headset }

ApplianceState _stateFrom(Object? raw) => switch (raw) {
  'idle' => ApplianceState.idle,
  'recording' => ApplianceState.recording,
  _ => ApplianceState.unconfigured,
};

ApplianceOutput _outputFrom(Object? raw) =>
    raw == 'headphones' ? ApplianceOutput.headphones : ApplianceOutput.speaker;

ApplianceMicSource _micFrom(Object? raw) =>
    raw == 'headset' ? ApplianceMicSource.headset : ApplianceMicSource.builtIn;

int _int(Object? raw) => raw is int ? raw : 0;

String _string(Object? raw) => raw is String ? raw : '';

/// The outcome of the last thing the app asked the appliance to do.
class ApplianceCommandResult {
  const ApplianceCommandResult({
    required this.command,
    required this.ok,
    required this.message,
  });

  final String command;
  final bool ok;
  final String message;
}

/// One complete picture of the appliance.
class ApplianceStatus {
  const ApplianceStatus({
    this.state = ApplianceState.unconfigured,
    this.recordingElapsed = Duration.zero,
    this.pendingRecordings = 0,
    this.needsAttention = 0,
    this.output = ApplianceOutput.speaker,
    this.micSource = ApplianceMicSource.builtIn,
    this.headsetConnected = false,
    this.headsetName = '',
    this.headsetBattery,
    this.networkOnline = false,
    this.authenticationFailed = false,
    this.deviceRevoked = false,
    this.error = '',
    this.firmware = '',
    this.deviceId = '',
    this.updateState = 'idle',
    this.autoUpdate = true,
    this.lastResult,
  });

  final ApplianceState state;
  final Duration recordingElapsed;
  final int pendingRecordings;
  final int needsAttention;
  final ApplianceOutput output;
  final ApplianceMicSource micSource;
  final bool headsetConnected;
  final String headsetName;
  final int? headsetBattery;
  final bool networkOnline;
  final bool authenticationFailed;
  final bool deviceRevoked;
  final String error;
  final String firmware;

  /// The id the server gave this appliance, so the link can be matched against
  /// a row in the account's device list. Empty until it has registered.
  final String deviceId;

  /// What the software is doing about itself: `idle`, `checking`, `installing`
  /// or `failed`. A word rather than flags, so it can be shown as it stands.
  final String updateState;
  final bool autoUpdate;
  final ApplianceCommandResult? lastResult;

  bool get isRecording => state == ApplianceState.recording;

  /// What the current output is called, in words.
  ///
  /// Not sent over the link: when the output is headphones this is the headset's
  /// own name, which is already in the payload, and when it is the speaker it is
  /// a word the app can write itself. Sending it twice cost bytes a single
  /// Bluetooth packet does not have.
  String get outputName => output == ApplianceOutput.headphones
      ? (headsetName.isEmpty ? 'Headphones' : headsetName)
      : 'Speaker';

  bool get needsSetup =>
      state == ApplianceState.unconfigured ||
      authenticationFailed ||
      deviceRevoked;

  /// True while the appliance is checking for or installing a new version.
  bool get isUpdating =>
      updateState == 'checking' || updateState == 'installing';

  bool get isSyncing =>
      state == ApplianceState.idle && pendingRecordings > 0 && networkOnline;

  /// The one line the device list shows, in words rather than fields.
  String get summary {
    if (needsSetup) return 'Not set up yet';
    if (isRecording) return 'Recording · ${formatElapsed(recordingElapsed)}';
    if (isSyncing) {
      return pendingRecordings == 1
          ? 'Sending 1 recording'
          : 'Sending $pendingRecordings recordings';
    }
    if (pendingRecordings > 0) {
      return pendingRecordings == 1
          ? '1 recording waiting to be sent'
          : '$pendingRecordings recordings waiting to be sent';
    }
    if (headsetConnected) return 'Ready · $headsetName';
    return 'Ready';
  }

  static ApplianceStatus decode(Uint8List payload) {
    final raw = cborDecode(payload);
    if (raw is! Map<String, Object?>) {
      throw const CborFormatException('a status update must be a map');
    }
    final resultRaw = raw['res'];
    return ApplianceStatus(
      state: _stateFrom(raw['st']),
      recordingElapsed: Duration(milliseconds: _int(raw['el'])),
      pendingRecordings: _int(raw['pc']),
      needsAttention: _int(raw['na']),
      output: _outputFrom(raw['out']),
      micSource: _micFrom(raw['mic']),
      headsetConnected: raw['hc'] == true,
      headsetName: _string(raw['hn']),
      headsetBattery: raw['hb'] is int ? raw['hb'] as int : null,
      networkOnline: raw['net'] == true,
      authenticationFailed: raw['auth'] == true,
      deviceRevoked: raw['rev'] == true,
      error: _string(raw['err']),
      firmware: _string(raw['fw']),
      deviceId: _string(raw['did']),
      updateState: raw['upd'] is String ? raw['upd'] as String : 'idle',
      autoUpdate: raw['auto'] != false,
      lastResult: resultRaw is Map<String, Object?>
          ? ApplianceCommandResult(
              command: _string(resultRaw['c']),
              ok: resultRaw['ok'] != false,
              message: _string(resultRaw['m']),
            )
          : null,
    );
  }
}

/// A network, a pair of headphones, or a check verdict the appliance reported.
///
/// Results arrive in pages. A realistic list does not fit in one Bluetooth
/// notification — seven self-test verdicts are about 650 bytes against a
/// 244-byte packet — so the appliance splits them and [page] says which part
/// this is. [ApplianceLink] reassembles them; nothing above it sees a page.
/// One page of a recording travelling over Bluetooth during a drain.
///
/// Pages are numbered so a lost notification is detectable and the pull can be
/// resumed from the first missing page — at Bluetooth speeds a restart costs
/// minutes, a resume seconds.
class ApplianceAudioPage {
  const ApplianceAudioPage({
    required this.chunkPrefix,
    required this.page,
    required this.pages,
    required this.data,
  });

  final String chunkPrefix;
  final int page;
  final int pages;
  final Uint8List data;

  static ApplianceAudioPage? tryDecode(Map<Object?, Object?> raw) {
    if (raw['k'] != 'audio') return null;
    final Object? data = raw['d'];
    if (data is! Uint8List) return null;
    return ApplianceAudioPage(
      chunkPrefix: raw['ch'] is String ? raw['ch']! as String : '',
      page: raw['p'] is int ? raw['p']! as int : 0,
      pages: raw['n'] is int ? raw['n']! as int : 1,
      data: data,
    );
  }
}

/// A recording waiting on the device, as announced by a drain listing.
class AppliancePendingRecording {
  const AppliancePendingRecording({
    required this.id,
    required this.byteSize,
    required this.durationMs,
    required this.sha256,
    this.createdAt,
  });

  final String id;
  final int byteSize;
  final int durationMs;
  final String sha256;
  final DateTime? createdAt;

  static AppliancePendingRecording? fromEntry(Map<String, Object?> entry) {
    final Object? id = entry['id'];
    final Object? sha = entry['sh'];
    if (id is! String || id.isEmpty || sha is! String || sha.isEmpty) {
      return null;
    }
    return AppliancePendingRecording(
      id: id,
      byteSize: entry['by'] is int ? entry['by']! as int : 0,
      durationMs: entry['du'] is int ? entry['du']! as int : 0,
      sha256: sha,
      createdAt: entry['at'] is String
          ? DateTime.tryParse(entry['at']! as String)
          : null,
    );
  }
}

class ApplianceDiscovery {
  const ApplianceDiscovery({
    required this.kind,
    required this.entries,
    this.page = 0,
    this.pages = 1,
  });

  final String kind;
  final List<Map<String, Object?>> entries;

  /// Which page this is, and how many the appliance is sending in total.
  final int page;
  final int pages;

  bool get isWifi => kind == 'wifi';
  bool get isBluetooth => kind == 'bluetooth';
  bool get isSelfTest => kind == 'selftest';

  /// True when this page completes the result the appliance is sending.
  bool get isLastPage => page >= pages - 1;

  ApplianceDiscovery withEntries(List<Map<String, Object?>> combined) =>
      ApplianceDiscovery(
        kind: kind,
        entries: combined,
        page: page,
        pages: pages,
      );

  static ApplianceDiscovery decode(Uint8List payload) {
    final raw = cborDecode(payload);
    if (raw is! Map<String, Object?>) {
      throw const CborFormatException('a scan result must be a map');
    }
    final entries = raw['e'];
    // An appliance older than paging sends neither key, and one page is exactly
    // what it means.
    final pages = raw['n'] is int ? raw['n'] as int : 1;
    return ApplianceDiscovery(
      kind: _string(raw['k']),
      entries: entries is List
          ? entries.whereType<Map<String, Object?>>().toList(growable: false)
          : const <Map<String, Object?>>[],
      page: raw['p'] is int ? raw['p'] as int : 0,
      pages: pages < 1 ? 1 : pages,
    );
  }
}

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.signal,
    required this.secured,
  });

  final String ssid;
  final int signal;
  final bool secured;

  static WifiNetwork from(Map<String, Object?> entry) => WifiNetwork(
    ssid: _string(entry['ssid']),
    signal: _int(entry['signal']),
    secured: entry['secured'] == true,
  );
}

/// One verdict from the device's own check of itself.
class ApplianceCheck {
  const ApplianceCheck({
    required this.name,
    required this.ok,
    required this.detail,
  });

  final String name;
  final bool ok;
  final String detail;

  static ApplianceCheck from(Map<String, Object?> entry) => ApplianceCheck(
    name: _string(entry['name']),
    ok: entry['ok'] == true,
    detail: _string(entry['detail']),
  );
}

class ApplianceHeadphone {
  const ApplianceHeadphone({
    required this.address,
    required this.name,
    required this.paired,
    required this.connected,
    this.battery,
  });

  final String address;
  final String name;
  final bool paired;
  final bool connected;
  final int? battery;

  static ApplianceHeadphone from(Map<String, Object?> entry) =>
      ApplianceHeadphone(
        address: _string(entry['address']),
        name: _string(entry['name']),
        paired: entry['paired'] == true,
        connected: entry['connected'] == true,
        battery: entry['battery'] is int ? entry['battery'] as int : null,
      );
}

/// Commands, encoded exactly as the appliance's decoder expects them.
class ApplianceCommand {
  const ApplianceCommand._(this.payload);

  final Map<String, Object?> payload;

  Uint8List encode() => cborEncode(payload);

  static const ApplianceCommand start = ApplianceCommand._({
    'c': ApplianceProtocol.start,
  });
  static const ApplianceCommand stop = ApplianceCommand._({
    'c': ApplianceProtocol.stop,
  });
  static const ApplianceCommand scanWifi = ApplianceCommand._({
    'c': ApplianceProtocol.wifiScan,
  });

  /// List the recordings waiting on the device for a Bluetooth hand-over.
  static const ApplianceCommand drainList = ApplianceCommand._({
    'c': ApplianceProtocol.drainList,
  });

  /// Pull one recording, resuming from [fromPage] after a lost notification.
  static ApplianceCommand drainPull(String chunkId, {int fromPage = 0}) =>
      ApplianceCommand._(<String, Object?>{
        'c': ApplianceProtocol.drainPull,
        'ch': chunkId,
        if (fromPage > 0) 'fp': fromPage,
      });

  /// Tell the device its copy may go: the phone durably stored bytes whose
  /// SHA-256 is [sha256] — the device checks that against its own record.
  static ApplianceCommand drainAck(String chunkId, String sha256) =>
      ApplianceCommand._(<String, Object?>{
        'c': ApplianceProtocol.drainAck,
        'ch': chunkId,
        'sh': sha256,
      });
  static const ApplianceCommand scanBluetooth = ApplianceCommand._({
    'c': ApplianceProtocol.bluetoothScan,
  });

  /// Ask the appliance to check its own speakers and microphones.
  static const ApplianceCommand runSelfTest = ApplianceCommand._({
    'c': ApplianceProtocol.selfTest,
  });

  static const ApplianceCommand forgetAccount = ApplianceCommand._({
    'c': ApplianceProtocol.forgetAccount,
  });

  static ApplianceCommand useOutput(ApplianceOutput output) =>
      ApplianceCommand._({
        'c': ApplianceProtocol.setOutput,
        't': output == ApplianceOutput.headphones ? 'headphones' : 'speaker',
      });

  static ApplianceCommand useHeadsetMicrophone(bool enabled) =>
      ApplianceCommand._({'c': ApplianceProtocol.setHeadsetMic, 'on': enabled});

  static ApplianceCommand connectHeadphones(String address) =>
      ApplianceCommand._({
        'c': ApplianceProtocol.bluetoothConnect,
        'a': address,
      });

  static ApplianceCommand disconnectHeadphones(String address) =>
      ApplianceCommand._({
        'c': ApplianceProtocol.bluetoothDisconnect,
        'a': address,
      });

  static ApplianceCommand forgetHeadphones(String address) =>
      ApplianceCommand._({
        'c': ApplianceProtocol.bluetoothForget,
        'a': address,
      });

  /// Look for a new version now. The appliance postpones it while recording.
  static const ApplianceCommand updateNow = ApplianceCommand._({
    'c': ApplianceProtocol.updateNow,
  });

  static ApplianceCommand useAutomaticUpdates(bool enabled) =>
      ApplianceCommand._({'c': ApplianceProtocol.setAutoUpdate, 'on': enabled});

  static ApplianceCommand renameTo(String name) =>
      ApplianceCommand._({'c': ApplianceProtocol.rename, 'n': name});
}

/// Everything the appliance needs to join a network and reach an account.
class ApplianceProvisioning {
  const ApplianceProvisioning({
    required this.backendUrl,
    required this.apiKey,
    this.wifiSsid = '',
    this.wifiPassword = '',
    this.timezone = '',
    this.deviceName = '',
    this.tlsVerify = true,
  });

  final String backendUrl;
  final String apiKey;
  final String wifiSsid;
  final String wifiPassword;
  final String timezone;
  final String deviceName;
  final bool tlsVerify;

  Uint8List encode() {
    final payload = <String, Object?>{
      'url': backendUrl,
      'key': apiKey,
      'tls': tlsVerify,
    };
    if (wifiSsid.isNotEmpty) payload['ssid'] = wifiSsid;
    if (wifiPassword.isNotEmpty) payload['psk'] = wifiPassword;
    if (timezone.isNotEmpty) payload['tz'] = timezone;
    if (deviceName.isNotEmpty) payload['n'] = deviceName;
    return cborEncode(payload);
  }
}

/// `1:23:45` while recording, `04:12` for anything shorter than an hour.
String formatElapsed(Duration elapsed) {
  final seconds = elapsed.inSeconds;
  final minutes = (seconds ~/ 60) % 60;
  final hours = seconds ~/ 3600;
  final rest = seconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = rest.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}
