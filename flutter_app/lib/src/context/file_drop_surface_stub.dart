import 'dropped_file.dart';
import 'file_drop_surface.dart';

FileDropSurface createFileDropSurface() => const _NoFileDropSurface();

/// Platforms without a browser document have no page to drop onto. The surface
/// reports that plainly rather than pretending to listen.
class _NoFileDropSurface implements FileDropSurface {
  const _NoFileDropSurface();

  @override
  bool get isAvailable => false;

  @override
  void start({
    required void Function(bool hovering) onHover,
    required void Function(List<DroppedFile> files) onDrop,
    required void Function(Object error) onError,
  }) {}

  @override
  void stop() {}
}
