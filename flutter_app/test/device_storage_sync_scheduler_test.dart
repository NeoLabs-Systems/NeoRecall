import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/devices/device_storage_sync_scheduler.dart';

class _FakeTimer implements Timer {
  bool _active = true;
  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

/// Drives the scheduler's periodic tick by hand so timing is deterministic.
class _ManualClock {
  DateTime now = DateTime.utc(2026, 1, 1);
  void advance(Duration by) => now = now.add(by);
}

void main() {
  test('polls automatically while eligible and stops sweeping when not', () async {
    var eligible = true;
    var sweeps = 0;
    void Function(Timer)? tick;
    final scheduler = DeviceStorageSyncScheduler(
      isEligible: () => eligible,
      runSync: ({required bool userInitiated}) async {
        sweeps += 1;
        return true;
      },
      createTimer: (interval, callback) {
        tick = callback;
        return _FakeTimer();
      },
    );
    addTearDown(scheduler.dispose);

    scheduler.start();
    expect(scheduler.isPolling, isTrue);

    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 1);

    // No user action is needed for the next sweep: polling is the mechanism.
    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 2);

    eligible = false;
    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 2, reason: 'a sweep must not run while it is not eligible');
  });

  test('a failing device backs off instead of being polled every tick', () async {
    final clock = _ManualClock();
    var sweeps = 0;
    var succeed = false;
    void Function(Timer)? tick;
    const policy = DeviceStorageSyncPolicy(
      pollInterval: Duration(seconds: 15),
      initialFailureBackoff: Duration(seconds: 30),
      maximumFailureBackoff: Duration(minutes: 2),
    );
    final scheduler = DeviceStorageSyncScheduler(
      isEligible: () => true,
      runSync: ({required bool userInitiated}) async {
        sweeps += 1;
        return succeed;
      },
      policy: policy,
      clock: () => clock.now,
      createTimer: (interval, callback) {
        tick = callback;
        return _FakeTimer();
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.start();

    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 1);
    expect(scheduler.consecutiveFailures, 1);

    // Still inside the backoff window: the tick is skipped.
    clock.advance(const Duration(seconds: 15));
    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 1);

    clock.advance(const Duration(seconds: 20));
    tick!(_FakeTimer());
    await pumpEventQueue();
    expect(sweeps, 2);
    expect(scheduler.consecutiveFailures, 2);

    // A user-initiated sweep ignores the backoff so the button always acts.
    succeed = true;
    await scheduler.requestSync(userInitiated: true);
    expect(sweeps, 3);
    expect(scheduler.consecutiveFailures, 0, reason: 'success clears backoff');
  });

  test('backoff grows and is capped', () {
    const policy = DeviceStorageSyncPolicy(
      initialFailureBackoff: Duration(seconds: 30),
      maximumFailureBackoff: Duration(minutes: 2),
      failureBackoffMultiplier: 2,
    );
    expect(policy.backoffForFailures(0), Duration.zero);
    expect(policy.backoffForFailures(1), const Duration(seconds: 30));
    expect(policy.backoffForFailures(2), const Duration(minutes: 1));
    expect(policy.backoffForFailures(3), const Duration(minutes: 2));
    expect(policy.backoffForFailures(9), const Duration(minutes: 2));
  });

  test('linking a device clears backoff and sweeps at once', () async {
    var sweeps = 0;
    final scheduler = DeviceStorageSyncScheduler(
      isEligible: () => true,
      runSync: ({required bool userInitiated}) async {
        sweeps += 1;
        return false;
      },
      createTimer: (interval, callback) => _FakeTimer(),
    );
    addTearDown(scheduler.dispose);

    scheduler.onDeviceLinked();
    await pumpEventQueue();
    expect(sweeps, 1);
    expect(scheduler.consecutiveFailures, 1);
    expect(scheduler.isPolling, isTrue, reason: 'linking starts the poll');

    // Reconnecting is the user's signal that the device is reachable again.
    scheduler.onDeviceLinked();
    await pumpEventQueue();
    expect(sweeps, 2);
  });

  test('an automatic request is dropped while a sweep is in flight', () async {
    final gate = Completer<bool>();
    var sweeps = 0;
    final scheduler = DeviceStorageSyncScheduler(
      isEligible: () => true,
      runSync: ({required bool userInitiated}) {
        sweeps += 1;
        return gate.future;
      },
      createTimer: (interval, callback) => _FakeTimer(),
    );
    addTearDown(scheduler.dispose);

    final first = scheduler.requestSync();
    await pumpEventQueue();
    expect(sweeps, 1);
    expect(scheduler.isRunning, isTrue);

    await scheduler.requestSync();
    expect(sweeps, 1, reason: 'overlapping drains would corrupt the BLE channel');

    // A user-initiated request waits for the in-flight sweep, then runs.
    final manual = scheduler.requestSync(userInitiated: true);
    gate.complete(true);
    await first;
    await manual;
    expect(sweeps, 2);
    expect(scheduler.isRunning, isFalse);
  });

  test('a thrown sweep counts as a failure rather than escaping', () async {
    final scheduler = DeviceStorageSyncScheduler(
      isEligible: () => true,
      runSync: ({required bool userInitiated}) async =>
          throw StateError('device went away'),
      createTimer: (interval, callback) => _FakeTimer(),
    );
    addTearDown(scheduler.dispose);

    await scheduler.requestSync(userInitiated: true);
    expect(scheduler.consecutiveFailures, 1);
  });
}
