import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS declares every privacy permission used by native capture', () {
    final plist = File('macos/Runner/Info.plist').readAsStringSync();

    for (final key in <String>[
      'NSBluetoothAlwaysUsageDescription',
      'NSBluetoothPeripheralUsageDescription',
      'NSMicrophoneUsageDescription',
      'NSScreenCaptureDescription',
      'NSLocalNetworkUsageDescription',
    ]) {
      expect(plist, contains('<key>$key</key>'), reason: '$key is required');
    }
  });

  test('macOS uses a panel so compact capture can float above full screen', () {
    final window = File(
      'macos/Runner/MainFlutterWindow.swift',
    ).readAsStringSync();

    expect(window, contains('class MainFlutterWindow: NSPanel'));
    expect(window, contains('override var canBecomeKey: Bool { true }'));
  });
}
