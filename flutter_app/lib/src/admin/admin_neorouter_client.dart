import '../api_client.dart';

/// What one kind of work has on the connected router: how many models it
/// lists, how many of those are NeoRouter's own auto models, and how many more
/// the key may not use. [error] is set when the router refused this list.
class NeoRouterOffer {
  const NeoRouterOffer({
    required this.models,
    required this.auto,
    required this.notAllowed,
    this.error,
  });

  final int models;
  final int auto;
  final int notAllowed;
  final String? error;

  bool get empty => models + auto == 0;
}

/// The server-wide NeoRouter connection as the admin API reports it.
class NeoRouterState {
  const NeoRouterState({
    required this.connected,
    required this.address,
    required this.reachable,
    required this.unreachableReason,
    required this.roles,
    required this.activeRoles,
    required this.offers,
  });

  final bool connected;
  final String? address;

  /// False when the router did not answer the last time the server asked.
  final bool reachable;
  final String? unreachableReason;

  /// Every kind of work the router can take, in display order.
  final List<String> roles;

  /// The ones switched on.
  final Set<String> activeRoles;
  final Map<String, NeoRouterOffer> offers;

  factory NeoRouterState.fromJson(Map<String, dynamic> json) {
    final offer = json['offer'];
    final counts = offer is Map ? offer['roles'] : null;
    final hidden = offer is Map ? offer['notAllowed'] : null;
    final offers = <String, NeoRouterOffer>{};
    if (counts is Map) {
      for (final entry in counts.entries) {
        final value = entry.value is Map ? entry.value as Map : const {};
        offers[entry.key.toString()] = NeoRouterOffer(
          models: int.tryParse('${value['models']}') ?? 0,
          auto: int.tryParse('${value['auto']}') ?? 0,
          notAllowed: hidden is Map
              ? int.tryParse('${hidden[entry.key]}') ?? 0
              : 0,
          error: value['error']?.toString(),
        );
      }
    }
    List<String> strings(Object? value) => value is List
        ? value.map((item) => item.toString()).toList(growable: false)
        : const <String>[];
    return NeoRouterState(
      connected: json['connected'] == true,
      address: json['address']?.toString(),
      reachable: json['reachable'] == true,
      unreachableReason: json['unreachableReason']?.toString(),
      roles: strings(json['allRoles']),
      activeRoles: strings(json['roles']).toSet(),
      offers: offers,
    );
  }
}

/// A started sign-in: the NeoRouter page to approve on and the code it shows.
class NeoRouterSignIn {
  const NeoRouterSignIn({
    required this.id,
    required this.url,
    required this.userCode,
  });

  final String id;
  final String url;
  final String userCode;
}

/// The NeoRouter endpoints of the admin API.
class AdminNeoRouterClient {
  const AdminNeoRouterClient(this.api);

  final NeoRecallApiClient api;

  static const String _base = '/api/v1/admin/neorouter';

  Future<NeoRouterState> load() async => NeoRouterState.fromJson(
    Map<String, dynamic>.from(await api.request('GET', _base) as Map),
  );

  Future<NeoRouterSignIn> begin(String address) async {
    final body =
        await api.request(
              'POST',
              '$_base/connect',
              body: <String, dynamic>{'address': address},
            )
            as Map;
    return NeoRouterSignIn(
      id: body['id'].toString(),
      url: body['url'].toString(),
      userCode: body['userCode']?.toString() ?? '',
    );
  }

  /// `pending`, `completed` or `failed` (with [error] saying why).
  Future<({String status, String? error})> poll(String id) async {
    final body = await api.request('GET', '$_base/connect/$id') as Map;
    return (
      status: body['status'].toString(),
      error: body['error']?.toString(),
    );
  }

  Future<void> setRoles(Iterable<String> roles) => api.request(
    'PUT',
    '$_base/roles',
    body: <String, dynamic>{'roles': roles.toList(growable: false)},
  );

  Future<void> disconnect() => api.request('DELETE', _base);
}
