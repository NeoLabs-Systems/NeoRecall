import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'local_backend_installer_models.dart';

/// Desktop hosts can run the NeoRecall server themselves.
final bool supportsLocalBackendInstall =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

const String _releasesUrl =
    'https://api.github.com/repos/NeoLabs-Systems/NeoRecall/releases?per_page=50';
const int _defaultPort = 4500;

/// Installs NeoRecall on this computer the same way `install.sh` does: download
/// the `neorecall` binary from the newest release on the channel, check its
/// published checksum, then run `neorecall install`, which installs the signed
/// runtime, and wait for the service to answer.
class LocalBackendInstaller {
  LocalBackendInstaller({
    http.Client? client,
    Uri? releases,
    Map<String, String>? environment,
  }) : _http = client ?? http.Client(),
       _releases = releases ?? Uri.parse(_releasesUrl),
       _environment = environment ?? Platform.environment;

  final http.Client _http;
  final Uri _releases;
  final Map<String, String> _environment;
  final StreamController<LocalBackendInstallEvent> _events =
      StreamController<LocalBackendInstallEvent>.broadcast();
  Process? _process;
  bool _cancelled = false;
  bool _disposed = false;

  Stream<LocalBackendInstallEvent> get events => _events.stream;

  Future<LocalBackendInstallResult> install({
    required LocalBackendChannel channel,
  }) async {
    if (_disposed) {
      throw const LocalBackendInstallerException(
        'SETUP_INSTALLER_DISPOSED',
        'The installer is no longer available.',
        retryable: false,
      );
    }
    if (_isSandboxed) {
      throw const LocalBackendInstallerException(
        'SETUP_APP_SANDBOX',
        'This build of NeoRecall runs in the macOS App Sandbox, which cannot '
            'install a server: it redirects the home directory into the app '
            'container and blocks the background service.',
        retryable: false,
        remedy:
            'Install from a terminal instead:\n'
            'bash <(curl -fsSL https://raw.githubusercontent.com/'
            'NeoLabs-Systems/NeoRecall/main/install.sh)',
      );
    }
    _cancelled = false;
    try {
      _emit(
        LocalBackendInstallStage.prepare,
        'started',
        'Looking up the latest ${channel.cliName} release',
        progress: 0.02,
      );
      final command = await _downloadCommand(channel);
      _throwIfCancelled();

      _emit(
        LocalBackendInstallStage.install,
        'started',
        'Installing the runtime, models, and background service',
        progress: 0.4,
      );
      await _runStreaming(
        executable: command.path,
        arguments: <String>['install', '--channel', channel.cliName],
        workingDirectory: command.parent.path,
        stage: LocalBackendInstallStage.install,
        progressFrom: 0.4,
        progressTo: 0.92,
        failureCode: 'SETUP_INSTALL_FAILED',
        failureMessage:
            'NeoRecall could not finish installing on this computer.',
      );
      _emit(
        LocalBackendInstallStage.install,
        'completed',
        'NeoRecall is installed',
        progress: 0.93,
      );
      _throwIfCancelled();

      final port = _configuredPort();
      final backendUrl = 'http://localhost:$port';
      _emit(
        LocalBackendInstallStage.connect,
        'started',
        'Waiting for the NeoRecall service on port $port',
        progress: 0.94,
      );
      final version = await _waitForServer(port);
      _emit(
        LocalBackendInstallStage.complete,
        'completed',
        'NeoRecall is running at $backendUrl',
        progress: 1,
      );
      return LocalBackendInstallResult(
        backendUrl: backendUrl,
        commandPath: command.path,
        channel: channel,
        serverVersion: version,
      );
    } on LocalBackendInstallerException catch (error) {
      _emit(
        LocalBackendInstallStage.install,
        'failed',
        error.message,
        errorCode: error.code,
        retryable: error.retryable,
      );
      rethrow;
    } on Object catch (error) {
      final wrapped = LocalBackendInstallerException(
        'SETUP_FAILED',
        error.toString(),
      );
      _emit(
        LocalBackendInstallStage.install,
        'failed',
        wrapped.message,
        errorCode: wrapped.code,
      );
      throw wrapped;
    }
  }

  /// The release binary for this computer, named as the release workflow
  /// publishes it. Windows on ARM runs the x64 build.
  String get _assetName {
    if (Platform.isWindows) return 'neorecall-cli-windows-x64.exe';
    final abi = Abi.current();
    final arch = abi == Abi.macosArm64 || abi == Abi.linuxArm64
        ? 'arm64'
        : 'x64';
    return 'neorecall-cli-${Platform.isMacOS ? 'macos' : 'linux'}-$arch';
  }

  Future<File> _downloadCommand(LocalBackendChannel channel) async {
    final response = await _http
        .get(
          _releases,
          headers: const <String, String>{
            'Accept': 'application/vnd.github+json',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw LocalBackendInstallerException(
        'SETUP_DOWNLOAD_FAILED',
        'Could not reach GitHub releases (HTTP ${response.statusCode}).',
      );
    }
    final asset = _newestAsset(jsonDecode(response.body) as List, channel);
    if (asset == null) {
      throw LocalBackendInstallerException(
        'SETUP_RELEASE_UNAVAILABLE',
        'No ${channel.cliName} release has a build for this computer yet.',
        retryable: false,
      );
    }

    final configured = _environment['NEORECALL_BIN_DIR']?.trim() ?? '';
    final binDirectory = Directory(
      configured.isNotEmpty
          ? configured
          : <String>[
              _homeDirectory(),
              '.local',
              'bin',
            ].join(Platform.pathSeparator),
    )..createSync(recursive: true);
    final name = Platform.isWindows ? 'neorecall.exe' : 'neorecall';
    final target = File('${binDirectory.path}${Platform.pathSeparator}$name');
    final partial = File('${target.path}.download');
    try {
      _emit(
        LocalBackendInstallStage.download,
        'started',
        'Downloading NeoRecall',
        progress: 0.08,
      );
      final download = await _http.send(
        http.Request('GET', Uri.parse(asset['browser_download_url'] as String)),
      );
      if (download.statusCode != 200) {
        throw LocalBackendInstallerException(
          'SETUP_DOWNLOAD_FAILED',
          'Could not download NeoRecall (HTTP ${download.statusCode}).',
        );
      }
      await download.stream.pipe(partial.openWrite());
      _throwIfCancelled();

      final published = asset['digest']?.toString() ?? '';
      final actual = await sha256.bind(partial.openRead()).first;
      if (published != 'sha256:$actual') {
        throw const LocalBackendInstallerException(
          'SETUP_CHECKSUM_MISMATCH',
          'The download did not match its published checksum; nothing was '
              'installed.',
        );
      }
      if (!Platform.isWindows) {
        final mode = await Process.run('chmod', <String>['755', partial.path]);
        if (mode.exitCode != 0) {
          throw LocalBackendInstallerException(
            'SETUP_INSTALL_FAILED',
            'Could not make the NeoRecall command executable: ${mode.stderr}',
          );
        }
      }
      if (target.existsSync()) target.deleteSync();
      partial.renameSync(target.path);
    } finally {
      if (partial.existsSync()) partial.deleteSync();
    }
    _emit(
      LocalBackendInstallStage.download,
      'completed',
      'Downloaded and verified NeoRecall',
      progress: 0.38,
    );
    return target;
  }

  Map<String, dynamic>? _newestAsset(
    List<dynamic> releases,
    LocalBackendChannel channel,
  ) {
    List<int>? newest;
    Map<String, dynamic>? chosen;
    for (final release in releases.cast<Map<String, dynamic>>()) {
      if (release['draft'] == true) continue;
      if (channel == LocalBackendChannel.stable &&
          release['prerelease'] == true) {
        continue;
      }
      final match = RegExp(
        r'^v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$',
      ).firstMatch('${release['tag_name']}');
      if (match == null) continue;
      // A final release sorts after every beta of the same version.
      final version = <int>[
        for (var group = 1; group <= 3; group++) int.parse(match.group(group)!),
        int.tryParse(match.group(4) ?? '') ?? 1 << 30,
      ];
      if (newest != null && !_isNewer(version, newest)) continue;
      for (final asset
          in (release['assets'] as List).cast<Map<String, dynamic>>()) {
        if (asset['name'] == _assetName) {
          newest = version;
          chosen = asset;
        }
      }
    }
    return chosen;
  }

  bool _isNewer(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  Future<void> _runStreaming({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required LocalBackendInstallStage stage,
    required double progressFrom,
    required double progressTo,
    required String failureCode,
    required String failureMessage,
  }) async {
    _throwIfCancelled();
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: _environment,
    );
    _process = process;
    final output = <String>[];
    var emitted = 0;
    void handle(String line) {
      final text = line.trim();
      if (text.isEmpty) return;
      output.add(text);
      if (output.length > 200) output.removeAt(0);
      // The CLI reports no percentage, so each line nudges the bar
      // toward the end of this stage without ever passing it.
      emitted += 1;
      final span = progressTo - progressFrom;
      final progress = progressFrom + span * (1 - 1 / (1 + emitted / 12));
      _emit(stage, 'progress', _humanize(text), progress: progress);
    }

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handle)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handle)
        .asFuture<void>();
    final exitCode = await process.exitCode;
    await stdoutDone;
    await stderrDone;
    _process = null;
    _throwIfCancelled();
    if (exitCode != 0) {
      final detail = output.isEmpty ? '' : ' ${output.last}';
      throw LocalBackendInstallerException(
        failureCode,
        '$failureMessage$detail',
      );
    }
  }

  /// CLI lines already read as sentences; this only strips the log prefixes so
  /// the panel does not show `[neorecall] ✓ …`.
  String _humanize(String line) {
    var text = line.replaceFirst(RegExp(r'^\[neorecall\]\s*'), '');
    text = text.replaceFirst(RegExp(r'^[✓✗✕!•○→]\s*'), '');
    return text.length > 160 ? '${text.substring(0, 157)}…' : text;
  }

  Future<String> _waitForServer(int port) async {
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      while (DateTime.now().isBefore(deadline)) {
        _throwIfCancelled();
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port/health'),
          );
          final response = await request.close();
          final body = await response.transform(utf8.decoder).join();
          final decoded = jsonDecode(body);
          if (response.statusCode == 200 &&
              decoded is Map &&
              decoded['status'] == 'ok') {
            return decoded['version']?.toString() ?? 'unknown';
          }
        } on Object {
          // The service is still starting; retry until the deadline.
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } finally {
      client.close(force: true);
    }
    throw LocalBackendInstallerException(
      'SETUP_SERVER_UNREACHABLE',
      'NeoRecall was installed, but the service did not answer on port $port.',
      remedy:
          'Open a terminal and run "neorecall status" and "neorecall logs" '
          'to see what the service reported.',
    );
  }

  int _configuredPort() {
    final envFile = File('${_runtimeHome()}${Platform.pathSeparator}.env');
    final fromEnvironment = int.tryParse(
      _environment['NEORECALL_PORT']?.trim() ?? '',
    );
    if (fromEnvironment != null) return fromEnvironment;
    if (!envFile.existsSync()) return _defaultPort;
    for (final line in envFile.readAsLinesSync()) {
      final match = RegExp(
        r'^\s*NEORECALL_PORT\s*=\s*"?(\d{2,5})"?\s*$',
      ).firstMatch(line);
      if (match != null) return int.parse(match.group(1)!);
    }
    return _defaultPort;
  }

  /// Where the server keeps its runtime data, mirroring the CLI's own
  /// `NEORECALL_HOME` override.
  String _runtimeHome() {
    final configured = _environment['NEORECALL_HOME']?.trim() ?? '';
    if (configured.isNotEmpty) {
      return configured.startsWith('~')
          ? '${_homeDirectory()}${configured.substring(1)}'
          : configured;
    }
    final home = _homeDirectory();
    return home.isEmpty
        ? '.neorecall'
        : '$home${Platform.pathSeparator}.neorecall';
  }

  String _homeDirectory() {
    final environment = _environment;
    return (Platform.isWindows
            ? environment['USERPROFILE']
            : environment['HOME']) ??
        '';
  }

  /// The sandbox sets this for every process it contains.
  bool get _isSandboxed =>
      Platform.isMacOS &&
      (Platform.environment['APP_SANDBOX_CONTAINER_ID']?.isNotEmpty ?? false);

  void _emit(
    LocalBackendInstallStage stage,
    String state,
    String message, {
    double? progress,
    String? errorCode,
    bool retryable = true,
  }) {
    if (_events.isClosed) return;
    _events.add(
      LocalBackendInstallEvent(
        stage: stage,
        state: state,
        message: message,
        progress: progress,
        errorCode: errorCode,
        retryable: retryable,
      ),
    );
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw const LocalBackendInstallerException(
        'SETUP_CANCELLED',
        'Setup was cancelled.',
      );
    }
  }

  void cancel() {
    _cancelled = true;
    _process?.kill(ProcessSignal.sigterm);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    cancel();
    _http.close();
    unawaited(_events.close());
  }
}
