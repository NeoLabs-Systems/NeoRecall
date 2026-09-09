/// Web and other non-IO targets have no app-specific files directory.
class MemoketE2eReportSink {
  static Future<String?> writeStatus(Map<String, Object?> report) async => null;

  static Future<String?> writeReport(Map<String, Object?> report) async => null;
}
