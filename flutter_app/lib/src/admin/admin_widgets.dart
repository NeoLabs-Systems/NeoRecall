import 'dart:async';

import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_spacing.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import '../api_client.dart';

/// Passes on a failed admin call. When the server says this account is no
/// longer an admin, the app stops offering the page instead of showing the
/// same refusal on every card.
void noteAdminFailure(NeoRecallController controller, Object error) {
  if (error is ApiException && error.code == 'ADMIN_REQUIRED') {
    controller.adminAccessRevoked();
  }
}

String adminErrorText(Object error) =>
    error is ApiException ? error.message : error.toString();

String adminDate(BuildContext context, DateTime? value) {
  if (value == null) return '—';
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatMediumDate(value)} · '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
}

String adminMegabytes(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// Tells the cards on the open area which one a search result pointed at.
class AdminSearchTarget extends InheritedWidget {
  const AdminSearchTarget({
    super.key,
    required this.card,
    required super.child,
  });

  final String? card;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminSearchTarget>()?.card;

  @override
  bool updateShouldNotify(AdminSearchTarget oldWidget) =>
      card != oldWidget.card;
}

/// A card on the Admin page. When a search result targets [id], the card
/// scrolls into view once it exists and is outlined for a moment, so the eye
/// lands on it. Both are the answer to the tap that opened it; nothing moves
/// on its own afterwards.
class AdminCard extends StatefulWidget {
  const AdminCard({
    super.key,
    required this.id,
    required this.eyebrow,
    required this.child,
    this.trailing,
  });

  final String id;
  final String eyebrow;
  final Widget child;
  final Widget? trailing;

  @override
  State<AdminCard> createState() => _AdminCardState();
}

class _AdminCardState extends State<AdminCard> {
  static const Duration _outlineFor = Duration(milliseconds: 1600);

  bool _handled = false;
  bool _outlined = false;
  Timer? _fade;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handled || AdminSearchTarget.of(context) != widget.id) return;
    _handled = true;
    _outlined = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: 0.05,
      );
      _fade = Timer(_outlineFor, () {
        if (mounted) setState(() => _outlined = false);
      });
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.panel + 2),
        border: Border.all(
          color: _outlined ? palette.accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: SectionCard(
        eyebrow: widget.eyebrow,
        trailing: widget.trailing,
        child: widget.child,
      ),
    );
  }
}

/// Loads one area's data and shows it, a spinner, or what went wrong with a
/// way to try again.
class AdminLoader<T> extends StatefulWidget {
  const AdminLoader({
    super.key,
    required this.controller,
    required this.load,
    required this.builder,
  });

  final NeoRecallController controller;
  final Future<T> Function() load;

  /// [reload] fetches again, for after a change.
  final Widget Function(
    BuildContext context,
    T data,
    Future<void> Function() reload,
  )
  builder;

  @override
  State<AdminLoader<T>> createState() => _AdminLoaderState<T>();
}

class _AdminLoaderState<T> extends State<AdminLoader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      noteAdminFailure(widget.controller, error);
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      if (_loading) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return AdminFailure(error: _error, onRetry: _reload);
    }
    // Keeps what is on screen while a reload runs, with the failure above it
    // if the reload did not work: a card that goes blank on refresh tells an
    // operator the system is idle when it is only unreachable.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_error != null) ...<Widget>[
          AdminFailure(error: _error, onRetry: _reload),
          const SizedBox(height: AppSpacing.sm),
        ],
        widget.builder(context, data, _reload),
      ],
    );
  }
}

class AdminFailure extends StatelessWidget {
  const AdminFailure({super.key, required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppL10n.of(context);
    final failure = error;
    // A server older than the app has no admin API at all; saying so beats a
    // bare "not found" that reads like a fault in this page.
    final serverTooOld =
        failure is ApiException &&
        failure.status == 404 &&
        failure.code == 'NOT_FOUND';
    return InlineMessage(
      error: true,
      message: serverTooOld
          ? strings.adminServerTooOld
          : failure == null
          ? strings.adminLoadFailed
          : strings.adminLoadFailedBecause(adminErrorText(failure)),
      action: TextButton(onPressed: onRetry, child: Text(strings.adminRetry)),
    );
  }
}

enum AdminTone { ok, warning, danger, neutral }

/// One figure on an overview grid: a coloured dot for its state, a label, a
/// value.
class AdminStatTile extends StatelessWidget {
  const AdminStatTile({
    super.key,
    required this.label,
    required this.value,
    this.tone = AdminTone.ok,
    this.width = 200,
  });

  final String label;
  final String value;
  final AdminTone tone;

  /// Set by [AdminStatGrid] so tiles share a row evenly.
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      width: width,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: palette.bgSecondary.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.borderLight),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: StatusDot(color: adminToneColor(palette, tone)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(color: palette.textMuted, fontSize: 11.5),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
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

/// Stat tiles in even columns: as many 200-point tiles as fit, and never
/// fewer than two, so a phone shows a grid rather than one tile per row.
class AdminStatGrid extends StatelessWidget {
  const AdminStatGrid({super.key, required this.tiles});

  final List<AdminStatTile> tiles;

  static const double _spacing = AppSpacing.sm;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + _spacing) / (200 + _spacing))
            .floor()
            .clamp(2, 8);
        final width =
            (constraints.maxWidth - _spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: <Widget>[
            for (final tile in tiles)
              AdminStatTile(
                label: tile.label,
                value: tile.value,
                tone: tile.tone,
                width: width,
              ),
          ],
        );
      },
    );
  }
}

Color adminToneColor(NeoRecallPalette palette, AdminTone tone) =>
    switch (tone) {
      AdminTone.ok => palette.success,
      AdminTone.warning => palette.warning,
      AdminTone.danger => palette.danger,
      AdminTone.neutral => palette.textMuted,
    };

/// How a job, request, backup or worker state reads at a glance.
AdminTone adminStateTone(String state) => switch (state.toLowerCase()) {
  'completed' || 'succeeded' || 'ready' => AdminTone.ok,
  'failed' || 'not_ready' => AdminTone.danger,
  'queued' ||
  'leased' ||
  'reserved' ||
  'sent' ||
  'running' ||
  'starting' => AdminTone.warning,
  _ => AdminTone.neutral,
};

/// The state in the app's language. A state this build does not know keeps
/// the server's own word rather than disappearing.
String adminStateLabel(AppL10n strings, String state) =>
    switch (state.toLowerCase()) {
      'queued' => strings.adminStateQueued,
      'leased' || 'running' => strings.adminStateRunning,
      'completed' || 'succeeded' => strings.adminStateDone,
      'failed' => strings.adminStateFailed,
      'cancelled' => strings.adminStateCancelled,
      'reserved' => strings.adminStateReserved,
      'sent' => strings.adminStateSent,
      'starting' => strings.adminStateStarting,
      'ready' => strings.adminStateReady,
      'not_ready' => strings.adminStateNotReady,
      'manual' => strings.adminTriggerManual,
      'scheduled' => strings.adminTriggerScheduled,
      _ => state,
    };

/// A chip for a server state: its label in the app's language, its tone.
class AdminStateChip extends StatelessWidget {
  const AdminStateChip({super.key, required this.state});

  final String state;

  @override
  Widget build(BuildContext context) => AdminChip(
    label: adminStateLabel(AppL10n.of(context), state),
    tone: adminStateTone(state),
  );
}

/// A small tinted label: a state, a role.
class AdminChip extends StatelessWidget {
  const AdminChip({super.key, required this.label, required this.tone});

  final String label;
  final AdminTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = adminToneColor(palette, tone);
    return TintedSurface(
      tint: color,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A card's list of rows, or the sentence that says it is empty.
class AdminRows extends StatelessWidget {
  const AdminRows({super.key, required this.empty, required this.children});

  final String empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Text(
          empty,
          style: TextStyle(color: neoRecallPaletteOf(context).textMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// One row of an admin list: a title line with chips, supporting lines, and
/// its actions.
class AdminListRow extends StatelessWidget {
  const AdminListRow({
    super.key,
    required this.title,
    this.chips = const <Widget>[],
    this.lines = const <String>[],
    this.actions = const <Widget>[],
    this.first = false,
  });

  final String title;
  final List<Widget> chips;
  final List<String> lines;
  final List<Widget> actions;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        border: first ? null : Border(top: BorderSide(color: palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              ...chips,
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                line,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: actions),
          ],
        ],
      ),
    );
  }
}
