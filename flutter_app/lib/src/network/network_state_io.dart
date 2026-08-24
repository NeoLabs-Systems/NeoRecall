import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

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

const MethodChannel _androidChannel = MethodChannel(
  'systems.neolabs.neorecall/background_capture',
);

NetworkState _fromResults(List<ConnectivityResult> results) {
  final connected = !results.contains(ConnectivityResult.none);
  return NetworkState(
    connected: connected,
    unmetered:
        connected &&
        (results.contains(ConnectivityResult.wifi) ||
            results.contains(ConnectivityResult.ethernet)),
  );
}

Future<NetworkState> currentNetworkState() async {
  if (Platform.isAndroid) {
    try {
      final value = await _androidChannel.invokeMapMethod<String, dynamic>(
        'networkRuntimeState',
      );
      if (value != null) {
        return NetworkState(
          connected: value['connected'] == true,
          unmetered: value['unmetered'] == true,
        );
      }
    } catch (_) {
      // A pre-upgrade Android host can still use the transport-level fallback.
    }
  }
  return _fromResults(await Connectivity().checkConnectivity());
}

Stream<NetworkState> networkAvailability() async* {
  yield await currentNetworkState();
  await for (final _ in Connectivity().onConnectivityChanged) {
    yield await currentNetworkState();
  }
}
