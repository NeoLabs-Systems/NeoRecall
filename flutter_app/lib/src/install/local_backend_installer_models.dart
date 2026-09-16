/// Release channel the local install tracks. `stable` follows the `main`
/// branch, `beta` follows `beta` — the same two channels the CLI persists in
/// `~/.neorecall/.env`.
enum LocalBackendChannel { stable, beta }

extension LocalBackendChannelNames on LocalBackendChannel {
  String get cliName => this == LocalBackendChannel.beta ? 'beta' : 'stable';
  String get gitBranch => this == LocalBackendChannel.beta ? 'beta' : 'main';
}

/// Ordered stages of a local install. The UI shows the current stage message;
/// the progress bar uses the fractions the installer emits with each event.
enum LocalBackendInstallStage {
  prepare,
  download,
  dependencies,
  link,
  install,
  connect,
  complete,
}

class LocalBackendInstallEvent {
  const LocalBackendInstallEvent({
    required this.stage,
    required this.state,
    required this.message,
    this.progress,
    this.errorCode,
    this.retryable = true,
  });

  final LocalBackendInstallStage stage;

  /// `started`, `progress`, `completed`, `warning`, `message`, or `failed`.
  final String state;
  final String message;
  final double? progress;
  final String? errorCode;
  final bool retryable;

  bool get isFailure => state == 'failed';
  bool get isWarning => state == 'warning';
  bool get isCompleted => state == 'completed';
}

class LocalBackendInstallResult {
  const LocalBackendInstallResult({
    required this.backendUrl,
    required this.sourceDirectory,
    required this.channel,
    required this.serverVersion,
    this.adminApiKey,
    this.cliLinked = true,
  });

  final String backendUrl;
  final String sourceDirectory;
  final LocalBackendChannel channel;
  final String serverVersion;

  /// The server's administrator API key, read from `~/.neorecall/.env`. It lets
  /// this app configure transcription and language-model services without the
  /// admin web dashboard. Null when the key could not be read.
  final String? adminApiKey;

  /// False when the global `neorecall` command could not be linked. The server
  /// still runs; only the terminal shortcut is missing.
  final bool cliLinked;
}

class LocalBackendInstallerException implements Exception {
  const LocalBackendInstallerException(
    this.code,
    this.message, {
    this.retryable = true,
    this.remedy,
  });

  final String code;
  final String message;
  final bool retryable;

  /// A concrete next step the person can take, shown under the error.
  final String? remedy;

  @override
  String toString() => message;
}

/// A prerequisite command the installer needs on the host.
class LocalBackendRequirement {
  const LocalBackendRequirement({
    required this.command,
    required this.label,
    required this.downloadUrl,
  });

  final String command;
  final String label;
  final String downloadUrl;
}

const List<LocalBackendRequirement> localBackendRequirements =
    <LocalBackendRequirement>[
      LocalBackendRequirement(
        command: 'git',
        label: 'Git',
        downloadUrl: 'https://git-scm.com/downloads',
      ),
      LocalBackendRequirement(
        command: 'node',
        label: 'Node.js 20+',
        downloadUrl: 'https://nodejs.org',
      ),
      LocalBackendRequirement(
        command: 'npm',
        label: 'npm',
        downloadUrl: 'https://nodejs.org',
      ),
    ];
