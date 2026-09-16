import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Writes harness progress where `adb pull` can read it without root.
class MemoketE2eReportSink {
  static const statusName = 'memoket_e2e_status.json';
  static const reportName = 'memoket_e2e_report.json';

  static Future<Directory?> _dir() async {
    try {
      return await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> writeStatus(Map<String, Object?> report) async {
    return _write(statusName, report);
  }

  static Future<String?> writeReport(Map<String, Object?> report) async {
    return _write(reportName, report);
  }

  static Future<String?> _write(
    String name,
    Map<String, Object?> report,
  ) async {
    final dir = await _dir();
    if (dir == null) return null;
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    return file.path;
  }
}
