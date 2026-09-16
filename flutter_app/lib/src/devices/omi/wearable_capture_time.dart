/// When a wearable recorded something, as a UTC instant.
///
/// Device clocks are set from unix time (or from UTC wall-clock digits). A
/// `YYYYMMDDHHMMSS` stamp is that UTC clock, not the phone's local zone.
/// Reading it with `DateTime(...)` then `.toUtc()` shifted every offline
/// import by the phone offset — two hours in CEST.
class WearableCaptureTime {
  static final RegExp _stamp = RegExp(
    r'(\d{4})(\d{2})(\d{2})_?(\d{2})(\d{2})(\d{2})',
  );

  /// Compact stamp (`20260906_184302` or `20260906184302`) as UTC.
  static DateTime? parseUtcStamp(String source) {
    final match = _stamp.firstMatch(source);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }

  /// `YYYY-MM-DD` (or any date-only prefix) as UTC midnight.
  static DateTime? parseUtcDate(String source) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(source);
    if (match == null) return null;
    return DateTime.utc(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// ISO-8601 from a device. A trailing `Z`/offset is honored; a naive string
  /// is the device's UTC clock, not the phone's local zone.
  static DateTime? parseDeviceInstant(String? source) {
    if (source == null || source.isEmpty) return null;
    final parsed = DateTime.tryParse(source);
    if (parsed == null) return null;
    if (parsed.isUtc) return parsed;
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );
  }

  static DateTime? fromUnixSeconds(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    return _plausible(
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
    );
  }

  static DateTime? fromUnixMillis(int? millis) {
    if (millis == null || millis <= 0) return null;
    return _plausible(DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true));
  }

  /// Digits the phone writes onto a device that takes a wall-clock string.
  static String formatUtcStamp(DateTime time) {
    final utc = time.toUtc();
    String pad(int value, int width) => value.toString().padLeft(width, '0');
    return '${pad(utc.year, 4)}${pad(utc.month, 2)}${pad(utc.day, 2)}'
        '${pad(utc.hour, 2)}${pad(utc.minute, 2)}${pad(utc.second, 2)}';
  }

  static String formatUtcDate(DateTime time) {
    final utc = time.toUtc();
    String pad(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${pad(utc.month)}-${pad(utc.day)}';
  }

  static DateTime? _plausible(DateTime time) {
    if (time.year < 2015 || time.year > 2100) return null;
    return time;
  }
}
