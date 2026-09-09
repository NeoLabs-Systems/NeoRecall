part of '../../main_controller.dart';

/// Per-user Nextcloud backup (write-only copies of audio and account data).
mixin CloudController on ChangeNotifier {
  NeoRecallApiClient get api;

  Map<String, dynamic> cloudStatus = const <String, dynamic>{
    'connected': false,
    'status': 'disconnected',
  };
  bool loadingCloud = false;
  bool cloudBusy = false;
  Timer? _cloudPollTimer;

  String get cloudStatusName =>
      cloudStatus['status'] as String? ?? 'disconnected';
  bool get cloudConnected => cloudStatus['connected'] == true;
  bool get cloudConnecting => cloudStatusName == 'connecting';
  String? get cloudLoginUrl => cloudStatus['loginUrl'] as String?;

  Future<void> loadCloudStatus() async {
    loadingCloud = true;
    notifyListeners();
    try {
      final response = await api.request('GET', '/api/v1/cloud');
      _applyCloud(response);
    } catch (_) {
      cloudStatus = const <String, dynamic>{
        'connected': false,
        'status': 'disconnected',
      };
    } finally {
      loadingCloud = false;
      notifyListeners();
    }
  }

  Future<String?> startCloudLogin(String instanceUrl) async {
    cloudBusy = true;
    notifyListeners();
    try {
      final response = await api.request(
        'POST',
        '/api/v1/cloud/nextcloud/login',
        body: {'instanceUrl': instanceUrl},
      );
      _applyCloud(response);
      _armCloudPoll();
      final url = cloudLoginUrl;
      if (url != null) await openCloudLoginUrl(url);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      cloudBusy = false;
      notifyListeners();
    }
  }

  Future<void> pollCloudLogin() async {
    if (!cloudConnecting && cloudLoginUrl == null) return;
    try {
      final response = await api.request('POST', '/api/v1/cloud/nextcloud/poll');
      _applyCloud(response);
      if (cloudConnected) _cloudPollTimer?.cancel();
    } catch (_) {
      // Keep the waiting state; the next tick retries.
    }
    notifyListeners();
  }

  Future<String?> patchCloud(Map<String, dynamic> changes) async {
    cloudBusy = true;
    notifyListeners();
    try {
      final response = await api.request('PATCH', '/api/v1/cloud', body: changes);
      _applyCloud(response);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      cloudBusy = false;
      notifyListeners();
    }
  }

  Future<String?> backupCloudNow() async {
    cloudBusy = true;
    notifyListeners();
    try {
      final response = await api.request('POST', '/api/v1/cloud/backup');
      _applyCloud(response);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      cloudBusy = false;
      notifyListeners();
    }
  }

  Future<String?> disconnectCloud() async {
    cloudBusy = true;
    notifyListeners();
    try {
      _cloudPollTimer?.cancel();
      await api.request('DELETE', '/api/v1/cloud');
      cloudStatus = const <String, dynamic>{
        'connected': false,
        'status': 'disconnected',
      };
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      cloudBusy = false;
      notifyListeners();
    }
  }

  Future<void> cancelCloudLogin() async {
    _cloudPollTimer?.cancel();
    await disconnectCloud();
  }

  Future<void> openCloudLoginUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void disposeCloud() {
    _cloudPollTimer?.cancel();
  }

  void _applyCloud(dynamic response) {
    if (response is Map && response['cloud'] is Map) {
      cloudStatus = Map<String, dynamic>.from(response['cloud'] as Map);
    }
    if (cloudConnecting) {
      _armCloudPoll();
    } else {
      _cloudPollTimer?.cancel();
    }
  }

  void _armCloudPoll() {
    _cloudPollTimer?.cancel();
    _cloudPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(pollCloudLogin());
    });
  }
}
