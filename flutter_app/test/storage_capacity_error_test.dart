import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neorecall/src/sync/storage_capacity_error.dart';

void main() {
  test('only explicit operating-system capacity errors are storage full', () {
    expect(
      isStorageCapacityError(
        const FileSystemException('write', '', OSError('full', 28)),
      ),
      isTrue,
    );
    expect(
      isStorageCapacityError(
        const FileSystemException('write', '', OSError('denied', 13)),
      ),
      isFalse,
    );
    expect(isStorageCapacityError(StateError('database unavailable')), isFalse);
  });
}
