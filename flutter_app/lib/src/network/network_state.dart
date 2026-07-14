export 'network_state_stub.dart'
    if (dart.library.io) 'network_state_io.dart'
    if (dart.library.html) 'network_state_web.dart';
