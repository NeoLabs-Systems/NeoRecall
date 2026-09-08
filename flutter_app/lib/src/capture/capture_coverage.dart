/// How much of a finished take actually reached durable storage.
///
/// A recording session and the audio it produced are two different facts. A
/// wearable whose live stream dies keeps the session open while delivering
/// nothing, and the result is a short transcript of a long conversation with
/// nothing anywhere saying that most of it was never captured. Comparing the
/// two is what turns that silent loss into something the user is told about.
library;

/// Below this share of the elapsed session, a take is reported as incomplete.
const double kMinimumCaptureCoverage = 0.6;

/// Takes shorter than this are not judged at all: start-up and flush timing
/// dominate them, so their coverage would produce false alarms rather than
/// protection.
const int kCoverageFloorMs = 60000;

/// The audio missing from a finished take, or null when it is complete enough.
///
/// [capturedMs] counts only what was written to the durable ledger, never what
/// a device claimed to be sending.
Duration? captureShortfall({required int elapsedMs, required int capturedMs}) {
  if (elapsedMs < kCoverageFloorMs) return null;
  final captured = capturedMs < 0 ? 0 : capturedMs;
  if (captured / elapsedMs >= kMinimumCaptureCoverage) return null;
  return Duration(milliseconds: elapsedMs - captured);
}
