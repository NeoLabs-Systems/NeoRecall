import 'dart:async';

/// Tunable timing for automatic device-storage sync.
///
/// A wearable that records on its own gives no signal when a new file appears,
/// so the app polls. [pollInterval] is deliberately short — recordings should
/// arrive on their own within seconds of being made, without anyone pressing a
/// sync button — while [maximumFailureBackoff] keeps a device that is out of
/// range, busy, or faulted from being retried at that rate indefinitely.
class DeviceStorageSyncPolicy {
  const DeviceStorageSyncPolicy({
    this.pollInterval = const Duration(seconds: 15),
    this.initialFailureBackoff = const Duration(seconds: 30),
    this.maximumFailureBackoff = const Duration(minutes: 5),
    this.failureBackoffMultiplier = 2,
  });

  final Duration pollInterval;
  final Duration initialFailureBackoff;
  final Duration maximumFailureBackoff;
  final int failureBackoffMultiplier;

  /// How long to stay quiet after [consecutiveFailures] failed sweeps.
  Duration backoffForFailures(int consecutiveFailures) {
    if (pollInterval <= Duration.zero ||
        initialFailureBackoff <= Duration.zero ||
        maximumFailureBackoff < initialFailureBackoff ||
        failureBackoffMultiplier < 1) {
      throw StateError('Invalid device storage sync policy.');
    }
    if (consecutiveFailures <= 0) return Duration.zero;
    var milliseconds = initialFailureBackoff.inMilliseconds;
    for (var index = 1; index < consecutiveFailures; index += 1) {
      milliseconds = (milliseconds * failureBackoffMultiplier).clamp(
        initialFailureBackoff.inMilliseconds,
        maximumFailureBackoff.inMilliseconds,
      );
      if (milliseconds == maximumFailureBackoff.inMilliseconds) break;
    }
    return Duration(milliseconds: milliseconds);
  }
}

/// Runs one sweep. Returns true when the sweep completed (with or without new
/// recordings); false or a thrown error counts as a failure for backoff.
typedef DeviceStorageSyncRunner =
    Future<bool> Function({required bool userInitiated});

typedef PeriodicTimerFactory =
    Timer Function(Duration interval, void Function(Timer) callback);

/// Drives automatic on-device recording sync so nothing has to be started by
/// hand — on every platform, including web.
///
/// The scheduler owns *when* a sweep runs and how failures back off; it knows
/// nothing about BLE or the ingest pipeline. That keeps the same policy behind
/// the periodic poll, the reconnect trigger, the app-resumed trigger, and the
/// manual button, instead of a separate timer per call site.
class DeviceStorageSyncScheduler {
  DeviceStorageSyncScheduler({
    required this.isEligible,
    required this.runSync,
    this.policy = const DeviceStorageSyncPolicy(),
    DateTime Function()? clock,
    PeriodicTimerFactory? createTimer,
  }) : _clock = clock ?? DateTime.now,
       _createTimer = createTimer ?? Timer.periodic;

  /// Whether a sweep may run right now (device linked, signed in, not recording).
  final bool Function() isEligible;
  final DeviceStorageSyncRunner runSync;
  final DeviceStorageSyncPolicy policy;
  final DateTime Function() _clock;
  final PeriodicTimerFactory _createTimer;

  Timer? _timer;
  Future<void>? _inFlight;
  /// Follow-up sweep shared by every request that arrived while a sweep was
  /// already running, so concurrent taps produce one extra sweep, not N.
  Future<void>? _queued;
  DateTime? _quietUntil;
  int _consecutiveFailures = 0;
  bool _disposed = false;

  bool get isRunning => _inFlight != null;
  bool get isPolling => _timer != null;

  /// The sweep currently in flight, if any. Callers that must take the device's
  /// transport over (a live capture claiming the BLE channel) await this after
  /// cancelling, so the drain is provably finished first.
  Future<void>? get activeSweep => _inFlight;

  /// Number of consecutive failed sweeps; exposed for diagnostics and tests.
  int get consecutiveFailures => _consecutiveFailures;

  void start() {
    if (_disposed || _timer != null) return;
    _timer = _createTimer(policy.pollInterval, (_) {
      unawaited(requestSync());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The device just linked (or relinked): drop any backoff and sweep at once,
  /// so a wearable that was carried around all day starts uploading on contact.
  void onDeviceLinked() {
    _consecutiveFailures = 0;
    _quietUntil = null;
    start();
    unawaited(requestSync());
  }

  /// The device went away; keep the timer (it is cheap and [isEligible] gates
  /// every tick) but forget the failure history so a reconnect starts clean.
  void onDeviceUnlinked() {
    _consecutiveFailures = 0;
    _quietUntil = null;
  }

  /// Runs a sweep when one is due.
  ///
  /// An automatic request is dropped while another sweep is in flight or while
  /// backing off. A [userInitiated] request ignores the backoff and waits for an
  /// in-flight sweep instead of being discarded, so the button always does
  /// something.
  Future<void> requestSync({bool userInitiated = false}) async {
    if (_disposed) return;
    final inFlight = _inFlight;
    if (inFlight != null) {
      if (!userInitiated) return;
      // Coalesce every request that lands during a sweep onto ONE follow-up.
      // Previously each waiter fell through and started its own sweep, so two
      // taps during an automatic sweep ran two more drains back to back against
      // the same connector.
      final queued = _queued;
      if (queued != null) return queued;
      final follow = _sweepAfter(inFlight);
      _queued = follow;
      try {
        await follow;
      } finally {
        if (identical(_queued, follow)) _queued = null;
      }
      return;
    }
    if (!userInitiated && _isQuiet()) return;
    if (!isEligible()) return;
    await _run(userInitiated);
  }

  /// Runs one user-initiated sweep once [previous] has finished.
  Future<void> _sweepAfter(Future<void> previous) async {
    await previous;
    if (_disposed || !isEligible()) return;
    await _run(true);
  }

  Future<void> _run(bool userInitiated) async {
    final future = _sweep(userInitiated);
    _inFlight = future;
    try {
      await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  bool _isQuiet() {
    final quietUntil = _quietUntil;
    if (quietUntil == null) return false;
    if (_clock().isBefore(quietUntil)) return true;
    _quietUntil = null;
    return false;
  }

  Future<void> _sweep(bool userInitiated) async {
    var succeeded = false;
    try {
      succeeded = await runSync(userInitiated: userInitiated);
    } catch (_) {
      succeeded = false;
    }
    if (succeeded) {
      _consecutiveFailures = 0;
      _quietUntil = null;
      return;
    }
    _consecutiveFailures += 1;
    _quietUntil = _clock().add(
      policy.backoffForFailures(_consecutiveFailures),
    );
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
