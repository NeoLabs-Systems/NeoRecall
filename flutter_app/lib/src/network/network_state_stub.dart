class NetworkState {
  const NetworkState({required this.connected, required this.unmetered});

  final bool connected;
  final bool unmetered;
}

Future<NetworkState> currentNetworkState() async =>
    const NetworkState(connected: true, unmetered: true);

Stream<NetworkState> networkAvailability() => Stream<NetworkState>.value(
  const NetworkState(connected: true, unmetered: true),
);
