class RecordingSchedule {
  const RecordingSchedule({
    required this.enabled,
    required this.startMinute,
    required this.endMinute,
  }) : assert(startMinute >= 0 && startMinute < minutesPerDay),
       assert(endMinute >= 0 && endMinute < minutesPerDay);

  static const int minutesPerDay = 24 * 60;

  final bool enabled;
  final int startMinute;
  final int endMinute;

  bool allows(DateTime localTime) {
    if (!enabled || startMinute == endMinute) return true;
    final minute = localTime.hour * 60 + localTime.minute;
    if (startMinute < endMinute) {
      return minute >= startMinute && minute < endMinute;
    }
    // A window such as 22:00–06:00 crosses local midnight.
    return minute >= startMinute || minute < endMinute;
  }

  DateTime nextBoundary(DateTime localTime) {
    if (!enabled || startMinute == endMinute) {
      return localTime.add(const Duration(days: 1));
    }
    final targetMinute = allows(localTime) ? endMinute : startMinute;
    var boundary = DateTime(
      localTime.year,
      localTime.month,
      localTime.day,
      targetMinute ~/ 60,
      targetMinute % 60,
    );
    if (!boundary.isAfter(localTime)) {
      boundary = DateTime(
        localTime.year,
        localTime.month,
        localTime.day + 1,
        targetMinute ~/ 60,
        targetMinute % 60,
      );
    }
    return boundary;
  }
}
