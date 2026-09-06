import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/sync/retained_audio_store.dart';

void main() {
  late Directory root;
  late RetainedAudioStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('neorecall-retained-');
    store = createRetainedAudioStore(rootPath: root.path);
    await store.initialize();
  });

  tearDown(() async {
    await store.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('keeps a clip until the shared keep-days window expires', () async {
    const account = 'account-a';
    await store.retain(
      accountId: account,
      id: 'import-1',
      bytes: Uint8List.fromList(const <int>[1, 2, 3, 4]),
      mimeType: 'audio/ogg',
      filename: 'take.ogg',
      capturedAt: DateTime.utc(2026, 9, 1, 12),
      importId: 'import-1',
    );
    expect(
      await store.hasClips(accountId: account, importIds: <String>['import-1']),
      isTrue,
    );
    expect(
      await store.readBytes(
        (await store.lookup(
          accountId: account,
          importIds: <String>['import-1'],
        )).single,
      ),
      <int>[1, 2, 3, 4],
    );
    expect(
      await store.purgeExpired(
        accountId: account,
        keep: const Duration(days: 7),
        now: DateTime.utc(2026, 9, 6, 12),
      ),
      0,
    );
    expect(
      await store.purgeExpired(
        accountId: account,
        keep: const Duration(days: 7),
        now: DateTime.utc(2026, 9, 9, 12),
      ),
      1,
    );
    expect(
      await store.hasClips(accountId: account, importIds: <String>['import-1']),
      isFalse,
    );
  });

  test('looks up live chunks by session and imports by import id', () async {
    const account = 'account-b';
    await store.retain(
      accountId: account,
      id: 'chunk-0',
      bytes: Uint8List.fromList(const <int>[9]),
      mimeType: 'audio/wav',
      filename: 'chunk-0.wav',
      capturedAt: DateTime.utc(2026, 9, 6, 10),
      sessionId: 'session-live',
      sequence: 0,
    );
    await store.retain(
      accountId: account,
      id: 'import-9',
      bytes: Uint8List.fromList(const <int>[8]),
      mimeType: 'audio/ogg',
      filename: 'import.ogg',
      capturedAt: DateTime.utc(2026, 9, 6, 11),
      importId: 'import-9',
    );
    expect(
      (await store.lookup(
        accountId: account,
        sessionIds: <String>['session-live'],
      )).map((clip) => clip.id),
      <String>['chunk-0'],
    );
    expect(
      (await store.lookup(
        accountId: account,
        importIds: <String>['import-9'],
      )).map((clip) => clip.id),
      <String>['import-9'],
    );
    expect(await store.purgeAccount(account), greaterThan(0));
    expect(
      await store.hasClips(
        accountId: account,
        sessionIds: <String>['session-live'],
      ),
      isFalse,
    );
  });
}
