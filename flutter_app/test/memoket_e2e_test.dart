import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/omi/memoket_e2e.dart';

void main() {
  test('host extras treat zero as the default live soak, not the floor', () {
    final config = MemoketE2eConfig.fromHost(liveMs: 0, reconnectGapMs: 0);
    expect(config.liveDuration, const Duration(seconds: 120));
    expect(config.reconnectGap, const Duration(seconds: 8));
    expect(config.idleHold, const Duration(seconds: 12));
  });

  test('host extras clamp an explicit live soak into the allowed window', () {
    expect(
      MemoketE2eConfig.fromHost(liveMs: 1).liveDuration,
      const Duration(seconds: 30),
    );
    expect(
      MemoketE2eConfig.fromHost(liveMs: 9999999).liveDuration,
      const Duration(minutes: 10),
    );
    expect(
      MemoketE2eConfig.fromHost(liveMs: 180000).liveDuration,
      const Duration(seconds: 180),
    );
  });

  test('PCM coverage uses the configured fraction of 16 kHz mono s16', () {
    const config = MemoketE2eConfig(minPcmFraction: 0.7);
    const live = Duration(seconds: 10);
    expect(config.expectedPcmBytes(live), 16000 * 2 * 10);
    expect(config.pcmCovers(config.expectedPcmBytes(live), live), isTrue);
    expect(
      config.pcmCovers((config.expectedPcmBytes(live) * 0.7).floor(), live),
      isTrue,
    );
    expect(
      config.pcmCovers((config.expectedPcmBytes(live) * 0.69).floor(), live),
      isFalse,
    );
  });

  test('a failed required step fails the report even with later skips', () {
    final report = MemoketE2eReport(
      config: const MemoketE2eConfig(),
      startedAt: DateTime.utc(2026, 9, 9),
      steps: const <MemoketE2eStepResult>[
        MemoketE2eStepResult(
          name: 'scan',
          status: MemoketE2eStepStatus.passed,
          durationMs: 10,
        ),
        MemoketE2eStepResult(
          name: 'connect',
          status: MemoketE2eStepStatus.failed,
          durationMs: 10,
          error: 'timeout',
        ),
        MemoketE2eStepResult(
          name: 'drain_soak_take',
          status: MemoketE2eStepStatus.skipped,
          durationMs: 0,
        ),
      ],
    );
    expect(report.allRequiredPassed, isFalse);
  });

  test('skipped steps do not fail a report whose required steps passed', () {
    final report = MemoketE2eReport(
      config: const MemoketE2eConfig(),
      startedAt: DateTime.utc(2026, 9, 9),
      steps: const <MemoketE2eStepResult>[
        MemoketE2eStepResult(
          name: 'scan',
          status: MemoketE2eStepStatus.passed,
          durationMs: 10,
        ),
        MemoketE2eStepResult(
          name: 'drain_soak_take',
          status: MemoketE2eStepStatus.skipped,
          durationMs: 0,
        ),
      ],
    );
    expect(report.allRequiredPassed, isTrue);
  });

  test('MemoketE2eRequest reads sparse host maps', () {
    final request = MemoketE2eRequest.fromMap(<String, Object?>{
      'liveMs': 90000,
    });
    expect(request.liveMs, 90000);
    expect(request.config.liveDuration, const Duration(seconds: 90));
  });
}
