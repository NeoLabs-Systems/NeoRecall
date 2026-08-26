import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqlite;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;

import '../models/chunk.dart';
import '../models/recording.dart';
import 'chunk_store.dart';

ChunkStore createChunkStore() => IoChunkStore();

class _RecoveredWav {
  const _RecoveredWav(this.bytes, this.durationMs);

  final Uint8List bytes;
  final int durationMs;
}

_RecoveredWav? _recoverWavBytes(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final header = ByteData.sublistView(bytes);
  String text(int offset, int length) =>
      String.fromCharCodes(bytes.sublist(offset, offset + length));
  if (text(0, 4) != 'RIFF' || text(8, 4) != 'WAVE' || text(36, 4) != 'data') {
    return null;
  }
  final sampleRate = header.getUint32(24, Endian.little);
  final frameBytes = header.getUint16(32, Endian.little);
  if (sampleRate <= 0 || frameBytes <= 0) return null;
  final availableData = ((bytes.length - 44) ~/ frameBytes) * frameBytes;
  if (availableData <= 0) return null;
  final recovered = Uint8List.fromList(bytes.sublist(0, 44 + availableData));
  final recoveredHeader = ByteData.sublistView(recovered);
  recoveredHeader.setUint32(4, recovered.length - 8, Endian.little);
  recoveredHeader.setUint32(40, availableData, Endian.little);
  return _RecoveredWav(
    recovered,
    (availableData * 1000 / (sampleRate * frameBytes)).round(),
  );
}

DatabaseFactory _desktopDatabaseFactory() {
  sqfliteFfiInit();
  return databaseFactoryFfi;
}

class IoChunkStore implements ChunkStore {
  Database? _database;
  late Directory _audioDirectory;

  @override
  Future<void> initialize() async {
    if (_database != null) return;
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'NeoRecall'))
      ..createSync(recursive: true);
    _audioDirectory = Directory(p.join(root.path, 'pending_audio'))
      ..createSync(recursive: true);
    Future<void> createSessions(Database database) => database.execute(
      '''CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY, accountId TEXT NOT NULL DEFAULT '', sourceId TEXT NOT NULL, deviceId TEXT NOT NULL, deviceClientUuid TEXT NOT NULL,
        deviceName TEXT NOT NULL, platform TEXT NOT NULL, startedAt TEXT NOT NULL, timezone TEXT NOT NULL,
        consentAttestedAt TEXT NOT NULL, sourceKind TEXT NOT NULL, channelLayout TEXT NOT NULL,
        sampleRate INTEGER NOT NULL DEFAULT 16000,
        endedAt TEXT, finalSequence INTEGER, interrupted INTEGER NOT NULL DEFAULT 0, synced INTEGER NOT NULL)''',
    );
    Future<void> createCapturePartials(Database database) =>
        database.execute('''CREATE TABLE IF NOT EXISTS capture_partials (
        sourceId TEXT PRIMARY KEY, chunkJson TEXT NOT NULL, filePath TEXT NOT NULL,
        updatedAt TEXT NOT NULL)''');
    final factory = Platform.isAndroid || Platform.isIOS
        ? mobile_sqlite.databaseFactory
        : _desktopDatabaseFactory();
    try {
      _database = await factory.openDatabase(
        p.join(root.path, 'offline.sqlite3'),
        options: OpenDatabaseOptions(
          version: 6,
          onCreate: (database, _) async {
            await database.execute('''CREATE TABLE chunks (
        id TEXT PRIMARY KEY, sessionId TEXT NOT NULL, sourceId TEXT NOT NULL, sequence INTEGER NOT NULL,
        startedAt TEXT NOT NULL, monotonicOffsetMs INTEGER NOT NULL, durationMs INTEGER NOT NULL, overlapMs INTEGER NOT NULL,
        channelLayout TEXT NOT NULL, container TEXT NOT NULL, codec TEXT NOT NULL, sha256 TEXT NOT NULL,
        state TEXT NOT NULL, createdAt TEXT NOT NULL, filePath TEXT, isFinal INTEGER NOT NULL,
        receipt TEXT, error TEXT, UNIQUE(sourceId,sequence))''');
            await createSessions(database);
            await createCapturePartials(database);
          },
          onUpgrade: (database, oldVersion, _) async {
            if (oldVersion < 2) {
              await createSessions(database);
            } else if (oldVersion < 3) {
              await database.execute(
                'ALTER TABLE sessions ADD COLUMN interrupted INTEGER NOT NULL DEFAULT 0',
              );
            }
            if (oldVersion < 4) await createCapturePartials(database);
            if (oldVersion >= 2 && oldVersion < 5) {
              await database.execute(
                'ALTER TABLE sessions ADD COLUMN sampleRate INTEGER NOT NULL DEFAULT 16000',
              );
            }
            if (oldVersion >= 2 && oldVersion < 6) {
              await database.execute(
                "ALTER TABLE sessions ADD COLUMN accountId TEXT NOT NULL DEFAULT ''",
              );
            }
          },
        ),
      );
      final capturing = await _database!.query(
        'chunks',
        where: 'state=?',
        whereArgs: <Object?>[LocalChunkState.capturing.name],
      );
      for (final row in capturing) {
        final finalFile = File(
          p.join(_audioDirectory.path, '${row['id']}.${row['container']}'),
        );
        final declaredFile = row['filePath'] == null
            ? null
            : File(row['filePath'] as String);
        // put() renames before updating SQLite. If the process dies in that
        // narrow window, the ledger still names `.partial` while the complete
        // file is already at its canonical path.
        final file = declaredFile?.existsSync() == true
            ? declaredFile
            : finalFile.existsSync()
            ? finalFile
            : null;
        final recovered = file == null
            ? null
            : _recoverWavBytes(await file.readAsBytes());
        if (file != null && recovered != null) {
          final handle = await file.open(mode: FileMode.writeOnly);
          try {
            await handle.writeFrom(recovered.bytes);
            await handle.truncate(recovered.bytes.length);
            await handle.flush();
          } finally {
            await handle.close();
          }
          if (file.path != finalFile.path) await file.rename(finalFile.path);
          await _database!.update(
            'chunks',
            <String, Object?>{
              'state': LocalChunkState.ready.name,
              'filePath': finalFile.path,
              'sha256': sha256.convert(recovered.bytes).toString(),
              'durationMs': recovered.durationMs,
              'isFinal': 1,
              'error': 'Recovered after an interrupted local write.',
            },
            where: 'id=?',
            whereArgs: <Object?>[row['id']],
          );
        } else {
          await _database!.update(
            'chunks',
            <String, Object?>{
              'state': LocalChunkState.needsAttention.name,
              if (file != null) 'filePath': file.path,
              'error':
                  'Capture was interrupted before the local WAV could be recovered automatically. The original file was retained.',
            },
            where: 'id=?',
            whereArgs: <Object?>[row['id']],
          );
        }
      }
      final capturePartials = await _database!.query('capture_partials');
      for (final row in capturePartials) {
        final file = File(row['filePath'] as String);
        if (!file.existsSync() || file.lengthSync() < 44) continue;
        final map = Map<String, dynamic>.from(
          jsonDecode(row['chunkJson'] as String) as Map,
        );
        final recovered = _recoverWavBytes(await file.readAsBytes());
        if (recovered == null) continue;
        final handle = await file.open(mode: FileMode.writeOnly);
        try {
          await handle.writeFrom(recovered.bytes);
          await handle.truncate(recovered.bytes.length);
          await handle.flush();
        } finally {
          await handle.close();
        }
        map.addAll(<String, Object?>{
          'state': LocalChunkState.ready.name,
          'filePath': file.path,
          'sha256': sha256.convert(recovered.bytes).toString(),
          'durationMs': recovered.durationMs,
          'isFinal': 1,
          'error': 'Recovered from the rolling capture ledger.',
        });
        final inserted = await _database!.insert(
          'chunks',
          map,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        if (inserted == 0) await file.delete();
        await _database!.delete(
          'capture_partials',
          where: 'sourceId=?',
          whereArgs: <Object?>[row['sourceId']],
        );
      }
      final openSessions = await _database!.query(
        'sessions',
        where: 'endedAt IS NULL',
      );
      for (final session in openSessions) {
        final maximum = await _database!.rawQuery(
          'SELECT MAX(sequence) value FROM chunks WHERE sessionId=?',
          <Object?>[session['id']],
        );
        final sequence = maximum.first['value'] as int? ?? -1;
        await _database!.update(
          'sessions',
          <String, Object?>{
            'endedAt': DateTime.now().toUtc().toIso8601String(),
            'finalSequence': sequence,
            'interrupted': 1,
            'synced': 0,
          },
          where: 'id=?',
          whereArgs: <Object?>[session['id']],
        );
      }
    } catch (_) {
      await _database?.close();
      _database = null;
      rethrow;
    }
  }

  Database get db =>
      _database ?? (throw StateError('ChunkStore is not initialized.'));
  @override
  Future<void> put(AudioChunk chunk, Uint8List bytes) async {
    final partial = File(p.join(_audioDirectory.path, '${chunk.id}.partial'));
    final finalFile = File(
      p.join(_audioDirectory.path, '${chunk.id}.${chunk.container}'),
    );
    final map = chunk
        .copyWith(state: LocalChunkState.capturing, filePath: partial.path)
        .toMap(includeBytes: false);
    await db.insert('chunks', map, conflictAlgorithm: ConflictAlgorithm.abort);
    final handle = await partial.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await partial.rename(finalFile.path);
    await db.update(
      'chunks',
      <String, Object?>{
        'state': LocalChunkState.ready.name,
        'filePath': finalFile.path,
      },
      where: 'id=?',
      whereArgs: <Object?>[chunk.id],
    );
  }

  @override
  Future<bool> hasMatchingChunk(String id, String sha256) async {
    final rows = await db.query(
      'chunks',
      columns: <String>['sha256'],
      where: 'id=?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['sha256'] == sha256;
  }

  @override
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes) async {
    final file = File(p.join(_audioDirectory.path, '${chunk.id}.recovery.wav'));
    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
    final previous = await db.query(
      'capture_partials',
      columns: <String>['filePath'],
      where: 'sourceId=?',
      whereArgs: <Object?>[chunk.sourceId],
      limit: 1,
    );
    final map = chunk.toMap(includeBytes: false)
      ..['filePath'] = file.path
      ..['state'] = LocalChunkState.ready.name;
    await db.insert('capture_partials', <String, Object?>{
      'sourceId': chunk.sourceId,
      'chunkJson': jsonEncode(map),
      'filePath': file.path,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (previous.isNotEmpty) {
      final old = File(previous.first['filePath'] as String);
      if (old.path != file.path && old.existsSync()) await old.delete();
    }
  }

  @override
  Future<void> clearPartial(String sourceId) async {
    final rows = await db.query(
      'capture_partials',
      columns: <String>['filePath'],
      where: 'sourceId=?',
      whereArgs: <Object?>[sourceId],
    );
    await db.delete(
      'capture_partials',
      where: 'sourceId=?',
      whereArgs: <Object?>[sourceId],
    );
    for (final row in rows) {
      final file = File(row['filePath'] as String);
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  Future<void> putSession(LocalRecordingDeclaration session) async => db.insert(
    'sessions',
    session.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  @override
  Future<void> claimLegacySessions(String accountId) async {
    if (accountId.isEmpty) return;
    await db.update('sessions', <String, Object?>{
      'accountId': accountId,
    }, where: "accountId=''");
  }

  @override
  Future<List<LocalRecordingDeclaration>> pendingSessions(
    String accountId,
  ) async =>
      (await db.query(
            'sessions',
            where: 'synced=0 AND accountId=?',
            whereArgs: <Object?>[accountId],
            orderBy: 'startedAt',
          ))
          .map(
            (row) => LocalRecordingDeclaration.fromMap(
              Map<String, dynamic>.from(row),
            ),
          )
          .toList();
  @override
  Future<void> markSessionSynced(String id) async {
    await db.update(
      'sessions',
      <String, Object?>{'synced': 1},
      where: 'id=?',
      whereArgs: <Object?>[id],
    );
  }

  Map<String, dynamic> _map(Map<String, Object?> row) => <String, dynamic>{
    ...row,
    if (row['receipt'] != null) 'receipt': jsonDecode(row['receipt'] as String),
  };
  @override
  Future<List<AudioChunk>> pending(
    String accountId, {
    int limit = 100,
  }) async => (await db.rawQuery(
    // needsAttention is returned so callers can surface/retry it; the upload
    // pump filters by state itself and never acts on needsAttention chunks.
    '''SELECT c.* FROM chunks c
       JOIN sessions s ON s.id=c.sessionId
       WHERE s.accountId=? AND c.state IN (?,?,?,?,?,?,?)
       ORDER BY CASE WHEN c.state=? THEN 0 ELSE 1 END,
                c.createdAt,c.sourceId,c.sequence
       LIMIT ?''',
    <Object?>[
      accountId,
      LocalChunkState.ready.name,
      LocalChunkState.uploading.name,
      LocalChunkState.uploaded.name,
      LocalChunkState.failed.name,
      LocalChunkState.capturing.name,
      LocalChunkState.needsAttention.name,
      LocalChunkState.terminal.name,
      LocalChunkState.terminal.name,
      limit,
    ],
  )).map((row) => AudioChunk.fromMap(_map(row))).toList();
  @override
  Future<Uint8List> readBytes(AudioChunk chunk) =>
      File(chunk.filePath!).readAsBytes();
  @override
  Future<int> storedBytes(AudioChunk chunk) async {
    final path = chunk.filePath;
    if (path == null) return chunk.bytes?.length ?? 0;
    final file = File(path);
    return await file.exists() ? file.length() : 0;
  }

  @override
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  }) => db
      .update(
        'chunks',
        <String, Object?>{
          'state': state.name,
          if (receipt != null) 'receipt': jsonEncode(receipt),
          'error': ?error,
        },
        where: 'id=?',
        whereArgs: <Object?>[id],
      )
      .then((_) {});
  @override
  Future<void> release(String id) async {
    final rows = await db.query(
      'chunks',
      where: 'id=?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final state = LocalChunkState.values.byName(rows.first['state'] as String);
    final receipt = rows.first['receipt'] == null
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.first['receipt'] as String) as Map,
          );
    if (state != LocalChunkState.terminal || !provesSafeAudioRelease(receipt)) {
      throw StateError(
        'Local audio release requires a proven terminal server receipt.',
      );
    }
    final filePath = rows.first['filePath'] as String?;
    if (filePath != null) {
      final file = File(filePath);
      if (file.existsSync()) await file.delete();
    }
    await db.update(
      'chunks',
      <String, Object?>{
        'state': LocalChunkState.released.name,
        'filePath': null,
      },
      where: 'id=?',
      whereArgs: <Object?>[id],
    );
  }

  @override
  Future<int> pendingBytes(String accountId) async {
    final rows = await db.rawQuery(
      '''SELECT c.filePath FROM chunks c
         JOIN sessions s ON s.id=c.sessionId
         WHERE s.accountId=? AND c.state!=?''',
      <Object?>[accountId, LocalChunkState.released.name],
    );
    final chunkBytes = rows.fold<int>(0, (sum, row) {
      final path = row['filePath'] as String?;
      return sum +
          (path != null && File(path).existsSync()
              ? File(path).lengthSync()
              : 0);
    });
    final partials = await db.rawQuery(
      '''SELECT p.filePath FROM capture_partials p
         JOIN sessions s ON s.sourceId=p.sourceId
         WHERE s.accountId=?''',
      <Object?>[accountId],
    );
    return chunkBytes +
        partials.fold<int>(0, (sum, row) {
          final file = File(row['filePath'] as String);
          return sum + (file.existsSync() ? file.lengthSync() : 0);
        });
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }
}
