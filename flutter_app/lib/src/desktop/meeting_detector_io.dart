import 'dart:async';
import 'dart:io';

import 'meeting_detector.dart';

MeetingDetector createMeetingDetector() => DesktopMeetingDetector();

class MeetingDetectionConfig {
  const MeetingDetectionConfig({
    this.pollInterval = const Duration(seconds: 4),
    this.requiredStableSnapshots = 2,
    this.applicationSignatures = defaultApplicationSignatures,
  }) : assert(requiredStableSnapshots > 0);

  final Duration pollInterval;
  final int requiredStableSnapshots;
  final List<MeetingApplicationSignature> applicationSignatures;

  static const List<MeetingApplicationSignature> defaultApplicationSignatures =
      <MeetingApplicationSignature>[
        MeetingApplicationSignature(
          application: 'Zoom',
          executableTokens: <String>['zoom.us', 'zoom.exe', 'cpthost'],
        ),
        MeetingApplicationSignature(
          application: 'Microsoft Teams',
          executableTokens: <String>['msteams', 'teams.exe'],
        ),
        MeetingApplicationSignature(
          application: 'Webex',
          executableTokens: <String>[
            'webex.exe',
            'webexmta',
            'ciscocollabhost',
          ],
        ),
        MeetingApplicationSignature(
          application: 'FaceTime',
          executableTokens: <String>['facetime.app'],
        ),
      ];
}

class MeetingApplicationSignature {
  const MeetingApplicationSignature({
    required this.application,
    required this.executableTokens,
  });

  final String application;
  final List<String> executableTokens;

  bool matches(DesktopProcess process) {
    final value = '${process.executable} ${process.arguments}'.toLowerCase();
    return executableTokens.any((token) => value.contains(token.toLowerCase()));
  }
}

class DesktopProcess {
  const DesktopProcess({
    required this.pid,
    required this.executable,
    this.arguments = '',
  });

  final int pid;
  final String executable;
  final String arguments;
}

Map<String, Set<int>> classifyMeetingProcesses(
  List<DesktopProcess> processes,
  List<MeetingApplicationSignature> signatures,
) {
  final matches = <String, Set<int>>{};
  for (final signature in signatures) {
    matches[signature.application] = <int>{
      for (final process in processes)
        if (signature.matches(process)) process.pid,
    };
  }
  return matches;
}

/// Pure meeting lifecycle state machine. Process I/O stays in the detector;
/// stability and baseline behavior can therefore be verified deterministically.
class MeetingActivityTracker {
  MeetingActivityTracker({
    required this.config,
    required List<DesktopProcess> baseline,
  }) : _baseline = classifyMeetingProcesses(
         baseline,
         config.applicationSignatures,
       );

  final MeetingDetectionConfig config;
  final Map<String, Set<int>> _baseline;
  final Map<String, int> _presentCounts = <String, int>{};
  final Map<String, int> _absentCounts = <String, int>{};
  final Set<String> _activeApplications = <String>{};

  List<MeetingActivity> evaluate(
    List<DesktopProcess> processes,
    DateTime detectedAt,
  ) {
    final activities = <MeetingActivity>[];
    final current = classifyMeetingProcesses(
      processes,
      config.applicationSignatures,
    );
    for (final signature in config.applicationSignatures) {
      final application = signature.application;
      final currentPids = current[application] ?? const <int>{};
      final baselinePids = _baseline[application] ?? const <int>{};
      final hasNewSession = currentPids.difference(baselinePids).isNotEmpty;

      if (hasNewSession) {
        _absentCounts[application] = 0;
        final count = (_presentCounts[application] ?? 0) + 1;
        _presentCounts[application] = count;
        if (count >= config.requiredStableSnapshots &&
            _activeApplications.add(application)) {
          activities.add(
            MeetingActivity(
              type: MeetingActivityType.started,
              application: application,
              detectedAt: detectedAt,
            ),
          );
        }
        continue;
      }

      _presentCounts[application] = 0;
      if (!_activeApplications.contains(application)) continue;
      final count = (_absentCounts[application] ?? 0) + 1;
      _absentCounts[application] = count;
      if (count >= config.requiredStableSnapshots) {
        _activeApplications.remove(application);
        _absentCounts[application] = 0;
        activities.add(
          MeetingActivity(
            type: MeetingActivityType.ended,
            application: application,
            detectedAt: detectedAt,
          ),
        );
      }
    }
    return activities;
  }
}

class DesktopMeetingDetector implements MeetingDetector {
  DesktopMeetingDetector({this.config = const MeetingDetectionConfig()});

  final MeetingDetectionConfig config;
  final StreamController<MeetingActivity> _activities =
      StreamController<MeetingActivity>.broadcast();
  Timer? _timer;
  MeetingActivityTracker? _tracker;
  bool _polling = false;
  bool _disposed = false;

  @override
  Stream<MeetingActivity> get activities => _activities.stream;

  @override
  Future<void> start() async {
    if (_disposed ||
        _timer != null ||
        !(Platform.isMacOS || Platform.isWindows)) {
      return;
    }
    final baseline = await _processSnapshot();
    if (_disposed) return;
    if (baseline != null) {
      _tracker = MeetingActivityTracker(config: config, baseline: baseline);
    }
    _timer = Timer.periodic(config.pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final current = await _processSnapshot();
      if (_disposed || current == null) return;
      if (_tracker == null) {
        _tracker = MeetingActivityTracker(config: config, baseline: current);
        return;
      }
      final activities = _tracker?.evaluate(current, DateTime.now());
      if (activities == null) return;
      for (final activity in activities) {
        _emit(activity);
      }
    } finally {
      _polling = false;
    }
  }

  Future<List<DesktopProcess>?> _processSnapshot() async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('ps', <String>[
          '-axo',
          'pid=,comm=,args=',
        ]);
        if (result.exitCode != 0) return null;
        return parsePosixProcessSnapshot(result.stdout.toString());
      }
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', <String>[
          '/fo',
          'csv',
          '/nh',
        ]);
        if (result.exitCode != 0) return null;
        return parseWindowsProcessSnapshot(result.stdout.toString());
      }
    } on ProcessException {
      return null;
    }
    return null;
  }

  void _emit(MeetingActivity activity) {
    if (!_disposed) _activities.add(activity);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _activities.close();
  }
}

List<DesktopProcess> parsePosixProcessSnapshot(String value) {
  final processes = <DesktopProcess>[];
  for (final line in value.split('\n')) {
    final match = RegExp(r'^\s*(\d+)\s+(\S+)\s*(.*)$').firstMatch(line);
    if (match == null) continue;
    final pid = int.tryParse(match.group(1)!);
    if (pid == null) continue;
    processes.add(
      DesktopProcess(
        pid: pid,
        executable: match.group(2)!,
        arguments: match.group(3) ?? '',
      ),
    );
  }
  return processes;
}

List<DesktopProcess> parseWindowsProcessSnapshot(String value) {
  final processes = <DesktopProcess>[];
  final row = RegExp(r'^"([^"]+)","(\d+)"');
  for (final line in value.split('\n')) {
    final match = row.firstMatch(line.trim());
    if (match == null) continue;
    processes.add(
      DesktopProcess(
        pid: int.parse(match.group(2)!),
        executable: match.group(1)!,
      ),
    );
  }
  return processes;
}
