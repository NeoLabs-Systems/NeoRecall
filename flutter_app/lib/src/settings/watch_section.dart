import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../watch/paired_watch.dart';
import 'settings_section_list.dart';
import '../../l10n/gen/app_l10n.dart';

/// Pairing, installing and feeding a Wear OS watch.
///
/// The watch app is a second APK. It is not distributed through the Play Store,
/// so this screen has two jobs: say honestly what is paired and what is
/// installed on it, and hand over the exact steps to put NeoRecall on a watch
/// that does not have it. Everything it reports comes from Play services rather
/// than from NeoRecall's own state, so a watch that was never set up shows up
/// as paired-but-missing instead of not existing.
class WatchSection extends StatefulWidget {
  const WatchSection({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<WatchSection> createState() => _WatchSectionState();
}

class _WatchSectionState extends State<WatchSection> {
  static const String _releasesUrl =
      'https://github.com/NeoLabs-Systems/NeoRecall/releases/latest';

  List<PairedWatch>? _watches;
  bool _refreshing = false;
  bool _sending = false;
  String? _notice;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // An install finishes on the watch, not here. Polling is what lets the page
    // flip to "installed" by itself instead of asking the reader to come back.
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final watches = await widget.controller.loadPairedWatches();
    if (!mounted) return;
    setState(() {
      _watches = watches;
      _refreshing = false;
    });
  }

  Future<void> _sendDigest() async {
    setState(() {
      _sending = true;
      _notice = null;
    });
    await widget.controller.resendWatchDigest();
    if (!mounted) return;
    setState(() {
      _sending = false;
      _notice = AppL10n.of(context).watchDigestSent;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final watches = _watches;
    final installed = watches?.where((watch) => watch.installed).toList();
    return SettingsSectionList(
      controller: widget.controller,
      children: <Widget>[
        SectionCard(
          eyebrow: 'Wear OS',
          trailing: _refreshing
              ? const SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: strings.watchCheckAgain,
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                strings.watchTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.watchDescription,
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 18),
              if (watches == null)
                Text(
                  strings.watchLooking,
                  style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                )
              else if (watches.isEmpty)
                _NoWatchNotice(palette: palette)
              else
                ...watches.map(
                  (watch) => _WatchRow(watch: watch, palette: palette),
                ),
              if (installed != null && installed.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _sending ? null : _sendDigest,
                      icon: const Icon(Icons.watch_outlined, size: 18),
                      label: Text(
                        _sending
                            ? strings.watchSending
                            : strings.watchSendToday,
                      ),
                    ),
                    if (_notice != null) ...<Widget>[
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _notice!,
                          style: TextStyle(
                            color: palette.success,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _InstallGuide(releasesUrl: _releasesUrl),
      ],
    );
  }
}

class _WatchRow extends StatelessWidget {
  const _WatchRow({required this.watch, required this.palette});

  final PairedWatch watch;
  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) {
    final Color tint;
    final String status;
    if (!watch.installed) {
      tint = palette.warning;
      status = AppL10n.of(context).watchNotInstalled;
    } else if (!watch.nearby) {
      tint = palette.textMuted;
      status = AppL10n.of(context).watchOutOfRange;
    } else {
      tint = palette.success;
      status = AppL10n.of(context).watchConnected;
    }
    return HairlineRow(
      title: watch.name,
      subtitle: status,
      leading: Icon(Icons.watch_outlined, size: 18, color: tint),
      trailing: TintedSurface(
        tint: tint,
        child: Text(
          watch.installed
              ? AppL10n.of(context).watchReady
              : AppL10n.of(context).watchSetUp,
          style: TextStyle(
            color: tint,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

class _NoWatchNotice extends StatelessWidget {
  const _NoWatchNotice({required this.palette});

  final NeoRecallPalette palette;

  @override
  Widget build(BuildContext context) => Text(
    AppL10n.of(context).watchNonePaired,
    style: TextStyle(color: palette.textMuted, fontSize: 12.5, height: 1.45),
  );
}

/// How to put the watch APK on a watch, without the Play Store.
///
/// Written out rather than automated because the last step genuinely happens on
/// the watch: Android does not let one app install another app onto a paired
/// device. The commands are exact and copyable, which is the most this screen
/// can honestly offer.
class _InstallGuide extends StatelessWidget {
  const _InstallGuide({required this.releasesUrl});

  final String releasesUrl;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return SectionCard(
      eyebrow: strings.watchInstallEyebrow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            strings.watchInstallIntro,
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 18),
          _Step(
            number: 1,
            title: strings.watchStep1Title,
            detail: strings.watchStep1Detail,
          ),
          _CopyLine(label: strings.watchReleasesLabel, value: releasesUrl),
          const SizedBox(height: 14),
          _Step(
            number: 2,
            title: strings.watchStep2Title,
            detail: strings.watchStep2Detail,
          ),
          const SizedBox(height: 14),
          _Step(
            number: 3,
            title: strings.watchStep3Title,
            detail: strings.watchStep3Detail,
          ),
          _CopyLine(
            label: strings.watchConnectLabel,
            value: 'adb connect WATCH_IP:5555',
          ),
          _CopyLine(
            label: strings.watchInstallLabel,
            value: 'adb -s WATCH_IP:5555 install -r NeoRecall-WearOS.apk',
          ),
          const SizedBox(height: 14),
          _Step(
            number: 4,
            title: strings.watchStep4Title,
            detail: strings.watchStep4Detail,
          ),
          const SizedBox(height: 16),
          Text(
            strings.watchInstallFootnote,
            style: TextStyle(
              color: palette.textMuted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.detail,
  });

  final int number;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accentMuted,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: TextStyle(
                color: palette.accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A command or URL, shown as it must be typed and copyable in one tap.
class _CopyLine extends StatelessWidget {
  const _CopyLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(left: 34, top: 4, bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: palette.bgTertiary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: palette.border),
              ),
              child: SelectableText(
                value,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontFamily: 'IBM Plex Mono',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: AppL10n.of(context).watchCopyLabel(label),
            icon: const Icon(Icons.copy_all_outlined, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.maybeOf(
                context,
              )?.showSnackBar(SnackBar(content: Text('$label copied')));
            },
          ),
        ],
      ),
    );
  }
}
