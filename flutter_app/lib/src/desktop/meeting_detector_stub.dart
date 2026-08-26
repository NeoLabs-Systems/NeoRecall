import 'dart:async';

import 'meeting_detector.dart';

MeetingDetector createMeetingDetector() => _UnavailableMeetingDetector();

class _UnavailableMeetingDetector implements MeetingDetector {
  const _UnavailableMeetingDetector();

  @override
  Stream<MeetingActivity> get activities =>
      const Stream<MeetingActivity>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> dispose() async {}
}
