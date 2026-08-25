import 'storage_capacity_error_stub.dart'
    if (dart.library.io) 'storage_capacity_error_io.dart'
    as implementation;

/// True only when the operating system explicitly reported exhausted storage.
/// Other durable-store failures remain visible errors, but must not be
/// mislabeled as a full disk.
bool isStorageCapacityError(Object error) =>
    implementation.isStorageCapacityError(error);
