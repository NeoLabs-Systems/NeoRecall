part of '../../main_controller.dart';

/// Editing what the app has already learned: memories, highlights, speakers,
/// devices, and user settings.
///
/// Uniformly shaped — call the API, refresh, notify — and entirely separate
/// from capture. Grouping it here is what makes that shape visible, and makes
/// the controller's remaining bulk actually about recording.
mixin LibraryController on ChangeNotifier {
  /// The controller's translations, for the messages this mixin produces.
  AppL10n get strings;
  NeoRecallApiClient get api;
  List<RecallMemory> get memories;
  set memories(List<RecallMemory> value);
  List<MiniMemory> get miniMemories;
  set miniMemories(List<MiniMemory> value);
  List<RecallSpeaker> get speakers;
  List<TimelineMoment> get moments;
  set moments(List<TimelineMoment> value);
  Map<String, List<TranscriptSegment>> get momentTranscripts;
  Future<Map<String, dynamic>> _settings();
  Future<void> refreshAll({bool silent});
  Future<void> _cacheSettings(Map<String, dynamic> value);
  Future<void> _refreshPending();
  Future<void> applyRawAudioRetention({bool purgeAll = false});
  void _applyRecordingSchedule();
  SyncCoordinator get sync;
  String? get notice;
  set notice(String? value);

  Future<void> renameSpeaker(String id, String name) async {
    await api.request(
      'PATCH',
      '/api/v1/speakers/$id',
      body: <String, dynamic>{'displayName': name},
    );
    await refreshAll(silent: true);
  }

  Future<void> mergeSpeaker(String targetId, String sourceId) async {
    await api.request(
      'POST',
      '/api/v1/speakers/$targetId/merge',
      body: <String, dynamic>{'sourceId': sourceId},
    );
    await refreshAll(silent: true);
  }

  Future<void> deleteSpeaker(String id) async {
    await api.request('DELETE', '/api/v1/speakers/$id');
    await refreshAll(silent: true);
  }

  Future<void> setSpeakerMatching(String id, bool enabled) async {
    await api.request(
      'PATCH',
      '/api/v1/speakers/$id',
      body: <String, dynamic>{'matchingEnabled': enabled},
    );
    await refreshAll(silent: true);
  }

  Future<void> bulkDeleteSpeakers(List<String> ids) async {
    if (ids.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/speakers/bulk',
      body: <String, dynamic>{'ids': ids, 'action': 'delete'},
    );
    await refreshAll(silent: true);
  }

  Future<void> deleteMoment(String id) => bulkDeleteMoments(<String>[id]);

  Future<void> bulkDeleteMoments(List<String> ids) async {
    if (ids.isEmpty) return;
    final removed = ids.toSet();
    final previous = moments;
    moments = moments
        .where((moment) => moment.id == null || !removed.contains(moment.id))
        .toList();
    for (final id in ids) {
      momentTranscripts.remove(id);
    }
    notifyListeners();
    try {
      await api.request(
        'POST',
        '/api/v1/conversations/bulk',
        body: <String, dynamic>{'ids': ids, 'action': 'delete'},
      );
      unawaited(refreshAll(silent: true));
    } catch (_) {
      moments = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> mergeSpeakers(String targetId, List<String> sourceIds) async {
    if (sourceIds.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/speakers/merge',
      body: <String, dynamic>{'targetId': targetId, 'sourceIds': sourceIds},
    );
    await refreshAll(silent: true);
  }

  Future<Map<String, dynamic>> reevaluateSpeakers() async {
    final result = Map<String, dynamic>.from(
      await api.request('POST', '/api/v1/speakers/reevaluate') as Map,
    );
    await refreshAll(silent: true);
    return result;
  }

  Future<Map<String, dynamic>> loadSettings() => _settings();
  Future<void> updateSettings(Map<String, dynamic> changes) async {
    final payload =
        await api.request('PUT', '/api/v1/settings', body: changes) as Map;
    final settings = Map<String, dynamic>.from(payload['settings'] as Map);
    // An older server drops unknown keys. Keep the choice the user just made
    // so raw-audio retention does not snap back to the default.
    if (changes.containsKey('keepRawAudio') &&
        !settings.containsKey('keepRawAudio')) {
      settings['keepRawAudio'] = changes['keepRawAudio'];
    }
    await _cacheSettings(settings);
    await applyRawAudioRetention();
    // Status is derived from the cached policy, so refresh it before returning
    // to a settings screen that may have just changed the network rule.
    await _refreshPending();
    sync.pump.pump();
    _applyRecordingSchedule();
    notice = strings.settingsSaved;
    notifyListeners();
  }

  Future<void> revokeDevice(String id) async {
    await api.request('DELETE', '/api/v1/devices/$id');
    await refreshAll(silent: true);
  }

  Future<void> updateMiniMemory(String id, String status) async {
    await api.request(
      'PATCH',
      '/api/v1/mini-memories/$id',
      body: <String, dynamic>{'status': status},
    );
    await refreshAll(silent: true);
  }

  Future<void> deleteMiniMemory(String id) async {
    await api.request('DELETE', '/api/v1/mini-memories/$id');
    miniMemories = miniMemories.where((mini) => mini.id != id).toList();
    notifyListeners();
  }

  /// Full memory detail including linked transcript segments and mini-memories.
  Future<Map<String, dynamic>> loadMemoryDetail(String id) async {
    final payload =
        await api.request('GET', '/api/v1/memories/$id')
            as Map<dynamic, dynamic>;
    return Map<String, dynamic>.from(payload);
  }

  Future<Map<String, dynamic>> loadMiniMemoryDetail(String id) async {
    final payload =
        await api.request('GET', '/api/v1/mini-memories/$id')
            as Map<dynamic, dynamic>;
    return Map<String, dynamic>.from(payload);
  }

  Future<void> renameMemory(String id, String title) async {
    await api.request(
      'PATCH',
      '/api/v1/memories/$id',
      body: <String, dynamic>{'titleEn': title},
    );
    await refreshAll(silent: true);
  }

  Future<void> updateMemory(String id, {bool? pinned, bool? archived}) async {
    final body = <String, dynamic>{};
    if (pinned != null) body['pinned'] = pinned;
    if (archived != null) body['archived'] = archived;
    if (body.isEmpty) return;
    await api.request('PATCH', '/api/v1/memories/$id', body: body);
    await refreshAll(silent: true);
  }

  Future<void> deleteMemory(String id) async {
    await api.request('DELETE', '/api/v1/memories/$id');
    memories = memories.where((memory) => memory.id != id).toList();
    notifyListeners();
  }

  /// Mass pin / archive / delete for the consumer multi-select bar.
  Future<void> bulkMemories(List<String> ids, String action) async {
    if (ids.isEmpty) return;
    await api.request(
      'POST',
      '/api/v1/memories/bulk',
      body: <String, dynamic>{'ids': ids, 'action': action},
    );
    await refreshAll(silent: true);
  }

  /// Merge two or more memories into one.
  ///
  /// The server combines evidence and highlights and answers straight away, so
  /// the merged card can take its place in the list without anyone waiting. A
  /// reworded title and summary follow later from a background job; the next
  /// refresh picks them up.
  Future<Map<String, dynamic>> mergeMemories(List<String> ids) async {
    if (ids.length < 2) {
      throw StateError(strings.controllerMergeTooFew);
    }
    final mergeMax = api.maxMemoryMergeItems;
    if (mergeMax != null && ids.length > mergeMax) {
      throw StateError(strings.controllerMergeTooMany(mergeMax));
    }
    final payload =
        await api.request(
              'POST',
              '/api/v1/memories/merge',
              body: <String, dynamic>{'ids': ids},
            )
            as Map<dynamic, dynamic>;
    final result = Map<String, dynamic>.from(payload);
    final absorbedIds = ((result['absorbedIds'] as List?) ?? <dynamic>[])
        .map((value) => value.toString())
        .toSet();
    final memoryJson = result['memory'];
    if (memoryJson is Map) {
      final merged = RecallMemory.fromJson(
        Map<String, dynamic>.from(memoryJson),
      );
      memories = <RecallMemory>[
        merged,
        ...memories.where(
          (memory) =>
              memory.id != merged.id && !absorbedIds.contains(memory.id),
        ),
      ];
      notifyListeners();
    }
    unawaited(refreshAll(silent: true));
    return result;
  }
}
