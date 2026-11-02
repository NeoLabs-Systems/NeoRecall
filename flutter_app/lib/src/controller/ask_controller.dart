part of '../../main_controller.dart';

/// Asking questions of the owner's recall, and the conversation that holds them.
mixin AskController on ChangeNotifier {
  NeoRecallApiClient get api;
  AppL10n get strings;
  Future<void> refreshAccountUsage({bool silent});

  List<AskTurn> askTurns = <AskTurn>[];
  bool askBusy = false;

  void _applyAskPayload(AskTurn turn, Map payload) {
    turn.answer = payload['answer'] as String?;
    turn.sources = (payload['citations'] as List? ?? <dynamic>[])
        .cast<Map>()
        .map(
          (Map citation) =>
              AskSource.fromJson(Map<String, dynamic>.from(citation)),
        )
        .toList();
    final retrieval = payload['retrieval'];
    if (retrieval is Map) {
      turn.readRetrieval(Map<String, dynamic>.from(retrieval));
    }
  }

  /// Asks one question and appends the exchange to [askTurns].
  ///
  /// The turn is added before the request goes out, so the question the user
  /// typed is on screen while the answer is being written.
  Future<void> ask(String question) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty || askBusy) return;
    final turn = AskTurn(question: trimmed);
    askTurns = <AskTurn>[...askTurns, turn];
    askBusy = true;
    notifyListeners();
    try {
      final payload =
          await api.request(
                'POST',
                '/api/v1/search/ask',
                body: <String, dynamic>{'question': trimmed},
              )
              as Map;
      _applyAskPayload(turn, payload);
    } catch (exception) {
      turn.error = _describeAskFailure(exception);
    } finally {
      askBusy = false;
      notifyListeners();
    }
  }

  void clearAsk() {
    if (askTurns.isEmpty) return;
    askTurns = <AskTurn>[];
    askBusy = false;
    notifyListeners();
  }

  String _describeAskFailure(Object exception) {
    final code = exception is ApiException ? exception.code : '';
    final detail = exception.toString();
    if (code == 'USAGE_LIMIT_EXCEEDED' ||
        detail.contains('USAGE_LIMIT_EXCEEDED')) {
      unawaited(refreshAccountUsage(silent: true));
      return strings.usageAskLimited;
    }
    if (code == 'ASK_RATE_LIMITED' ||
        code == 'ASK_BURST_LIMITED' ||
        detail.contains('ASK_RATE_LIMITED') ||
        detail.contains('ASK_BURST_LIMITED')) {
      return strings.askRateLimited;
    }
    if (code == 'AI_NOT_CONFIGURED' || detail.contains('AI_NOT_CONFIGURED')) {
      return strings.askAiNotConfigured;
    }
    return strings.askFailed;
  }
}
