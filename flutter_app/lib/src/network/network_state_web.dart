import 'package:connectivity_plus/connectivity_plus.dart';

class NetworkState {
  const NetworkState({required this.connected, required this.unmetered});

  final bool connected;
  final bool unmetered;

  @override
  bool operator ==(Object other) =>
      other is NetworkState &&
      other.connected == connected &&
      other.unmetered == unmetered;

  @override
  int get hashCode => Object.hash(connected, unmetered);
}

NetworkState _fromResults(List<ConnectivityResult> results) => NetworkState(
  connected: !results.contains(ConnectivityResult.none),
  // Browsers do not expose Android/iOS metered-network capabilities. Treat an
  // available browser connection as eligible; the setting is a mobile-client
  // data guard, not a server-side upload policy.
  unmetered: !results.contains(ConnectivityResult.none),
);

Future<NetworkState> currentNetworkState() async =>
    _fromResults(await Connectivity().checkConnectivity());

Stream<NetworkState> networkAvailability() async* {
  yield await currentNetworkState();
  yield* Connectivity().onConnectivityChanged.map(_fromResults).distinct();
}
