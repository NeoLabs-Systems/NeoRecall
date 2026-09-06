import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main_controller.dart';
import 'main_spacing.dart';
import 'main_theme.dart';

/// Device & sync diagnostics, shown as a modal sheet from the Bluetooth setup
/// area rather than as a settings page.
///
/// This is a troubleshooting surface, not a feature: the product stays
/// consumer-facing, so nothing advertises it. It opens on a long-press of the
/// device status line (see `main_record.dart`), which has no visual affordance —
/// discoverable when support asks for it, invisible otherwise.
Future<void> showDeviceDiagnosticsSheet(
  BuildContext context,
  NeoRecallController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: neoRecallPaletteOf(context).surface,
    builder: (sheetContext) => _DeviceDiagnosticsSheet(controller: controller),
  );
}

class _DeviceDiagnosticsSheet extends StatefulWidget {
  const _DeviceDiagnosticsSheet({required this.controller});

  final NeoRecallController controller;

  @override
  State<_DeviceDiagnosticsSheet> createState() =>
      _DeviceDiagnosticsSheetState();
}

class _DeviceDiagnosticsSheetState extends State<_DeviceDiagnosticsSheet> {
  bool exporting = false;
  bool clearing = false;

  Future<void> _copyReport() async {
    setState(() => exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final report = await widget.controller.buildDiagnosticExport();
      await Clipboard.setData(ClipboardData(text: report));
      messenger.showSnackBar(
        const SnackBar(content: Text('Diagnostic report copied.')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> _clear() async {
    setState(() => clearing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.clearDiagnostics();
      messenger.showSnackBar(
        const SnackBar(content: Text('Diagnostic log cleared.')),
      );
    } finally {
      if (mounted) setState(() => clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    // Cap the sheet so it never swallows the whole screen on a phone.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.troubleshoot_rounded,
                    size: 20,
                    color: palette.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Device & sync diagnostics',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: () => setState(() {}),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Bluetooth scan/connect, device sync, and import events for this '
                'account. Passwords, tokens, audio, transcripts, and other '
                'accounts are never included.',
                style: TextStyle(
                  color: palette.textSecondary,
                  height: 1.45,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: DeviceDiagnosticsLogView(controller: widget.controller),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: exporting ? null : _copyReport,
                    icon: exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.content_copy_outlined),
                    label: Text(exporting ? 'Preparing…' : 'Copy full report'),
                  ),
                  OutlinedButton.icon(
                    onPressed: clearing ? null : _clear,
                    icon: clearing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline_rounded),
                    label: const Text('Clear log'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scrollable, monospaced view of the recent diagnostic events, colour-coded by
/// level. Reads a fresh snapshot on each build; the sheet's Refresh button
/// re-reads it, and it is captured in full by "Copy full report".
class DeviceDiagnosticsLogView extends StatelessWidget {
  const DeviceDiagnosticsLogView({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final events = controller.diagnosticEvents;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 360),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surfaceMuted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(color: palette.border),
      ),
      child: events.isEmpty
          ? Text(
              'No diagnostic events yet. Connect a device and sync to populate '
              'this log, then refresh.',
              style: TextStyle(color: palette.textMuted, fontSize: 12.5),
            )
          : SingleChildScrollView(
              reverse: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final event in events)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: SelectableText(
                        controller.formatDiagnosticEvent(event),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.3,
                          color: event['level'] == 'error'
                              ? palette.danger
                              : event['level'] == 'warning'
                              ? const Color(0xFFC98A00)
                              : palette.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
