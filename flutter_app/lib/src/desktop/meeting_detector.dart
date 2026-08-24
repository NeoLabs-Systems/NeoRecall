import 'dart:async';

import 'meeting_detector_stub.dart'
    if (dart.library.io) 'meeting_detector_io.dart'
    as implementation;

enum MeetingActivityType { started, ended }

class MeetingActivity {
  const MeetingActivity({
    required this.type,
    required this.application,
    required this.detectedAt,
  });

  final MeetingActivityType type;
  final String application;
  final DateTime detectedAt;
}

abstract interface class MeetingDetector {
  Stream<MeetingActivity> get activities;

  Future<void> start();

  Future<void> dispose();
}

MeetingDetector createMeetingDetector() =>
    implementation.createMeetingDetector();
