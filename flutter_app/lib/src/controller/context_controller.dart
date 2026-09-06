part of '../../main_controller.dart';

/// One durable context workflow shared by the live recorder and memory detail.
/// Widgets only choose content; persistence, retries and API translation live here.
mixin ContextController on ChangeNotifier {
  NeoRecallApiClient get api;
  ChunkStore get store;
  Uuid get _uuid;
  String? get accountId;
  bool get online;
  DateTime? get recordingStartedAt;
  bool get isRecording;

  final List<RecordingContextItem> _activeRecordingContext =
      <RecordingContextItem>[];
  List<RecordingContextItem> get activeRecordingContext =>
      List.unmodifiable(_activeRecordingContext);
  Stopwatch? _contextClock;
  Timer? _contextRetryTimer;
  bool _contextSyncing = false;
  static const Duration _contextRetryDelay = Duration(seconds: 15);

  RecordingContextStore? get _contextStore =>
      store is RecordingContextStore ? store as RecordingContextStore : null;

  Future<void> initializeRecordingContext() async {
    await _reloadActiveContext();
    unawaited(syncRecordingContext());
  }

  Future<void> activateRecordingContext(String sessionId) async {
    _contextClock = Stopwatch()..start();
    await _reloadActiveContext(sessionId: sessionId);
  }

  void deactivateRecordingContext() {
    _contextClock?.stop();
    _contextClock = null;
  }

  int get _contextOffsetMs {
    final clock = _contextClock;
    if (clock != null) return clock.elapsedMilliseconds;
    final started = recordingStartedAt;
    return started == null
        ? 0
        : DateTime.now()
              .toUtc()
              .difference(started)
              .inMilliseconds
              .clamp(0, 1 << 31);
  }

  Future<void> addRecordingHighlight(String sessionId) => _addRecordingContext(
    RecordingContextItem(
      id: _uuid.v4(),
      accountId: accountId!,
      sessionId: sessionId,
      kind: RecordingContextKind.highlight,
      capturedOffsetMs: _contextOffsetMs,
      state: LocalContextState.pending,
      createdAt: DateTime.now().toUtc(),
    ),
  );

  Future<void> addRecordingNote(String sessionId, String text) {
    final note = text.trim();
    if (note.isEmpty) throw StateError('Write a note before saving it.');
    final maximum = api.maxContextNoteCharacters;
    if (maximum != null && note.length > maximum) {
      throw StateError('Notes may contain at most $maximum characters.');
    }
    return _addRecordingContext(
      RecordingContextItem(
        id: _uuid.v4(),
        accountId: accountId!,
        sessionId: sessionId,
        kind: RecordingContextKind.note,
        capturedOffsetMs: _contextOffsetMs,
        noteText: note,
        state: LocalContextState.pending,
        createdAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> addRecordingFile({
    required String sessionId,
    required Uint8List bytes,
    required String name,
    required String contentType,
  }) {
    final maximum = api.maxContextFileBytes;
    if (maximum != null && bytes.length > maximum) {
      throw StateError('This file is larger than the server limit.');
    }
    final normalized = contentType.toLowerCase();
    final extension = name.toLowerCase().split('.').last;
    final kind = normalized.startsWith('image/')
        ? RecordingContextKind.image
        : <String>{
            'pdf',
            'docx',
            'txt',
            'md',
            'csv',
            'json',
          }.contains(extension)
        ? RecordingContextKind.document
        : RecordingContextKind.file;
    return _addRecordingContext(
      RecordingContextItem(
        id: _uuid.v4(),
        accountId: accountId!,
        sessionId: sessionId,
        kind: kind,
        capturedOffsetMs: _contextOffsetMs,
        originalName: name,
        contentType: contentType,
        byteSize: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        bytes: bytes,
        state: LocalContextState.pending,
        createdAt: DateTime.now().toUtc(),
      ),
      bytes,
    );
  }

  Future<void> _addRecordingContext(
    RecordingContextItem item, [
    Uint8List? bytes,
  ]) async {
    if (!isRecording) {
      throw StateError('Context can only be added while recording is active.');
    }
    final contextStore = _contextStore;
    if (contextStore == null) {
      throw StateError('Recording context storage is unavailable.');
    }
    await contextStore.putContext(item, bytes);
    _activeRecordingContext.add(item);
    _activeRecordingContext.sort(
      (left, right) => left.capturedOffsetMs.compareTo(right.capturedOffsetMs),
    );
    notifyListeners();
    unawaited(syncRecordingContext());
  }

  Future<void> _reloadActiveContext({String? sessionId}) async {
    final owner = accountId;
    final contextStore = _contextStore;
    if (owner == null || contextStore == null) return;
    final target =
        sessionId ??
        (_activeRecordingContext.isEmpty
            ? null
            : _activeRecordingContext.first.sessionId);
    if (target == null) return;
    _activeRecordingContext
      ..clear()
      ..addAll(await contextStore.contextItems(owner, sessionId: target));
    notifyListeners();
  }

  Future<void> syncRecordingContext() async {
    final contextStore = _contextStore;
    if (_contextSyncing ||
        !online ||
        api.token == null ||
        accountId == null ||
        contextStore == null) {
      return;
    }
    _contextSyncing = true;
    _contextRetryTimer?.cancel();
    try {
      final pending = await contextStore.contextItems(
        accountId!,
        pendingOnly: true,
      );
      for (final item in pending) {
        try {
          await contextStore.setContextState(
            item.id,
            LocalContextState.uploading,
          );
          final bytes = await contextStore.readContextBytes(item);
          if (item.sha256 != null &&
              (bytes == null ||
                  sha256.convert(bytes).toString() != item.sha256)) {
            throw StateError(
              'The locally stored context file failed its integrity check.',
            );
          }
          await api.uploadRecordingContext(item, bytes);
          await contextStore.releaseContextBytes(item.id);
        } catch (error) {
          await contextStore.setContextState(
            item.id,
            LocalContextState.failed,
            error: error.toString(),
          );
        }
      }
      if (_activeRecordingContext.isNotEmpty) await _reloadActiveContext();
    } finally {
      _contextSyncing = false;
      final remaining = accountId == null
          ? const <RecordingContextItem>[]
          : await contextStore.contextItems(accountId!, pendingOnly: true);
      if (remaining.isNotEmpty) {
        _contextRetryTimer = Timer(
          _contextRetryDelay,
          () => unawaited(syncRecordingContext()),
        );
      }
    }
  }

  Future<Map<String, dynamic>> addMemoryNoteContext(
    String memoryId,
    String text,
  ) async {
    final item = RecordingContextItem(
      id: _uuid.v4(),
      accountId: accountId!,
      sessionId: '',
      kind: RecordingContextKind.note,
      capturedOffsetMs: 0,
      noteText: text.trim(),
      state: LocalContextState.pending,
      createdAt: DateTime.now().toUtc(),
    );
    return api.uploadMemoryContext(memoryId: memoryId, item: item);
  }

  Future<Map<String, dynamic>> addMemoryFileContext(
    String memoryId,
    Uint8List bytes,
    String name,
    String contentType,
  ) async {
    final kind = contentType.toLowerCase().startsWith('image/')
        ? RecordingContextKind.image
        : RecordingContextKind.document;
    final item = RecordingContextItem(
      id: _uuid.v4(),
      accountId: accountId!,
      sessionId: '',
      kind: kind,
      capturedOffsetMs: 0,
      originalName: name,
      contentType: contentType,
      byteSize: bytes.length,
      sha256: sha256.convert(bytes).toString(),
      bytes: bytes,
      state: LocalContextState.pending,
      createdAt: DateTime.now().toUtc(),
    );
    return api.uploadMemoryContext(
      memoryId: memoryId,
      item: item,
      bytes: bytes,
    );
  }

  Future<void> deleteMemoryContext(String memoryId, String itemId) async {
    await api.request('DELETE', '/api/v1/memories/$memoryId/context/$itemId');
  }

  Future<void> retryMemoryContext(String memoryId, String itemId) async {
    await api.request(
      'POST',
      '/api/v1/memories/$memoryId/context/$itemId/retry',
    );
  }

  void disposeRecordingContext() {
    _contextRetryTimer?.cancel();
    deactivateRecordingContext();
  }
}
