/// How much of a device-side take actually arrived over the live stream.
///
/// A wearable records to its own flash while streaming to the phone, and the
/// phone may only delete the device's copy once it can show it holds the same
/// audio. That claim has to be measured, not assumed: this counts the seconds
/// that genuinely arrived, so a stream which died mid-take can never pass for
/// one that carried the whole thing.
class LiveCoverage {
  /// The longest gap between frames still counted as continuous audio. Anything
  /// longer is a hole in the live stream, and the seconds inside it exist only
  /// on the device.
  static const Duration maximumFrameGap = Duration(seconds: 3);

  String? _fileId;
  DateTime? _lastFrameAt;
  int _coveredMs = 0;

  /// The device file currently being measured, if any.
  String? get fileId => _fileId;

  /// Seconds of live audio received for that file.
  int get seconds => _coveredMs ~/ 1000;

  /// True when the live stream has been silent longer than [maximumFrameGap]
  /// at [at]. A take that went quiet before stop is not fully on the phone,
  /// even if the missing tail is only a few seconds — those seconds exist
  /// only on the device.
  bool stalledAt(DateTime at) {
    final last = _lastFrameAt;
    if (last == null) return _coveredMs == 0;
    return at.difference(last) > maximumFrameGap;
  }

  /// Records a frame of [fileId] arriving at [at].
  ///
  /// Time is added gap by gap rather than from the first frame to the last: a
  /// stream that stops for a quarter of an hour and then delivers one more
  /// frame has covered seconds, not a quarter of an hour.
  void frame(String fileId, DateTime at) {
    if (_fileId != fileId) {
      _fileId = fileId;
      _lastFrameAt = null;
      _coveredMs = 0;
    }
    final last = _lastFrameAt;
    if (last != null) {
      final gap = at.difference(last);
      if (gap > Duration.zero && gap <= maximumFrameGap) {
        _coveredMs += gap.inMilliseconds;
      }
    }
    _lastFrameAt = at;
  }

  void reset() {
    _fileId = null;
    _lastFrameAt = null;
    _coveredMs = 0;
  }
}
