import 'package:flutter/foundation.dart';

/// What the record button acts on.
///
/// One value, not a set of booleans that can disagree with each other. The Desk
/// is a peer here rather than a section of its own: it is another answer to
/// "where does this recording come from".
enum CaptureSource {
  phone,
  wearable,
  desk;

  static CaptureSource? fromName(String? name) {
    for (final value in CaptureSource.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// The initial capture-source policy shared by every recording entry point.
///
/// Keeping this separate from widgets prevents quick capture and the full
/// recorder from silently developing different defaults.
class CaptureSourceSelection {
  const CaptureSourceSelection({
    required this.microphone,
    required this.systemAudio,
    required this.bluetooth,
  });

  const CaptureSourceSelection.desktopMeeting()
    : microphone = true,
      systemAudio = true,
      bluetooth = false;

  factory CaptureSourceSelection.forPlatform({
    required bool web,
    required TargetPlatform platform,
    required bool preferBluetooth,
  }) {
    if (web) {
      return const CaptureSourceSelection(
        microphone: true,
        systemAudio: false,
        bluetooth: false,
      );
    }
    if (platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux) {
      return const CaptureSourceSelection.desktopMeeting();
    }
    final bluetooth = preferBluetooth;
    return CaptureSourceSelection(
      microphone: !bluetooth,
      systemAudio: false,
      bluetooth: bluetooth,
    );
  }

  final bool microphone;
  final bool systemAudio;
  final bool bluetooth;
}
