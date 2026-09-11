import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Offers a save location for a downloaded account zip.
///
/// Returns the chosen path or file name, or null when the person cancelled.
Future<String?> saveAccountExport(Uint8List bytes, String filename) {
  return FilePicker.platform.saveFile(
    dialogTitle: filename,
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: const <String>['zip'],
    bytes: bytes,
  );
}
