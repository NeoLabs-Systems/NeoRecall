import 'local_backend_installer_models.dart';

/// Web builds are served by a running NeoRecall server, so there is nothing
/// for them to install.
const bool supportsLocalBackendInstall = false;

class LocalBackendInstaller {
  LocalBackendInstaller({Object? client});

  Stream<LocalBackendInstallEvent> get events =>
      const Stream<LocalBackendInstallEvent>.empty();

  Future<LocalBackendInstallResult> install({
    required LocalBackendChannel channel,
  }) {
    throw const LocalBackendInstallerException(
      'SETUP_PLATFORM_UNSUPPORTED',
      'Installing NeoRecall on this computer is not available on this platform.',
      retryable: false,
    );
  }

  void cancel() {}

  void dispose() {}
}
