part of '../../main_controller.dart';

/// Authorized OAuth companions (NeoAgent and MCP clients) for this account.
mixin IntegrationsController on ChangeNotifier {
  NeoRecallApiClient get api;
  String get backendUrl;

  List<Map<String, dynamic>> integrations = const <Map<String, dynamic>>[];
  bool loadingIntegrations = false;

  String get mcpEndpointUrl {
    final root = backendUrl.replaceFirst(RegExp(r'/$'), '');
    return '$root/mcp';
  }

  Future<void> loadIntegrations() async {
    loadingIntegrations = true;
    notifyListeners();
    try {
      final response = await api.request('GET', '/api/v1/integrations');
      final items = response is Map ? response['integrations'] : null;
      integrations = items is List
          ? items
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList()
          : const <Map<String, dynamic>>[];
    } catch (_) {
      integrations = const <Map<String, dynamic>>[];
    } finally {
      loadingIntegrations = false;
      notifyListeners();
    }
  }

  Future<bool> revokeIntegration(String clientId) async {
    try {
      await api.request('DELETE', '/api/v1/integrations/$clientId');
      integrations = integrations
          .where((item) => item['id'] != clientId)
          .toList();
      notifyListeners();
      return true;
    } catch (exception) {
      return false;
    }
  }
}
