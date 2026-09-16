import 'package:flutter/material.dart';

import '../../main_controller.dart';
import '../../main_shared.dart';
import '../../main_theme.dart';
import '../../l10n/gen/app_l10n.dart';
import 'settings_section_list.dart';

class AccountUsageSnapshot {
  const AccountUsageSnapshot({required this.ai, required this.transcription});

  final UsageMeterSnapshot ai;
  final UsageMeterSnapshot transcription;

  factory AccountUsageSnapshot.fromJson(Map<String, dynamic> json) {
    return AccountUsageSnapshot(
      ai: UsageMeterSnapshot.fromJson(
        Map<String, dynamic>.from(json['ai'] as Map? ?? const <String, dynamic>{}),
      ),
      transcription: UsageMeterSnapshot.fromJson(
        Map<String, dynamic>.from(
          json['transcription'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }
}

class UsageMeterSnapshot {
  const UsageMeterSnapshot({
    required this.fourHour,
    required this.weekly,
  });

  final UsageWindowSnapshot fourHour;
  final UsageWindowSnapshot weekly;

  factory UsageMeterSnapshot.fromJson(Map<String, dynamic> json) {
    return UsageMeterSnapshot(
      fourHour: UsageWindowSnapshot.fromJson(json, 'fourHour'),
      weekly: UsageWindowSnapshot.fromJson(json, 'weekly'),
    );
  }
}

class UsageWindowSnapshot {
  const UsageWindowSnapshot({
    required this.limit,
    required this.used,
    required this.remaining,
    required this.reached,
    required this.isCustom,
    this.nextDecreaseAt,
  });

  final int? limit;
  final int used;
  final int? remaining;
  final bool reached;
  final bool isCustom;
  final DateTime? nextDecreaseAt;

  factory UsageWindowSnapshot.fromJson(Map<String, dynamic> json, String key) {
    final limits = json['limits'] as Map? ?? const <String, dynamic>{};
    final usage = json['usage'] as Map? ?? const <String, dynamic>{};
    final remaining = json['remaining'] as Map? ?? const <String, dynamic>{};
    final reached = json['reached'] as Map? ?? const <String, dynamic>{};
    final next = json['nextDecreaseAt'] as Map? ?? const <String, dynamic>{};
    return UsageWindowSnapshot(
      limit: (limits[key] as num?)?.toInt(),
      used: (usage[key] as num?)?.toInt() ?? 0,
      remaining: (remaining[key] as num?)?.toInt(),
      reached: reached[key] == true,
      isCustom: key == 'fourHour'
          ? limits['fourHourIsCustom'] == true
          : limits['weeklyIsCustom'] == true,
      nextDecreaseAt: DateTime.tryParse(next[key]?.toString() ?? ''),
    );
  }
}

class UsageSection extends StatefulWidget {
  const UsageSection({super.key, required this.controller});

  final NeoRecallController controller;

  @override
  State<UsageSection> createState() => _UsageSectionState();
}

class _UsageSectionState extends State<UsageSection> {
  @override
  void initState() {
    super.initState();
    widget.controller.refreshAccountUsage();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _body(),
  );

  Widget _body() {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final usage = widget.controller.accountUsage;
    return SettingsSectionList(
      controller: widget.controller,
      children: <Widget>[
        SectionCard(
          eyebrow: strings.usageSectionEyebrow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                strings.usageSectionTitle,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.usageSectionDescription,
                style: TextStyle(color: palette.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 20),
              if (widget.controller.accountUsageLoading && usage == null)
                const Center(child: CircularProgressIndicator())
              else if (usage == null)
                Text(
                  strings.usageUnavailable,
                  style: TextStyle(color: palette.textSecondary, height: 1.45),
                )
              else ...<Widget>[
                _meterCard(
                  title: strings.usageAiTitle,
                  meter: usage.ai,
                  formatAmount: (value) => _formatCount(value),
                ),
                const SizedBox(height: 16),
                _meterCard(
                  title: strings.usageTranscriptionTitle,
                  meter: usage.transcription,
                  formatAmount: _formatSeconds,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _meterCard({
    required String title,
    required UsageMeterSnapshot meter,
    required String Function(int value) formatAmount,
  }) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              color: palette.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          _windowRow(
            label: strings.usageWindowFourHour,
            window: meter.fourHour,
            formatAmount: formatAmount,
          ),
          const SizedBox(height: 14),
          _windowRow(
            label: strings.usageWindowWeekly,
            window: meter.weekly,
            formatAmount: formatAmount,
          ),
        ],
      ),
    );
  }

  Widget _windowRow({
    required String label,
    required UsageWindowSnapshot window,
    required String Function(int value) formatAmount,
  }) {
    final palette = neoRecallPaletteOf(context);
    final strings = AppL10n.of(context);
    final limitLabel = window.limit == null
        ? strings.usageUnlimited
        : formatAmount(window.limit!);
    final usedLabel = formatAmount(window.used);
    final progress = window.limit == null || window.limit == 0
        ? 0.0
        : (window.used / window.limit!).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (window.isCustom)
              Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  strings.usageCustomBadge,
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Text(
              strings.usageUsedOfLimit(usedLabel, limitLabel),
              style: TextStyle(
                color: window.reached ? palette.danger : palette.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: window.limit == null ? 0 : progress,
            minHeight: 6,
            backgroundColor: palette.border,
            color: window.reached ? palette.danger : palette.accent,
          ),
        ),
        if (window.nextDecreaseAt != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            strings.usageNextDrop(_relativeWhen(window.nextDecreaseAt!)),
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
          ),
        ],
      ],
    );
  }

  String _formatCount(int value) => value.toString();

  String _formatSeconds(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  String _relativeWhen(DateTime when) {
    final remaining = when.difference(DateTime.now());
    if (remaining.isNegative) return _formatSeconds(0);
    return _formatSeconds(remaining.inSeconds);
  }
}
