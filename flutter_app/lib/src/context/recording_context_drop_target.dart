import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import 'context_content_type.dart';
import 'dropped_file.dart';
import 'file_drop_surface.dart';

/// Accepts files dropped anywhere on the page while a recording runs.
///
/// The gesture is deliberately bound to the running recording: context items
/// belong to a session, so outside one there is nothing for a file to attach
/// to, and the page hands drops back to the browser instead of swallowing
/// them. Wrapping the whole app rather than a single panel is the point — the
/// owner drops a document while reading their timeline, without first
/// navigating back to the recording screen.
class RecordingContextDropTarget extends StatefulWidget {
  const RecordingContextDropTarget({
    super.key,
    required this.controller,
    required this.child,
    this.surface,
  });

  final NeoRecallController controller;
  final Widget child;

  /// The drop area to observe. The platform's own is used when this is left
  /// out; tests pass one they can drive without a browser.
  @visibleForTesting
  final FileDropSurface? surface;

  @override
  State<RecordingContextDropTarget> createState() =>
      _RecordingContextDropTargetState();
}

class _RecordingContextDropTargetState
    extends State<RecordingContextDropTarget> {
  late final FileDropSurface _surface =
      widget.surface ?? createFileDropSurface();
  bool _listening = false;
  bool _hovering = false;

  NeoRecallController get _controller => widget.controller;

  /// The session a dropped file would join, or null when there is none.
  String? get _sessionId =>
      _controller.isRecording ? _controller.activeRecordingSessionId : null;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncListening);
    _syncListening();
  }

  @override
  void didUpdateWidget(covariant RecordingContextDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncListening);
      widget.controller.addListener(_syncListening);
      _syncListening();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_syncListening);
    _surface.stop();
    super.dispose();
  }

  void _syncListening() {
    if (!_surface.isAvailable) return;
    final bool shouldListen = _sessionId != null;
    if (shouldListen == _listening) return;
    _listening = shouldListen;
    if (shouldListen) {
      _surface.start(onHover: _setHovering, onDrop: _accept, onError: _report);
    } else {
      _surface.stop();
      _setHovering(false);
    }
  }

  void _setHovering(bool hovering) {
    if (!mounted || hovering == _hovering) return;
    setState(() => _hovering = hovering);
  }

  Future<void> _accept(List<DroppedFile> files) async {
    final AppL10n l10n = AppL10n.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    // The recording can end between the drop and this callback; a file added
    // then would belong to no session.
    final String? sessionId = _sessionId;
    if (sessionId == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.recordDropNoRecording)),
      );
      return;
    }
    int added = 0;
    final List<String> failures = <String>[];
    for (final DroppedFile file in files) {
      try {
        await _controller.addRecordingFile(
          sessionId: sessionId,
          bytes: file.bytes,
          name: file.name,
          contentType: contextContentTypeFor(
            file.name,
            declared: file.declaredType,
          ),
        );
        added += 1;
      } catch (error) {
        failures.add(
          l10n.recordDropRejected(file.name, _messageFor(l10n, error)),
        );
      }
    }
    if (!mounted) return;
    final List<String> lines = <String>[
      if (added > 0) l10n.recordDropAdded(added),
      ...failures,
    ];
    if (lines.isEmpty) return;
    messenger.showSnackBar(SnackBar(content: Text(lines.join('\n'))));
  }

  void _report(Object error) {
    if (!mounted) return;
    final AppL10n l10n = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error is FileDropReadException
              ? l10n.recordDropUnreadable(error.name)
              : _messageFor(l10n, error),
        ),
      ),
    );
  }

  String _messageFor(AppL10n l10n, Object error) => switch (error) {
    FileDropReadException(:final String name) => l10n.recordDropUnreadable(
      name,
    ),
    StateError(:final String message) => message,
    _ => error.toString(),
  };

  @override
  Widget build(BuildContext context) {
    if (!_surface.isAvailable) return widget.child;
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _hovering ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: _hovering ? const _DropOverlay() : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the page shows while a file hovers over it: where the file will land,
/// and what will happen to it.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final NeoRecallPalette palette = neoRecallPaletteOf(context);
    final AppL10n l10n = AppL10n.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return ColoredBox(
      color: palette.bgPrimary.withValues(alpha: 0.82),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(AppSpacing.xl),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.lg,
          ),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(AppRadius.panel),
            border: Border.all(color: palette.accent, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.upload_file_rounded, size: 40, color: palette.accent),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.recordDropTitle,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(color: palette.textPrimary),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.recordDropHint,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: palette.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
