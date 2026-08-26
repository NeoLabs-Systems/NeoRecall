import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/capture/capture_defaults.dart';

void main() {
  test('desktop defaults to microphone and device audio together', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      final selection = CaptureSourceSelection.forPlatform(
        web: false,
        platform: platform,
        preferBluetooth: true,
      );

      expect(selection.microphone, isTrue);
      expect(selection.systemAudio, isTrue);
      expect(selection.bluetooth, isFalse);
    }
  });

  test('mobile preserves the saved Bluetooth preference', () {
    final selection = CaptureSourceSelection.forPlatform(
      web: false,
      platform: TargetPlatform.android,
      preferBluetooth: true,
    );

    expect(selection.microphone, isFalse);
    expect(selection.systemAudio, isFalse);
    expect(selection.bluetooth, isTrue);
  });

  test('web starts conservatively with microphone only', () {
    final selection = CaptureSourceSelection.forPlatform(
      web: true,
      platform: TargetPlatform.macOS,
      preferBluetooth: true,
    );

    expect(selection.microphone, isTrue);
    expect(selection.systemAudio, isFalse);
    expect(selection.bluetooth, isFalse);
  });
}
