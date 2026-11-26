import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:neolabs_flutter/installer.dart';

import 'local_backend_installer_models.dart';
import 'local_runtime_app.dart';

/// Desktop hosts can run the NeoRecall server themselves.
final bool supportsLocalBackendInstall =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

const int _defaultPort = 4500;

/// Runs the shared NeoLabs runtime installer, then `neorecall install` from the
/// verified runtime, and waits for the service to answer.
class LocalBackendInstaller {
  LocalBackendInstaller({http.Client? client}) {
    _runtime = NeoRuntimeInstaller(
      app: neoRecallRuntimeApp,
      client: client,
      onEvent: (event) {
        // The server is only ready once its service answers, which is later.
        if (event.stage == NeoInstallStage.complete) return;
        _add(
          LocalBackendInstallEvent(
            stage: LocalBackendInstallStage.values.byName(event.stage.name),
            state: event.state,
            message: event.message,
            progress: event.progress,
            errorCode: event.errorCode,
            retryable: event.retryable,
          ),
        );
      },
    );
  }

  late final NeoRuntimeInstaller _runtime;
  final Map<String, String> _environment = Platform.environment;
  final StreamController<LocalBackendInstallEvent> _events =
      StreamController<LocalBackendInstallEvent>.broadcast();
  Process? _process;

  Stream<LocalBackendInstallEvent> get events => _events.stream;

  Future<LocalBackendInstallResult> install({
    required LocalBackendChannel channel,
  }) async {
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
    final home = _runtimeHome();
    final environment = <String, String>{
      ..._environment,
      'NEORECALL_HOME': home,
    };
    try {
      return await _runtime.install(
        channel: channel.cliName,
        runtimeHome: Directory(home),
        environment: environment,
        rollbackArguments: (hasPrevious) => <String>[
          hasPrevious ? 'repair' : 'stop',
        ],
        configure: (version, executable) async {
          await _runStreaming(
            executable: executable.path,
            arguments: <String>['install', '--channel', channel.cliName],
            workingDirectory: '${version.path}${Platform.pathSeparator}app',
            environment: environment,
          );
          final port = _configuredPort();
          final backendUrl = 'http://localhost:$port';
          _add(
            LocalBackendInstallEvent(
              stage: LocalBackendInstallStage.connect,
              state: 'started',
              message: 'Waiting for the NeoRecall service on port $port',
              progress: 0.94,
            ),
          );
          final serverVersion = await _waitForServer(port);
          _add(
            LocalBackendInstallEvent(
              stage: LocalBackendInstallStage.complete,
              state: 'completed',
              message: 'NeoRecall is running at $backendUrl',
              progress: 1,
            ),
          );
          return LocalBackendInstallResult(
            backendUrl: backendUrl,
            commandPath: executable.path,
            channel: channel,
            serverVersion: serverVersion,
          );
        },
      );
    } on NeoInstallerException catch (error) {
      throw LocalBackendInstallerException(
        error.code,
        error.message,
        retryable: error.retryable,
      );
    }
  }

  Future<void> _runStreaming({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
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
      _emit(
        LocalBackendInstallStage.service,
        'progress',
        _humanize(text),
        progress: 0.72 + 0.2 * (1 - 1 / (1 + emitted / 12)),
      );
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
    if (_runtime.cancelled) {
      throw const LocalBackendInstallerException(
        'SETUP_CANCELLED',
        'Setup was cancelled.',
      );
    }
    if (exitCode != 0) {
      final detail = output.isEmpty ? '' : ' ${output.last}';
      throw LocalBackendInstallerException(
        'SETUP_INSTALL_FAILED',
        'NeoRecall could not finish installing on this computer.$detail',
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
        _runtime.throwIfCancelled();
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

  void _add(LocalBackendInstallEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _emit(
    LocalBackendInstallStage stage,
    String state,
    String message, {
    double? progress,
  }) => _add(
    LocalBackendInstallEvent(
      stage: stage,
      state: state,
      message: message,
      progress: progress,
    ),
  );

  void cancel() {
    _runtime.cancel();
    _process?.kill(ProcessSignal.sigterm);
  }

  void dispose() {
    cancel();
    _runtime.dispose();
    unawaited(_events.close());
  }
}
