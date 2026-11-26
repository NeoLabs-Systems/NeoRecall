import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neorecall/src/install/local_backend_installer.dart';

const List<String> _assetNames = <String>[
  'neorecall-cli-linux-x64',
  'neorecall-cli-linux-arm64',
  'neorecall-cli-macos-x64',
  'neorecall-cli-macos-arm64',
];

/// A stand-in `neorecall` that records its arguments and fails, so the test
/// stops before waiting for a server.
const String _binary =
    '#!/bin/sh\necho "\$@" > "\$NEORECALL_BIN_DIR/args"\necho stub stopped\nexit 3\n';

Map<String, Object> _release(
  String tag, {
  required String digest,
  bool prerelease = true,
  bool draft = false,
}) => <String, Object>{
  'tag_name': tag,
  'prerelease': prerelease,
  'draft': draft,
  'assets': <Map<String, String>>[
    for (final name in _assetNames)
      <String, String>{
        'name': name,
        'browser_download_url': 'https://example.test/$tag/$name',
        'digest': digest,
      },
  ],
};

void main() {
  late Directory bin;
  final digest = 'sha256:${sha256.convert(utf8.encode(_binary))}';

  setUp(() => bin = Directory.systemTemp.createTempSync('neorecall-install-'));
  tearDown(() => bin.deleteSync(recursive: true));

  LocalBackendInstaller installer(
    List<Map<String, Object>> releases,
    List<String> downloads,
  ) {
    final subject = LocalBackendInstaller(
      releases: Uri.parse('https://example.test/releases'),
      environment: <String, String>{
        'NEORECALL_BIN_DIR': bin.path,
        'PATH': Platform.environment['PATH'] ?? '',
      },
      client: MockClient((request) async {
        if (request.url.path == '/releases') {
          return http.Response(jsonEncode(releases), 200);
        }
        downloads.add(request.url.path);
        return http.Response(_binary, 200);
      }),
    );
    addTearDown(subject.dispose);
    return subject;
  }

  Matcher failsWith(String code) => throwsA(
    isA<LocalBackendInstallerException>().having((e) => e.code, 'code', code),
  );

  test(
    'downloads the newest release and runs its install command',
    () async {
      final downloads = <String>[];
      final subject = installer(<Map<String, Object>>[
        _release('v0.1.4-beta.9', digest: digest),
        _release('v0.1.4-beta.22', digest: digest),
        _release('v0.1.4-beta.23', digest: digest, draft: true),
      ], downloads);

      await expectLater(
        subject.install(channel: LocalBackendChannel.beta),
        failsWith('SETUP_INSTALL_FAILED'),
      );
      expect(downloads.single, startsWith('/v0.1.4-beta.22/'));
      expect(
        File('${bin.path}/args').readAsStringSync().trim(),
        'install --channel beta',
      );
    },
    skip: Platform.isWindows,
  );

  test('a checksum mismatch installs nothing', () async {
    final subject = installer(<Map<String, Object>>[
      _release('v1.0.0', digest: 'sha256:00', prerelease: false),
    ], <String>[]);

    await expectLater(
      subject.install(channel: LocalBackendChannel.stable),
      failsWith('SETUP_CHECKSUM_MISMATCH'),
    );
    expect(bin.listSync(), isEmpty);
  }, skip: Platform.isWindows);

  test('stable never installs a beta', () async {
    final downloads = <String>[];
    final subject = installer(<Map<String, Object>>[
      _release('v0.1.4-beta.22', digest: digest),
    ], downloads);

    await expectLater(
      subject.install(channel: LocalBackendChannel.stable),
      failsWith('SETUP_RELEASE_UNAVAILABLE'),
    );
    expect(downloads, isEmpty);
  }, skip: Platform.isWindows);
}
