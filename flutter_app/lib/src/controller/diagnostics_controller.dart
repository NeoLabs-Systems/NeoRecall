part of '../../main_controller.dart';

/// The on-device diagnostic log and the export a user sends when reporting a
/// problem. Self-contained: it reads the log and the API, and touches no
/// capture or library state.
mixin DiagnosticsController on ChangeNotifier {
  NeoRecallApiClient get api;
  bool get authenticated;
  DeviceSessionController get audioDeviceSessions;
  bool get deviceConnected;
  int get needsAttentionCount;
  int get pendingAudioBytes;

  Future<String> buildDiagnosticExport() async {
    if (!authenticated) {
      throw StateError('Sign in before exporting diagnostics.');
    }
    Object backend;
    var backendAvailable = true;
    try {
      backend = await api.request('GET', '/api/v1/diagnostics/export');
    } catch (error) {
      backendAvailable = false;
      backend = <String, Object?>{
        'available': false,
        'error': error.toString(),
      };
    }
    ClientDiagnosticLog.instance.record(
      'diagnostics',
      'export_created',
      details: <String, Object?>{'backendAvailable': backendAvailable},
    );
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'schemaVersion': 2,
      'client': <String, Object?>{
        ...ClientDiagnosticLog.instance.clientSummary(),
        'wearableAudioCodec': wearableAudioCodecStatus,
        'preferredDevice': audioDeviceSessions.preferredDevice?.displayName,
        'preferredDeviceType':
            audioDeviceSessions.preferredDevice?.metadata['type'],
        'deviceState': audioDeviceSessions.state.name,
        'deviceConnected': deviceConnected,
        'pendingAudioBytes': pendingAudioBytes,
        'needsAttentionCount': needsAttentionCount,
      },
      'backend': backend,
    });
  }

  /// Recent diagnostic events (newest last) for the in-app viewer.
  List<Map<String, Object?>> get diagnosticEvents =>
      ClientDiagnosticLog.instance.recent(80);

  int get diagnosticEventCount => ClientDiagnosticLog.instance.length;

  /// One readable line for a diagnostic event (used by the viewer).
  String formatDiagnosticEvent(Map<String, Object?> event) =>
      ClientDiagnosticLog.instance.formatLine(event);

  /// Wipes the local diagnostic log (the "delete" action in Settings).
  Future<void> clearDiagnostics() async {
    await ClientDiagnosticLog.instance.clear();
    ClientDiagnosticLog.instance.record(
      'diagnostics',
      'log_cleared',
      details: <String, Object?>{'by': 'user'},
    );
    notifyListeners();
  }
}
