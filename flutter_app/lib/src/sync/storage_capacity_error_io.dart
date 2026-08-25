import 'dart:io';

import 'package:sqflite_common/sqlite_api.dart';

// Native error numbers used by supported hosts. POSIX reports ENOSPC (28);
// Windows reports ERROR_DISK_FULL (112) or ERROR_HANDLE_DISK_FULL (39).
const Set<int> _capacityErrorCodes = <int>{28, 39, 112};
const int _sqliteFullResultCode = 13;

bool isStorageCapacityError(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    return code != null && _capacityErrorCodes.contains(code);
  }
  if (error is DatabaseException) {
    final code = error.getResultCode();
    // Extended SQLite result codes retain the primary code in the low byte.
    return code != null && (code & 0xff) == _sqliteFullResultCode;
  }
  return false;
}
