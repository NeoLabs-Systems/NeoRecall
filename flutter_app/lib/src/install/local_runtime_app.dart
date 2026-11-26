import 'package:neolabs_flutter/installer.dart';

/// What the shared NeoLabs installer needs to know about NeoRecall. The key is
/// `internal/signing/public_key.txt` and the targets are the release's runtime
/// bundles.
const NeoRuntimeApp neoRecallRuntimeApp = NeoRuntimeApp(
  name: 'NeoRecall',
  command: 'neorecall',
  repository: 'NeoLabs-Systems/NeoRecall',
  publicKey: String.fromEnvironment(
    'NEORECALL_RUNTIME_PUBLIC_KEY',
    defaultValue:
        'MCowBQYDK2VwAyEAXPVQlFsa1unXhM8Q8YuPaFbyb49u15d3fQLXWtGz0XA=',
  ),
  targets: <String, List<String>>{
    'linux': <String>['x64', 'arm64'],
    'macos': <String>['x64', 'arm64'],
    'windows': <String>['x64'],
  },
  webIndex: <String>['flutter_app', 'build', 'web', 'index.html'],
  strings: _installText,
);

String _installText(NeoInstallText text) => switch (text) {
  NeoInstallText.finding => 'Looking up the latest NeoRecall release',
  NeoInstallText.downloading => 'Downloading NeoRecall',
  NeoInstallText.verifying => 'Verifying the download',
  NeoInstallText.extracting => 'Unpacking NeoRecall',
  NeoInstallText.usingInstalled => 'This version is already downloaded',
  NeoInstallText.ready => 'NeoRecall is ready',
  NeoInstallText.cancelled => 'Setup was cancelled.',
  NeoInstallText.disposed => 'The installer is no longer available.',
  NeoInstallText.unsupportedPlatform =>
    'There is no NeoRecall server build for this computer.',
  NeoInstallText.insecureDownload =>
    'NeoRecall downloads require a secure address.',
  NeoInstallText.releaseLookupFailed => 'Could not check GitHub releases.',
  NeoInstallText.releaseListInvalid =>
    'The release list from GitHub could not be read.',
  NeoInstallText.notPublished =>
    'No release on this channel has a NeoRecall server build yet.',
  NeoInstallText.assetMissing =>
    'The release is missing the build for this computer.',
  NeoInstallText.downloadFailed => 'Could not download NeoRecall.',
  NeoInstallText.downloadIncomplete => 'The download was incomplete.',
  NeoInstallText.metadataTooLarge => 'A release file was unexpectedly large.',
  NeoInstallText.trustNotConfigured =>
    'This build cannot verify NeoRecall releases.',
  NeoInstallText.signatureInvalid =>
    'The release signature did not verify; nothing was installed.',
  NeoInstallText.manifestInvalid => 'The release manifest is invalid.',
  NeoInstallText.hashMismatch =>
    'The download did not match its checksum; nothing was installed.',
  NeoInstallText.archiveInvalid => 'The download could not be unpacked.',
  NeoInstallText.archiveUnsafe => 'The download holds unsafe file paths.',
  NeoInstallText.runtimeIncomplete => 'The download is missing server files.',
  NeoInstallText.restoring => 'Restoring the previous version',
  NeoInstallText.rollbackIncomplete =>
    'The previous version could not be restarted; run the setup again.',
};
