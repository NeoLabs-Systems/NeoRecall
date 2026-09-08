// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'dropped_file.dart';
import 'file_drop_surface.dart';

FileDropSurface createFileDropSurface() => _BrowserFileDropSurface();

/// Drops anywhere on the document, not on one widget.
///
/// The listeners live on `document` so the whole page accepts a file, which is
/// what makes the gesture worth having: the owner drops onto the window they
/// are already looking at instead of aiming at a target. While no listener is
/// attached the browser keeps its own behavior, which is to open the file and
/// navigate away from the app.
class _BrowserFileDropSurface implements FileDropSurface {
  void Function(bool hovering)? _onHover;
  void Function(List<DroppedFile> files)? _onDrop;
  void Function(Object error)? _onError;

  final List<StreamSubscription<html.MouseEvent>> _subscriptions =
      <StreamSubscription<html.MouseEvent>>[];

  /// How many nested elements the pointer is currently inside. `dragleave`
  /// fires when a drag crosses into a child element, so a plain boolean would
  /// flicker the overlay off while the file is still over the page.
  int _depth = 0;

  @override
  bool get isAvailable => true;

  @override
  void start({
    required void Function(bool hovering) onHover,
    required void Function(List<DroppedFile> files) onDrop,
    required void Function(Object error) onError,
  }) {
    stop();
    _onHover = onHover;
    _onDrop = onDrop;
    _onError = onError;
    final html.Document document = html.document;
    _subscriptions.addAll(<StreamSubscription<html.MouseEvent>>[
      document.onDragEnter.listen(_enter),
      document.onDragOver.listen(_over),
      document.onDragLeave.listen(_leave),
      document.onDrop.listen(_drop),
    ]);
  }

  @override
  void stop() {
    for (final StreamSubscription<html.MouseEvent> subscription
        in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    if (_depth != 0) {
      _depth = 0;
      _onHover?.call(false);
    }
    _onHover = null;
    _onDrop = null;
    _onError = null;
  }

  /// Whether the drag carries files. Dragging selected text or a link inside
  /// the app must keep behaving as it always has.
  bool _carriesFiles(html.MouseEvent event) =>
      event.dataTransfer.types?.contains('Files') ?? false;

  void _enter(html.MouseEvent event) {
    if (!_carriesFiles(event)) return;
    event.preventDefault();
    _depth += 1;
    if (_depth == 1) _onHover?.call(true);
  }

  void _over(html.MouseEvent event) {
    if (!_carriesFiles(event)) return;
    // Without cancelling the default the browser refuses the drop outright and
    // the `drop` event never arrives.
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
  }

  void _leave(html.MouseEvent event) {
    if (!_carriesFiles(event)) return;
    event.preventDefault();
    _depth = _depth > 0 ? _depth - 1 : 0;
    if (_depth == 0) _onHover?.call(false);
  }

  Future<void> _drop(html.MouseEvent event) async {
    if (!_carriesFiles(event)) return;
    event.preventDefault();
    _depth = 0;
    _onHover?.call(false);
    final List<html.File> files =
        event.dataTransfer.files ?? const <html.File>[];
    if (files.isEmpty) return;
    final void Function(List<DroppedFile>)? deliver = _onDrop;
    final void Function(Object)? report = _onError;
    final List<DroppedFile> read = <DroppedFile>[];
    for (final html.File file in files) {
      try {
        read.add(
          DroppedFile(
            name: file.name,
            bytes: await _read(file),
            declaredType: file.type,
          ),
        );
      } catch (error) {
        // A folder, or a file the browser cannot open, fails here. The rest of
        // the drop is still worth keeping.
        report?.call(error);
      }
    }
    if (read.isNotEmpty) deliver?.call(read);
  }

  Future<Uint8List> _read(html.File file) async {
    final html.FileReader reader = html.FileReader();
    final Completer<Uint8List> completer = Completer<Uint8List>();
    reader.onLoadEnd.first.then((html.Event _) {
      if (completer.isCompleted) return;
      final Object? result = reader.result;
      if (result is Uint8List) {
        completer.complete(result);
      } else if (result is ByteBuffer) {
        completer.complete(result.asUint8List());
      } else if (result is List<int>) {
        completer.complete(Uint8List.fromList(result));
      } else {
        completer.completeError(_unreadable(file));
      }
    });
    reader.onError.first.then((html.Event _) {
      if (!completer.isCompleted) completer.completeError(_unreadable(file));
    });
    reader.readAsArrayBuffer(file);
    return completer.future;
  }

  Exception _unreadable(html.File file) =>
      FileDropReadException(file.name.isEmpty ? 'file' : file.name);
}
