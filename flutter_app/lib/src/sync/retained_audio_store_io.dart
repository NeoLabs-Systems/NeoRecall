import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ledger_seal.dart';
import 'retained_audio_store.dart';

RetainedAudioStore createRetainedAudioStore({String? rootPath}) =>
    IoRetainedAudioStore(rootPath: rootPath);

class IoRetainedAudioStore implements RetainedAudioStore {
  IoRetainedAudioStore({this.rootPath});

  final String? rootPath;
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    final existing = _root;
    if (existing != null) return existing;
    if (rootPath != null) {
      return _root = Directory(rootPath!)..createSync(recursive: true);
    }
    final support = await getApplicationSupportDirectory();
    return _root = Directory(
      p.join(support.path, 'NeoRecall', 'retained_audio'),
    )..createSync(recursive: true);
  }

  Directory _accountDir(String accountId) =>
      Directory(p.join(_root!.path, _safeSegment(accountId)))
        ..createSync(recursive: true);

  static String _safeSegment(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static String _extensionFor(String mimeType, String filename) {
    final fromName = p.extension(filename);
    if (fromName.isNotEmpty && fromName.length <= 8) return fromName;
    return switch (mimeType.toLowerCase()) {
      'audio/wav' || 'audio/x-wav' => '.wav',
      'audio/mpeg' => '.mp3',
      'audio/mp4' => '.m4a',
      'audio/aac' => '.aac',
      'audio/webm' => '.webm',
      'audio/ogg' || 'audio/opus' => '.ogg',
      _ => '.bin',
    };
  }

  File _metaFile(String accountId, String id) =>
      File(p.join(_accountDir(accountId).path, '${_safeSegment(id)}.json'));

  File _audioFile(
    String accountId,
    String id,
    String mimeType,
    String filename,
  ) => File(
    p.join(
      _accountDir(accountId).path,
      '${_safeSegment(id)}${_extensionFor(mimeType, filename)}',
    ),
  );

  Future<List<File>> _metaFiles(String accountId) async {
    await _ensureRoot();
    final dir = _accountDir(accountId);
    if (!dir.existsSync()) return const <File>[];
    return dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.json'))
        .toList();
  }

  RetainedAudioClip? _readMeta(File file) {
    try {
      return RetainedAudioClip.fromJson(
        Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> initialize() async {
    await _ensureRoot();
  }

  @override
  Future<void> retain({
    required String accountId,
    required String id,
    required Uint8List bytes,
    required String mimeType,
    required String filename,
    required DateTime capturedAt,
    String? importId,
    String? sessionId,
    int sequence = 0,
    Duration duration = Duration.zero,
  }) async {
    await _ensureRoot();
    final clip = RetainedAudioClip(
      id: id,
      accountId: accountId,
      capturedAt: capturedAt.toUtc(),
      mimeType: mimeType,
      filename: filename,
      byteLength: bytes.length,
      importId: importId,
      sessionId: sessionId,
      sequence: sequence,
      duration: duration,
    );
    final audio = _audioFile(accountId, id, mimeType, filename);
    audio.writeAsBytesSync(
      await (await LedgerSeal.instance()).seal(bytes),
      flush: true,
    );
    _metaFile(accountId, id).writeAsStringSync(jsonEncode(clip.toJson()));
  }

  @override
  Future<List<RetainedAudioClip>> lookup({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  }) async {
    final imports = importIds.where((id) => id.isNotEmpty).toSet();
    final sessions = sessionIds.where((id) => id.isNotEmpty).toSet();
    if (imports.isEmpty && sessions.isEmpty) return const <RetainedAudioClip>[];
    final clips = <RetainedAudioClip>[];
    for (final file in await _metaFiles(accountId)) {
      final clip = _readMeta(file);
      if (clip == null) continue;
      if ((clip.importId != null && imports.contains(clip.importId)) ||
          (clip.sessionId != null && sessions.contains(clip.sessionId))) {
        clips.add(clip);
      }
    }
    clips.sort((a, b) {
      final bySequence = a.sequence.compareTo(b.sequence);
      if (bySequence != 0) return bySequence;
      return a.capturedAt.compareTo(b.capturedAt);
    });
    return clips;
  }

  @override
  Future<bool> hasClips({
    required String accountId,
    Iterable<String> importIds = const <String>[],
    Iterable<String> sessionIds = const <String>[],
  }) async {
    final found = await lookup(
      accountId: accountId,
      importIds: importIds,
      sessionIds: sessionIds,
    );
    return found.isNotEmpty;
  }

  @override
  Future<RetainedAudioClip?> getClip(String accountId, String id) async {
    await _ensureRoot();
    return _readMeta(_metaFile(accountId, id));
  }

  @override
  Future<Uint8List> readBytes(RetainedAudioClip clip) async {
    await _ensureRoot();
    final file = _audioFile(
      clip.accountId,
      clip.id,
      clip.mimeType,
      clip.filename,
    );
    if (!file.existsSync()) {
      throw StateError('This recording is no longer kept on this device.');
    }
    return (await LedgerSeal.instance()).unseal(await file.readAsBytes());
  }

  Future<void> _deleteClip(String accountId, RetainedAudioClip clip) async {
    final meta = _metaFile(accountId, clip.id);
    final audio = _audioFile(accountId, clip.id, clip.mimeType, clip.filename);
    if (meta.existsSync()) meta.deleteSync();
    if (audio.existsSync()) audio.deleteSync();
  }

  @override
  Future<int> purgeExpired({
    required String accountId,
    required Duration keep,
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(keep);
    var removed = 0;
    for (final file in await _metaFiles(accountId)) {
      final clip = _readMeta(file);
      if (clip == null) {
        file.deleteSync();
        removed += 1;
        continue;
      }
      if (!clip.capturedAt.isBefore(cutoff)) continue;
      await _deleteClip(accountId, clip);
      removed += 1;
    }
    return removed;
  }

  @override
  Future<int> purgeAccount(String accountId) async {
    await _ensureRoot();
    final dir = _accountDir(accountId);
    if (!dir.existsSync()) return 0;
    final files = dir.listSync().whereType<File>().toList();
    for (final file in files) {
      file.deleteSync();
    }
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    return files.length;
  }

  @override
  Future<void> close() async {
    _root = null;
  }
}
