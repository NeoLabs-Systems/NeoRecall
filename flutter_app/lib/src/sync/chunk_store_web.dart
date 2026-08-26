// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js' as js;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:idb_shim/idb_browser.dart';
import 'package:uuid/uuid.dart';

import '../models/chunk.dart';
import '../models/recording.dart';
import 'chunk_store.dart';

ChunkStore createChunkStore() => WebChunkStore();

class WebChunkStore implements ChunkStore {
  Database? _database;
  @override
  Future<void> initialize() async {
    _database = await idbFactoryBrowser.open(
      'neorecall-offline-v1',
      version: 2,
      onUpgradeNeeded: (event) {
        final database = event.database;
        if (!database.objectStoreNames.contains('chunks')) {
          database.createObjectStore('chunks', keyPath: 'id');
        }
        if (!database.objectStoreNames.contains('sessions')) {
          database.createObjectStore('sessions', keyPath: 'id');
        }
      },
    );
    final capture = js.context['NeoRecallCapture'];
    if (capture != null) capture.callMethod('requestPersistence');
    await _recoverCapturePartial();
    await _closeInterruptedSessions();
  }

  Future<void> _closeInterruptedSessions() async {
    final sessionTransaction = db.transaction('sessions', 'readonly');
    final sessionValues = await sessionTransaction
        .objectStore('sessions')
        .getAll();
    await sessionTransaction.completed;
    final chunkTransaction = db.transaction('chunks', 'readonly');
    final chunks = (await chunkTransaction.objectStore('chunks').getAll())
        .cast<Map>()
        .map((value) => AudioChunk.fromMap(Map<String, dynamic>.from(value)))
        .toList();
    await chunkTransaction.completed;
    for (final value in sessionValues.cast<Map>()) {
      final session = LocalRecordingDeclaration.fromMap(
        Map<String, dynamic>.from(value),
      );
      if (session.endedAt != null) continue;
      final sequences = chunks
          .where((chunk) => chunk.sessionId == session.id)
          .map((chunk) => chunk.sequence);
      final finalSequence = sequences.isEmpty
          ? -1
          : sequences.reduce((left, right) => left > right ? left : right);
      await putSession(
        session.copyWith(
          endedAt: DateTime.now().toUtc(),
          finalSequence: finalSequence,
          interrupted: true,
          synced: false,
        ),
      );
    }
  }

  Float32List _floatSamples(Object? value) {
    if (value is Float32List) return value;
    if (value is List) {
      return Float32List.fromList(
        value.cast<num>().map((sample) => sample.toDouble()).toList(),
      );
    }
    return Float32List(0);
  }

  Uint8List _wav(Float32List left, Float32List? right, int sampleRate) {
    final channels = right == null ? 1 : 2;
    final output = ByteData(44 + left.length * channels * 2);
    void text(int offset, String value) {
      for (var index = 0; index < value.length; index += 1) {
        output.setUint8(offset + index, value.codeUnitAt(index));
      }
    }

    text(0, 'RIFF');
    output.setUint32(4, output.lengthInBytes - 8, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    output.setUint32(16, 16, Endian.little);
    output.setUint16(20, 1, Endian.little);
    output.setUint16(22, channels, Endian.little);
    output.setUint32(24, sampleRate, Endian.little);
    output.setUint32(28, sampleRate * channels * 2, Endian.little);
    output.setUint16(32, channels * 2, Endian.little);
    output.setUint16(34, 16, Endian.little);
    text(36, 'data');
    output.setUint32(40, output.lengthInBytes - 44, Endian.little);
    var offset = 44;
    int pcm(double value) {
      final sample = value.clamp(-1.0, 1.0);
      return (sample < 0 ? sample * 32768 : sample * 32767).round();
    }

    for (var index = 0; index < left.length; index += 1) {
      output.setInt16(offset, pcm(left[index]), Endian.little);
      offset += 2;
      if (right != null) {
        output.setInt16(
          offset,
          pcm(index < right.length ? right[index] : 0),
          Endian.little,
        );
        offset += 2;
      }
    }
    return output.buffer.asUint8List();
  }

  Future<void> _recoverCapturePartial() async {
    final recovery = await idbFactoryBrowser.open(
      'neorecall-capture-recovery-v1',
      version: 1,
      onUpgradeNeeded: (event) {
        if (!event.database.objectStoreNames.contains('partial')) {
          event.database.createObjectStore('partial');
        }
      },
    );
    final read = recovery.transaction('partial', 'readonly');
    final raw = await read.objectStore('partial').getObject('active');
    await read.completed;
    if (raw == null) {
      recovery.close();
      return;
    }
    final partial = Map<String, dynamic>.from(raw as Map);
    final sessionRead = db.transaction('sessions', 'readonly');
    final sessionValues = await sessionRead.objectStore('sessions').getAll();
    await sessionRead.completed;
    final open =
        sessionValues
            .cast<Map>()
            .map(
              (value) => LocalRecordingDeclaration.fromMap(
                Map<String, dynamic>.from(value),
              ),
            )
            .where((session) => session.endedAt == null)
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (open.isEmpty) {
      recovery.close();
      return;
    }
    final session = open.first;
    final chunkTransaction = db.transaction('chunks', 'readonly');
    final existing = (await chunkTransaction.objectStore('chunks').getAll())
        .cast<Map>()
        .map((value) => AudioChunk.fromMap(Map<String, dynamic>.from(value)))
        .where((chunk) => chunk.sourceId == session.sourceId)
        .toList();
    await chunkTransaction.completed;
    final sequence = existing.isEmpty
        ? 0
        : existing
                  .map((chunk) => chunk.sequence)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    final left = _floatSamples(partial['left']);
    if (left.isNotEmpty) {
      final candidateRight = _floatSamples(partial['right']);
      final right = candidateRight.isEmpty ? null : candidateRight;
      final sampleRate = (partial['sampleRate'] as num?)?.round() ?? 16000;
      final bytes = _wav(left, right, sampleRate);
      final emittedOffset = (partial['emittedOffsetMs'] as num?)?.round() ?? 0;
      final options = Map<String, dynamic>.from(
        partial['options'] as Map? ?? const {},
      );
      final chunk = AudioChunk(
        id: const Uuid().v4(),
        sessionId: session.id,
        sourceId: session.sourceId,
        sequence: sequence,
        startedAt: DateTime.parse(
          partial['startedAt'] as String,
        ).add(Duration(milliseconds: emittedOffset)),
        monotonicOffsetMs: emittedOffset,
        durationMs: (left.length * 1000 / sampleRate).round(),
        overlapMs: sequence == 0
            ? 0
            : (options['overlapMs'] as num?)?.round() ?? 0,
        channelLayout: right == null ? 'mono' : 'microphone_left_system_right',
        container: 'wav',
        codec: 'pcm_s16le',
        sha256: sha256.convert(bytes).toString(),
        state: LocalChunkState.ready,
        createdAt: DateTime.now().toUtc(),
        isFinal: true,
      );
      await put(chunk, bytes);
    }
    await putSession(
      session.copyWith(
        endedAt: DateTime.now().toUtc(),
        finalSequence: left.isEmpty ? sequence - 1 : sequence,
        interrupted: true,
        synced: false,
      ),
    );
    final clear = recovery.transaction('partial', 'readwrite');
    await clear.objectStore('partial').delete('active');
    await clear.completed;
    recovery.close();
  }

  Database get db =>
      _database ?? (throw StateError('ChunkStore is not initialized.'));
  Future<T> _withStore<T>(
    String mode,
    Future<T> Function(ObjectStore store) callback,
  ) async {
    final transaction = db.transaction('chunks', mode);
    final result = await callback(transaction.objectStore('chunks'));
    await transaction.completed;
    return result;
  }

  @override
  Future<void> put(AudioChunk chunk, Uint8List bytes) =>
      _withStore('readwrite', (store) async {
        await store.put(
          chunk.copyWith(state: LocalChunkState.ready, bytes: bytes).toMap(),
        );
      });
  @override
  Future<bool> hasMatchingChunk(String id, String sha256) =>
      _withStore('readonly', (store) async {
        final value = await store.getObject(id);
        return value is Map && value['sha256'] == sha256;
      });
  @override
  Future<void> putPartial(AudioChunk chunk, Uint8List bytes) async {}
  @override
  Future<void> clearPartial(String sourceId) async {}
  @override
  Future<void> putSession(LocalRecordingDeclaration session) async {
    final transaction = db.transaction('sessions', 'readwrite');
    await transaction.objectStore('sessions').put(session.toMap());
    await transaction.completed;
  }

  @override
  Future<void> claimLegacySessions(String accountId) async {
    if (accountId.isEmpty) return;
    final transaction = db.transaction('sessions', 'readwrite');
    final store = transaction.objectStore('sessions');
    final values = await store.getAll();
    for (final value in values.cast<Map>()) {
      final session = LocalRecordingDeclaration.fromMap(
        Map<String, dynamic>.from(value),
      );
      if (session.accountId.isEmpty) {
        await store.put(<String, dynamic>{
          ...session.toMap(),
          'accountId': accountId,
        });
      }
    }
    await transaction.completed;
  }

  @override
  Future<List<LocalRecordingDeclaration>> pendingSessions(
    String accountId,
  ) async {
    final transaction = db.transaction('sessions', 'readonly');
    final values = await transaction.objectStore('sessions').getAll();
    await transaction.completed;
    return values
        .cast<Map>()
        .map(
          (value) => LocalRecordingDeclaration.fromMap(
            Map<String, dynamic>.from(value),
          ),
        )
        .where((session) => session.accountId == accountId && !session.synced)
        .toList();
  }

  @override
  Future<void> markSessionSynced(String id) async {
    final transaction = db.transaction('sessions', 'readwrite');
    final store = transaction.objectStore('sessions');
    final value = await store.getObject(id);
    if (value != null) {
      final session = LocalRecordingDeclaration.fromMap(
        Map<String, dynamic>.from(value as Map),
      );
      await store.put(session.copyWith(synced: true).toMap());
    }
    await transaction.completed;
  }

  @override
  Future<List<AudioChunk>> pending(String accountId, {int limit = 100}) async {
    final sessionTransaction = db.transaction('sessions', 'readonly');
    final sessionValues = await sessionTransaction
        .objectStore('sessions')
        .getAll();
    await sessionTransaction.completed;
    final sessionIds = sessionValues
        .cast<Map>()
        .map(
          (value) => LocalRecordingDeclaration.fromMap(
            Map<String, dynamic>.from(value),
          ),
        )
        .where((session) => session.accountId == accountId)
        .map((session) => session.id)
        .toSet();
    return _withStore('readonly', (store) async {
      final values = await store.getAll();
      final chunks =
          values
              .cast<Map>()
              .map(
                (value) => AudioChunk.fromMap(Map<String, dynamic>.from(value)),
              )
              .where(
                (chunk) =>
                    sessionIds.contains(chunk.sessionId) &&
                    chunk.state != LocalChunkState.released,
              )
              .toList()
            ..sort((a, b) {
              final aTerminal = a.state == LocalChunkState.terminal ? 0 : 1;
              final bTerminal = b.state == LocalChunkState.terminal ? 0 : 1;
              final byState = aTerminal.compareTo(bTerminal);
              return byState != 0
                  ? byState
                  : a.createdAt.compareTo(b.createdAt);
            });
      return chunks.take(limit).toList();
    });
  }

  @override
  Future<Uint8List> readBytes(AudioChunk chunk) async =>
      chunk.bytes ?? (throw StateError('Chunk has no browser audio bytes.'));
  @override
  Future<int> storedBytes(AudioChunk chunk) async => chunk.bytes?.length ?? 0;
  @override
  Future<void> setState(
    String id,
    LocalChunkState state, {
    Map<String, dynamic>? receipt,
    String? error,
  }) => _withStore('readwrite', (store) async {
    final value = await store.getObject(id);
    if (value == null) return;
    final chunk = AudioChunk.fromMap(Map<String, dynamic>.from(value as Map));
    await store.put(
      chunk.copyWith(state: state, receipt: receipt, error: error).toMap(),
    );
  });
  @override
  Future<void> release(String id) => _withStore('readwrite', (store) async {
    final value = await store.getObject(id);
    if (value == null) return;
    final chunk = AudioChunk.fromMap(Map<String, dynamic>.from(value as Map));
    if (chunk.state != LocalChunkState.terminal ||
        !provesSafeAudioRelease(chunk.receipt)) {
      throw StateError(
        'Local audio release requires a proven terminal server receipt.',
      );
    }
    await store.put(<String, dynamic>{
      ...chunk.copyWith(state: LocalChunkState.released).toMap(),
      'bytes': null,
    });
  });
  @override
  Future<int> pendingBytes(String accountId) async {
    final transaction = db.transaction('sessions', 'readonly');
    final values = await transaction.objectStore('sessions').getAll();
    await transaction.completed;
    final sessionIds = values
        .cast<Map>()
        .map(
          (value) => LocalRecordingDeclaration.fromMap(
            Map<String, dynamic>.from(value),
          ),
        )
        .where((session) => session.accountId == accountId)
        .map((session) => session.id)
        .toSet();
    return _withStore('readonly', (store) async {
      final values = await store.getAll();
      return values.cast<Map>().fold<int>(
        0,
        (sum, value) =>
            sum +
            (sessionIds.contains(value['sessionId'])
                ? (value['bytes'] as Uint8List?)?.length ?? 0
                : 0),
      );
    });
  }

  @override
  Future<void> close() async {
    db.close();
    _database = null;
  }

  @override
  Future<void> purgeAll() async {
    await initialize();
    await _withStore('readwrite', (store) => store.clear());
    final sessions = db.transaction('sessions', 'readwrite');
    await sessions.objectStore('sessions').clear();
    await sessions.completed;
  }
}
