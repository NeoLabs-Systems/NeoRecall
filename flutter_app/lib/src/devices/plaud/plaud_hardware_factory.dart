import 'plaud_hardware.dart';
import 'plaud_hardware_stub.dart'
    if (dart.library.io) 'plaud_hardware_io.dart'
    as impl;

PlaudHardware createPlaudHardware() => impl.createPlaudHardware();
