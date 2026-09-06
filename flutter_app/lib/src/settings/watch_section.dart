import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../watch/paired_watch.dart';
import 'settings_section_list.dart';

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
      _notice = 'Today was sent to the watch.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
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
                  tooltip: 'Check again',
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Record from your wrist',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The watch records on its own and holds every clip until this '
                'phone confirms it was transcribed and the server copy deleted. '
                'Today’s transcript, memories and commitments are sent back to '
                'the watch so they can be read without the phone.',
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 18),
              if (watches == null)
                Text(
                  'Looking for paired watches…',
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
                      label: Text(_sending ? 'Sending…' : 'Send today now'),
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
      status = 'NeoRecall not installed';
    } else if (!watch.nearby) {
      tint = palette.textMuted;
      status = 'Installed · out of range';
    } else {
      tint = palette.success;
      status = 'Installed · connected';
    }
    return HairlineRow(
      title: watch.name,
      subtitle: status,
      leading: Icon(Icons.watch_outlined, size: 18, color: tint),
      trailing: TintedSurface(
        tint: tint,
        child: Text(
          watch.installed ? 'READY' : 'SET UP',
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
    'No paired watch found. Pair the watch with this phone in the Wear OS app '
    'first — NeoRecall can only see watches Android has already paired.',
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
    return SectionCard(
      eyebrow: 'Installing on the watch',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'NeoRecall for Wear OS ships as its own APK, signed with the same '
            'key as this app, and is sideloaded once. It is not on the Play '
            'Store, so the watch needs developer options turned on for the '
            'install and nothing after that.',
            style: TextStyle(color: palette.textSecondary, height: 1.45),
          ),
          const SizedBox(height: 18),
          const _Step(
            number: 1,
            title: 'Download the watch APK',
            detail:
                'Take NeoRecall-WearOS-<version>.apk from the latest release, '
                'onto a computer that is on the same network as the watch.',
          ),
          _CopyLine(label: 'Releases', value: releasesUrl),
          const SizedBox(height: 14),
          const _Step(
            number: 2,
            title: 'Turn on wireless debugging on the watch',
            detail:
                'Settings → System → About → tap Build number seven times, '
                'then Settings → Developer options → ADB debugging and '
                'Wireless debugging. The watch shows its IP address there.',
          ),
          const SizedBox(height: 14),
          const _Step(
            number: 3,
            title: 'Install it over Wi-Fi',
            detail:
                'From the computer holding the APK, with the watch IP from the '
                'previous step:',
          ),
          const _CopyLine(
            label: 'Connect',
            value: 'adb connect WATCH_IP:5555',
          ),
          const _CopyLine(
            label: 'Install',
            value: 'adb -s WATCH_IP:5555 install -r NeoRecall-WearOS.apk',
          ),
          const SizedBox(height: 14),
          const _Step(
            number: 4,
            title: 'Open it once on the watch',
            detail:
                'Allow the microphone, and this page turns to Installed. Add '
                'the NeoRecall tiles by long-pressing the watch face, and the '
                'complications from the watch face editor.',
          ),
          const SizedBox(height: 16),
          Text(
            'Developer options can be turned back off afterwards — the app '
            'stays installed and keeps working.',
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
            tooltip: 'Copy $label',
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
