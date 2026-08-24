import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/desktop/meeting_detector.dart';
import 'package:neorecall/src/desktop/meeting_detector_io.dart';

void main() {
  test('parses macOS process snapshots without depending on spacing', () {
    final processes = parsePosixProcessSnapshot(
      '  42 /Applications/zoom.us.app/Contents/MacOS/zoom.us zoom.us --meeting\n'
      ' 105 /usr/bin/helper helper --quiet\n',
    );

    expect(processes, hasLength(2));
    expect(processes.first.pid, 42);
    expect(processes.first.executable, contains('zoom.us'));
  });

  test('parses Windows tasklist snapshots', () {
    final processes = parseWindowsProcessSnapshot(
      '"Zoom.exe","4120","Console","1","120,000 K"\r\n',
    );

    expect(processes, hasLength(1));
    expect(processes.single.pid, 4120);
    expect(processes.single.executable, 'Zoom.exe');
  });

  test('meeting signatures classify executable paths and arguments', () {
    const signature = MeetingApplicationSignature(
      application: 'Zoom',
      executableTokens: <String>['cpthost'],
    );

    expect(
      signature.matches(
        const DesktopProcess(
          pid: 9,
          executable: '/Applications/zoom.us.app/Contents/Frameworks/CptHost',
        ),
      ),
      isTrue,
    );
  });

  group('MeetingActivityTracker', () {
    const zoom = MeetingApplicationSignature(
      application: 'Zoom',
      executableTokens: <String>['zoom.us'],
    );
    const config = MeetingDetectionConfig(
      requiredStableSnapshots: 2,
      applicationSignatures: <MeetingApplicationSignature>[zoom],
    );
    const baselineProcess = DesktopProcess(pid: 10, executable: 'zoom.us');
    const newProcess = DesktopProcess(pid: 20, executable: 'zoom.us');
    final now = DateTime(2026, 8, 24);

    test('does not treat an already-running app as a new meeting', () {
      final tracker = MeetingActivityTracker(
        config: config,
        baseline: const <DesktopProcess>[baselineProcess],
      );

      expect(
        tracker.evaluate(const <DesktopProcess>[baselineProcess], now),
        isEmpty,
      );
      expect(
        tracker.evaluate(const <DesktopProcess>[baselineProcess], now),
        isEmpty,
      );
    });

    test('requires stable presence before emitting started', () {
      final tracker = MeetingActivityTracker(
        config: config,
        baseline: const [],
      );

      expect(
        tracker.evaluate(const <DesktopProcess>[newProcess], now),
        isEmpty,
      );
      final activities = tracker.evaluate(const <DesktopProcess>[
        newProcess,
      ], now.add(const Duration(seconds: 4)));

      expect(activities, hasLength(1));
      expect(activities.single.type, MeetingActivityType.started);
      expect(activities.single.application, 'Zoom');
    });

    test('requires stable absence before emitting ended', () {
      final tracker = MeetingActivityTracker(
        config: config,
        baseline: const [],
      );
      tracker.evaluate(const <DesktopProcess>[newProcess], now);
      tracker.evaluate(const <DesktopProcess>[newProcess], now);

      expect(tracker.evaluate(const <DesktopProcess>[], now), isEmpty);
      final activities = tracker.evaluate(
        const <DesktopProcess>[],
        now.add(const Duration(seconds: 4)),
      );

      expect(activities, hasLength(1));
      expect(activities.single.type, MeetingActivityType.ended);
    });

    test('detects a new session after a baseline process exits', () {
      final tracker = MeetingActivityTracker(
        config: config,
        baseline: const <DesktopProcess>[baselineProcess],
      );
      tracker.evaluate(const <DesktopProcess>[], now);

      expect(
        tracker.evaluate(const <DesktopProcess>[newProcess], now),
        isEmpty,
      );
      final activities = tracker.evaluate(const <DesktopProcess>[
        newProcess,
      ], now.add(const Duration(seconds: 4)));

      expect(activities.single.type, MeetingActivityType.started);
    });
  });
}
