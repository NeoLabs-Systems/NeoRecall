import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
    if (_isSandboxed) {
      throw const LocalBackendInstallerException(
        'SETUP_APP_SANDBOX',
        'This build of NeoRecall runs in the macOS App Sandbox, which cannot '
            'install a server: it redirects the home directory into the app '
            'container and blocks git, npm, and the background service.',
        retryable: false,
        remedy: 'Install from a terminal instead:\n'
            'bash <(curl -fsSL https://raw.githubusercontent.com/'
            'NeoLabs-Systems/NeoRecall/main/install.sh)',
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

      // Created before the service starts so the server reads it at boot; this
      // is what lets the app configure providers without the admin dashboard.
      final adminApiKey = await _ensureAdminApiKey(node, directory.path);
      _emit(
        LocalBackendInstallStage.install,
        adminApiKey == null ? 'warning' : 'progress',
        adminApiKey == null
            ? 'The administrator key could not be created; provider setup will '
                  'have to happen in the admin dashboard.'
            : 'Administrator key ready',
        progress: 0.66,
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
        adminApiKey: adminApiKey,
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

  /// Asks the CLI for the administrator API key, which it creates on first use.
  /// Deliberately not streamed into the event log: the key is a secret and the
  /// log is shown on screen.
  Future<String?> _ensureAdminApiKey(String node, String sourceDirectory) async {
    try {
      final result = await Process.run(
        node,
        <String>[
          '$sourceDirectory${Platform.pathSeparator}bin'
              '${Platform.pathSeparator}neorecall.js',
          'admin-key',
          '--json',
        ],
        workingDirectory: sourceDirectory,
        environment: _childEnvironment(),
      );
      if (result.exitCode != 0) return null;
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        if (!line.trim().startsWith('{')) continue;
        final decoded = jsonDecode(line.trim());
        if (decoded is Map && decoded['adminApiKey'] is String) {
          final key = (decoded['adminApiKey'] as String).trim();
          if (key.isNotEmpty) return key;
        }
      }
      return null;
    } on Object {
      return null;
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
      // Updating means reset --hard and clean -fd. That is right for an install
      // directory and ruinous for a working checkout, which is easy to pick by
      // accident when a developer's clone sits at the default path. Refuse
      // anything holding work that this would destroy.
      final dirty = await _runQuiet(git, <String>[
        '-C',
        directory.path,
        'status',
        '--porcelain',
      ]);
      if ('${dirty?.stdout ?? ''}'.trim().isNotEmpty) {
        throw LocalBackendInstallerException(
          'SETUP_CHECKOUT_DIRTY',
          '${directory.path} has uncommitted changes.',
          retryable: false,
          remedy: 'Installing here would discard them. Commit or stash them '
              'first, or choose a different install directory.',
        );
      }
      final published = await _runQuiet(git, <String>[
        '-C',
        directory.path,
        'branch',
        '--remotes',
        '--contains',
        'HEAD',
      ]);
      if (published != null &&
          published.exitCode == 0 &&
          '${published.stdout}'.trim().isEmpty) {
        throw LocalBackendInstallerException(
          'SETUP_CHECKOUT_UNPUSHED',
          '${directory.path} holds commits that are not on any remote branch.',
          retryable: false,
          remedy: 'Installing here would discard them. Push them first, or '
              'choose a different install directory.',
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
    final envFile = File(
      '${_runtimeHome()}${Platform.pathSeparator}.env',
    );
    final fromEnvironment = int.tryParse(
      Platform.environment['NEORECALL_PORT']?.trim() ?? '',
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
    final configured = Platform.environment['NEORECALL_HOME']?.trim() ?? '';
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
    final environment = Platform.environment;
    return (Platform.isWindows
            ? environment['USERPROFILE']
            : environment['HOME']) ??
        '';
  }

  /// A window-server launch gives the app a minimal PATH, so every child
  /// process gets the resolved tool directories added back.
  Map<String, String> _childEnvironment({
    Iterable<String> extraDirectories = const <String>[],
  }) {
    final environment = Map<String, String>.from(Platform.environment);
    final separator = Platform.isWindows ? ';' : ':';
    final directories = <String>{
      ...extraDirectories,
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
    for (final path in _existingPaths(lookup)) {
      if (await _runs(path)) return path;
    }

    if (!Platform.isWindows) {
      // Apps launched from Finder or a .desktop entry inherit a minimal PATH,
      // so ask the login shell where the tool actually lives.
      final shell = Platform.environment['SHELL'] ?? '/bin/sh';
      final viaShell = await _runQuiet(shell, <String>[
        '-lc',
        'command -v $command',
      ]);
      for (final path in _existingPaths(viaShell)) {
        if (await _runs(path)) return path;
      }

      // nvm, fnm and asdf define their shims in .zshrc or .bashrc, which a
      // non-interactive shell never reads, so the login lookup above cannot see
      // them however correct the user's setup is.
      final viaInteractiveShell = await _runQuiet(shell, <String>[
        '-ilc',
        'command -v $command',
      ]);
      for (final path in _existingPaths(viaInteractiveShell)) {
        if (await _runs(path)) return path;
      }
    }

    for (final candidate in _candidatePaths(command)) {
      if (File(candidate).existsSync() && await _runs(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether the file at this path is the working tool and not a stand-in for
  /// one. `/usr/bin/git` exists on every Mac but is an Xcode shim: without the
  /// command line tools installed it only prints an error, and treating it as
  /// Git would fail the install halfway through instead of up front.
  ///
  /// The probe runs with the tool's own directory on PATH. npm is a script that
  /// begins `#!/usr/bin/env node`, and a window-server launch hands the app a
  /// PATH with neither on it -- probed bare, a perfectly good npm reports
  /// `env: node: No such file or directory` and would be called missing.
  @visibleForTesting
  Future<bool> probeExecutable(String path) => _runs(path);

  Future<bool> _runs(String path) async {
    final probe = await _runQuiet(
      path,
      <String>['--version'],
      environment: _childEnvironment(
        extraDirectories: <String>[File(path).parent.path],
      ),
    );
    return probe != null && probe.exitCode == 0;
  }

  List<String> _existingPaths(ProcessResult? result) {
    if (result == null || result.exitCode != 0) return const <String>[];
    return <String>[
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (line.trim().isNotEmpty && File(line.trim()).existsSync()) line.trim(),
    ];
  }

  /// The sandbox sets this for every process it contains.
  bool get _isSandboxed =>
      Platform.isMacOS &&
      (Platform.environment['APP_SANDBOX_CONTAINER_ID']?.isNotEmpty ?? false);

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
      // Apple ships git only through /usr/bin/git, which is a shim: it refuses
      // to run when the command line tools are absent, and equally when Xcode
      // is installed but its licence has not been accepted. The tools it stands
      // in for work in both cases, so reach them directly.
      if (Platform.isMacOS) ...<String>[
        '/Library/Developer/CommandLineTools/usr/bin/$command',
        '/Applications/Xcode.app/Contents/Developer/usr/bin/$command',
      ],
      if (home.isNotEmpty) ...<String>[
        '$home/.volta/bin/$command',
        '$home/.local/bin/$command',
        '$home/.nix-profile/bin/$command',
        '$home/.asdf/shims/$command',
        ..._versionManagerPaths(home, command),
      ],
    ];
  }

  /// Node installed through a version manager lives under a directory named for
  /// the version, so the newest one is tried first.
  List<String> _versionManagerPaths(String home, String command) {
    const roots = <String, String>{
      '.nvm/versions/node': 'bin',
      '.fnm/node-versions': 'installation/bin',
      '.local/share/fnm/node-versions': 'installation/bin',
      'n/bin': '',
    };
    final paths = <String>[];
    for (final entry in roots.entries) {
      final root = Directory('$home/${entry.key}');
      if (!root.existsSync()) continue;
      if (entry.value.isEmpty) {
        paths.add('${root.path}/$command');
        continue;
      }
      final versions =
          root.listSync().whereType<Directory>().toList(growable: false)
            ..sort((a, b) => b.path.compareTo(a.path));
      for (final version in versions) {
        paths.add('${version.path}/${entry.value}/$command');
      }
    }
    return paths;
  }

  Future<ProcessResult?> _runQuiet(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    try {
      return await Process.run(
        executable,
        arguments,
        environment: environment,
      ).timeout(const Duration(seconds: 20));
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
