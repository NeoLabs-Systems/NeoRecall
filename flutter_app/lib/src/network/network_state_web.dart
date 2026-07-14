import 'package:connectivity_plus/connectivity_plus.dart';

Stream<bool> networkAvailability() => Connectivity().onConnectivityChanged
    .map((results) => !results.contains(ConnectivityResult.none))
    .distinct();
