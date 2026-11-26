/// Release channel the local install tracks: the same two channels the CLI
/// persists in `~/.neorecall/.env`.
enum LocalBackendChannel { stable, beta }

extension LocalBackendChannelNames on LocalBackendChannel {
  String get cliName => this == LocalBackendChannel.beta ? 'beta' : 'stable';
}

/// Ordered stages of a local install. The UI shows the current stage message;
/// the progress bar uses the fractions the installer emits with each event.
enum LocalBackendInstallStage {
  prepare,
  download,
  verify,
  install,
  service,
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
    required this.commandPath,
    required this.channel,
    required this.serverVersion,
  });

  final String backendUrl;

  /// The installed server binary, which is also the command line tool.
  final String commandPath;
  final LocalBackendChannel channel;
  final String serverVersion;
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
