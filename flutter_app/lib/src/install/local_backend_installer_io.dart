import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_backend_installer_models.dart';

/// Desktop hosts can run the NeoRecall server themselves.
final bool supportsLocalBackendInstall =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

const String _repositoryUrl =
    'https://github.com/NeoLabs-Systems/NeoRecall.git';
const int _defaultPort = 4500;

/// Installs NeoRecall on this computer the same way `install.sh` does: clone the
/// channel branch, install dependencies, link the global CLI, then run
/// `neorecall install` and wait for the service to answer.
class LocalBackendInstaller {
  final StreamController<LocalBackendInstallEvent> _events =
      StreamController<LocalBackendInstallEvent>.broadcast();
  final Map<String, String?> _resolvedExecutables = <String, String?>{};
  Process? _process;
  bool _cancelled = false;
  bool _disposed = false;

  Stream<LocalBackendInstallEvent> get events => _events.stream;

  String get defaultInstallDirectory {
    final home = _homeDirectory();
    return home.isEmpty
        ? 'NeoRecall'
        : '$home${Platform.pathSeparator}NeoRecall';
  }

  /// Prerequisites the host is missing, in the order they are listed to the
  /// person. An empty list means the install can start.
  Future<List<LocalBackendRequirement>> missingRequirements() async {
    final missing = <LocalBackendRequirement>[];
    for (final requirement in localBackendRequirements) {
      if (await _resolveExecutable(requirement.command) == null) {
        missing.add(requirement);
      }
    }
    return missing;
  }

  Future<LocalBackendInstallResult> install({
    required LocalBackendChannel channel,
    String? installDirectory,
  }) async {
    if (_disposed) {
      throw const LocalBackendInstallerException(
        'SETUP_INSTALLER_DISPOSED',
        'The installer is no longer available.',
        retryable: false,
      );
    }
    if (!supportsLocalBackendInstall) {
      throw const LocalBackendInstallerException(
        'SETUP_PLATFORM_UNSUPPORTED',
        'Installing NeoRecall on this computer is not available on this platform.',
        retryable: false,
      );
    }
    _cancelled = false;
    final directory = Directory(
      (installDirectory?.trim().isNotEmpty ?? false)
          ? installDirectory!.trim()
          : defaultInstallDirectory,
    );

    try {
      _emit(
        LocalBackendInstallStage.prepare,
        'started',
        'Checking Git, Node.js, and npm',
        progress: 0.02,
      );
      final missing = await missingRequirements();
      if (missing.isNotEmpty) {
        throw LocalBackendInstallerException(
          'SETUP_REQUIREMENTS_MISSING',
          'Install ${missing.map((item) => item.label).join(', ')} first, then '
              'start the setup again.',
          retryable: false,
          remedy: missing.map((item) => item.downloadUrl).join('\n'),
        );
      }
      final git = (await _resolveExecutable('git'))!;
      final npm = (await _resolveExecutable('npm'))!;
      final node = (await _resolveExecutable('node'))!;
      _emit(
        LocalBackendInstallStage.prepare,
        'completed',
        'Git, Node.js, and npm are ready',
        progress: 0.06,
      );

      await _prepareCheckout(
        git: git,
        directory: directory,
        channel: channel,
      );
      _throwIfCancelled();

      _emit(
        LocalBackendInstallStage.dependencies,
        'started',
        'Installing NeoRecall dependencies',
        progress: 0.32,
      );
      await _runStreaming(
        executable: npm,
        arguments: <String>['install', '--omit=dev', '--no-audit', '--no-fund'],
        workingDirectory: directory.path,
        stage: LocalBackendInstallStage.dependencies,
        progressFrom: 0.32,
        progressTo: 0.55,
        failureCode: 'SETUP_DEPENDENCIES_FAILED',
        failureMessage: 'NeoRecall could not install its dependencies.',
      );
      _emit(
        LocalBackendInstallStage.dependencies,
        'completed',
        'Dependencies installed',
        progress: 0.56,
      );
      _throwIfCancelled();

      _emit(
        LocalBackendInstallStage.link,
        'started',
        'Linking the neorecall command',
        progress: 0.58,
      );
      // A missing global link only costs the terminal shortcut, so a failure
      // here is reported and the install continues.
      var cliLinked = true;
      try {
        await _runStreaming(
          executable: npm,
          arguments: <String>[
            'link',
            '--ignore-scripts',
            '--no-audit',
            '--no-fund',
          ],
          workingDirectory: directory.path,
          stage: LocalBackendInstallStage.link,
          progressFrom: 0.58,
          progressTo: 0.62,
          failureCode: 'SETUP_LINK_FAILED',
          failureMessage: 'Could not link the global neorecall command.',
        );
        _emit(
          LocalBackendInstallStage.link,
          'completed',
          'The neorecall command is available in a terminal',
          progress: 0.63,
        );
      } on LocalBackendInstallerException {
        cliLinked = false;
        _emit(
          LocalBackendInstallStage.link,
          'warning',
          'The neorecall terminal command could not be linked; NeoRecall itself '
              'will still be installed.',
          progress: 0.63,
        );
      }
      _throwIfCancelled();

      await _runStreaming(
        executable: node,
        arguments: <String>[
          '${directory.path}${Platform.pathSeparator}bin'
              '${Platform.pathSeparator}neorecall.js',
          'channel',
          channel.cliName,
        ],
        workingDirectory: directory.path,
        stage: LocalBackendInstallStage.install,
        progressFrom: 0.64,
        progressTo: 0.66,
        failureCode: 'SETUP_CHANNEL_FAILED',
        failureMessage: 'Could not store the ${channel.cliName} release channel.',
      );

      _emit(
        LocalBackendInstallStage.install,
        'started',
        'Preparing models, database, and the background service',
        progress: 0.67,
      );
      await _runStreaming(
        executable: node,
        arguments: <String>[
          '${directory.path}${Platform.pathSeparator}bin'
              '${Platform.pathSeparator}neorecall.js',
          'install',
        ],
        workingDirectory: directory.path,
        stage: LocalBackendInstallStage.install,
        progressFrom: 0.67,
        progressTo: 0.92,
        failureCode: 'SETUP_INSTALL_FAILED',
        failureMessage: 'NeoRecall could not finish installing on this computer.',
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
        sourceDirectory: directory.path,
        channel: channel,
        serverVersion: version,
        cliLinked: cliLinked,
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

  Future<void> _prepareCheckout({
    required String git,
    required Directory directory,
    required LocalBackendChannel channel,
  }) async {
    final branch = channel.gitBranch;
    final isCheckout = Directory(
      '${directory.path}${Platform.pathSeparator}.git',
    ).existsSync();
    if (isCheckout) {
      // Resetting a checkout discards whatever is in it, so refuse anything
      // that is not this repository.
      final origin = await _runQuiet(git, <String>[
        '-C',
        directory.path,
        'remote',
        'get-url',
        'origin',
      ]);
      if (!_isCanonicalRemote('${origin?.stdout ?? ''}')) {
        throw LocalBackendInstallerException(
          'SETUP_DIRECTORY_OCCUPIED',
          '${directory.path} is a Git repository, but not a NeoRecall checkout.',
          retryable: false,
          remedy: 'Choose a different install directory and start the setup '
              'again.',
        );
      }
      _emit(
        LocalBackendInstallStage.download,
        'started',
        'Updating the existing checkout in ${directory.path}',
        progress: 0.08,
      );
      for (final arguments in <List<String>>[
        <String>['fetch', 'origin', '--tags', '--force'],
        <String>['reset', '--hard', 'HEAD'],
        <String>['clean', '-fd'],
        <String>['checkout', '-B', branch, 'origin/$branch'],
        <String>['reset', '--hard', 'origin/$branch'],
      ]) {
        await _runStreaming(
          executable: git,
          arguments: arguments,
          workingDirectory: directory.path,
          stage: LocalBackendInstallStage.download,
          progressFrom: 0.08,
          progressTo: 0.3,
          failureCode: 'SETUP_CHECKOUT_FAILED',
          failureMessage:
              'Could not update the NeoRecall checkout in ${directory.path}.',
        );
      }
    } else {
      if (directory.existsSync() && directory.listSync().isNotEmpty) {
        throw LocalBackendInstallerException(
          'SETUP_DIRECTORY_OCCUPIED',
          '${directory.path} already exists and is not a NeoRecall checkout.',
          retryable: false,
          remedy: 'Choose a different install directory, or move that folder '
              'somewhere else and start the setup again.',
        );
      }
      _emit(
        LocalBackendInstallStage.download,
        'started',
        'Downloading NeoRecall (${channel.cliName}) into ${directory.path}',
        progress: 0.08,
      );
      final parent = directory.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      try {
        await _runStreaming(
          executable: git,
          arguments: <String>[
            'clone',
            '--branch',
            branch,
            _repositoryUrl,
            directory.path,
          ],
          workingDirectory: parent.path,
          stage: LocalBackendInstallStage.download,
          progressFrom: 0.08,
          progressTo: 0.3,
          failureCode: 'SETUP_CLONE_FAILED',
          failureMessage: 'Could not download NeoRecall from GitHub.',
        );
      } on Object {
        // A half-written clone would look like an occupied directory on the
        // next attempt, so remove it unless git left a usable repository.
        if (directory.existsSync() &&
            !Directory(
              '${directory.path}${Platform.pathSeparator}.git',
            ).existsSync()) {
          directory.deleteSync(recursive: true);
        }
        rethrow;
      }
    }
    _emit(
      LocalBackendInstallStage.download,
      'completed',
      'NeoRecall source ready (${channel.cliName})',
      progress: 0.31,
    );
  }

  bool _isCanonicalRemote(String value) {
    var remote = value.trim();
    if (remote.startsWith('git@github.com:')) {
      remote = 'https://github.com/${remote.substring(15)}';
    } else if (remote.startsWith('ssh://git@github.com/')) {
      remote = 'https://github.com/${remote.substring(21)}';
    }
    String normalize(String input) => input
        .toLowerCase()
        .replaceFirst(RegExp(r'\.git/?$'), '')
        .replaceFirst(RegExp(r'/$'), '');
    return normalize(remote) == normalize(_repositoryUrl);
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
      environment: _childEnvironment(),
    );
    _process = process;
    final output = <String>[];
    var emitted = 0;
    void handle(String line) {
      final text = line.trim();
      if (text.isEmpty) return;
      output.add(text);
      if (output.length > 200) output.removeAt(0);
      // Progress is unknowable for npm and git, so each line nudges the bar
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
    text = text.replaceFirst(RegExp(r'^[✓✗!→]\s*'), '');
    return text.length > 160 ? '${text.substring(0, 157)}…' : text;
  }

  Future<String> _waitForServer(int port) async {
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
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
      remedy: 'Open a terminal and run "neorecall status" and "neorecall logs" '
          'to see what the service reported.',
    );
  }

  int _configuredPort() {
    final home = _homeDirectory();
    if (home.isEmpty) return _defaultPort;
    final envFile = File(
      '$home${Platform.pathSeparator}.neorecall${Platform.pathSeparator}.env',
    );
    if (!envFile.existsSync()) return _defaultPort;
    for (final line in envFile.readAsLinesSync()) {
      final match = RegExp(r'^\s*PORT\s*=\s*"?(\d{2,5})"?\s*$').firstMatch(line);
      if (match != null) return int.parse(match.group(1)!);
    }
    return _defaultPort;
  }

  String _homeDirectory() {
    final environment = Platform.environment;
    return (Platform.isWindows
            ? environment['USERPROFILE']
            : environment['HOME']) ??
        '';
  }

  /// A window-server launch gives the app a minimal PATH, so every child
  /// process gets the resolved tool directories added back.
  Map<String, String> _childEnvironment() {
    final environment = Map<String, String>.from(Platform.environment);
    final separator = Platform.isWindows ? ';' : ':';
    final directories = <String>{
      for (final path in _resolvedExecutables.values)
        if (path != null && path.isNotEmpty) File(path).parent.path,
    };
    if (directories.isEmpty) return environment;
    final key = environment.keys.firstWhere(
      (name) => name.toUpperCase() == 'PATH',
      orElse: () => 'PATH',
    );
    final current = environment[key] ?? '';
    environment[key] = <String>{
      ...directories,
      ...current.split(separator).where((entry) => entry.isNotEmpty),
    }.join(separator);
    return environment;
  }

  Future<String?> _resolveExecutable(String command) async {
    if (_resolvedExecutables.containsKey(command)) {
      return _resolvedExecutables[command];
    }
    final resolved = await _findExecutable(command);
    _resolvedExecutables[command] = resolved;
    return resolved;
  }

  Future<String?> _findExecutable(String command) async {
    final lookup = await _runQuiet(
      Platform.isWindows ? 'where' : 'which',
      <String>[command],
    );
    final direct = _firstExistingPath(lookup);
    if (direct != null) return direct;

    if (!Platform.isWindows) {
      // Apps launched from Finder or a .desktop entry inherit a minimal PATH,
      // so ask the login shell where the tool actually lives.
      final shell = Platform.environment['SHELL'] ?? '/bin/sh';
      final viaShell = await _runQuiet(shell, <String>[
        '-lc',
        'command -v $command',
      ]);
      final shellPath = _firstExistingPath(viaShell);
      if (shellPath != null) return shellPath;
    }

    for (final candidate in _candidatePaths(command)) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _firstExistingPath(ProcessResult? result) {
    if (result == null || result.exitCode != 0) return null;
    for (final line in const LineSplitter().convert('${result.stdout}')) {
      final path = line.trim();
      if (path.isNotEmpty && File(path).existsSync()) return path;
    }
    return null;
  }

  List<String> _candidatePaths(String command) {
    final home = _homeDirectory();
    if (Platform.isWindows) {
      final programFiles =
          Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
      final appData = Platform.environment['APPDATA'] ?? '';
      final suffixes = command == 'npm'
          ? <String>['npm.cmd', 'npm.exe']
          : <String>['$command.exe', '$command.cmd'];
      return <String>[
        for (final suffix in suffixes) ...<String>[
          '$programFiles\\nodejs\\$suffix',
          '$programFiles\\Git\\cmd\\$suffix',
          if (appData.isNotEmpty) '$appData\\npm\\$suffix',
        ],
      ];
    }
    return <String>[
      '/opt/homebrew/bin/$command',
      '/usr/local/bin/$command',
      '/usr/bin/$command',
      '/bin/$command',
      if (home.isNotEmpty) '$home/.volta/bin/$command',
      if (home.isNotEmpty) '$home/.local/bin/$command',
      if (home.isNotEmpty) '$home/.nix-profile/bin/$command',
    ];
  }

  Future<ProcessResult?> _runQuiet(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(executable, arguments);
    } on Object {
      return null;
    }
  }

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
    unawaited(_events.close());
  }
}
