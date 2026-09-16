import 'dropped_file.dart';
import 'file_drop_surface_stub.dart'
    if (dart.library.html) 'file_drop_surface_web.dart'
    as implementation;

/// A page-wide drop area for files.
///
/// Only the browser build has one: the desktop and mobile shells receive files
/// through their own platform channels, and [isAvailable] is what callers use
/// to tell the difference instead of testing for the platform themselves.
abstract class FileDropSurface {
  /// Whether this build can observe drops at all.
  bool get isAvailable;

  /// Starts observing drops anywhere on the page.
  ///
  /// [onHover] reports whether a drag is currently over the page, so the app
  /// can show where the file will land. [onDrop] receives the dropped files
  /// with their bytes already read. [onError] reports a file that could not be
  /// read; the remaining files of the same drop still arrive through [onDrop].
  /// Calling this twice replaces the previous callbacks.
  void start({
    required void Function(bool hovering) onHover,
    required void Function(List<DroppedFile> files) onDrop,
    required void Function(Object error) onError,
  });

  /// Stops observing, handing drops back to the browser's own behavior.
  void stop();
}

FileDropSurface createFileDropSurface() =>
    implementation.createFileDropSurface();

/// Raised when a dropped item could not be read as a file — a folder, or a
/// file the browser refused to open.
class FileDropReadException implements Exception {
  const FileDropReadException(this.name);

  /// The item's name, for the message the owner sees.
  final String name;

  @override
  String toString() => name;
}
