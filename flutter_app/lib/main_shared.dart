import 'package:flutter/material.dart';

import 'main_spacing.dart';
import 'main_theme.dart';

/// The drag handle at the top of a bottom sheet.
///
/// Three sheets had written out the same 36x4 pill with the same 16-pixel gap
/// under it. Keeping it here is what stops the fourth one being 32x3.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: palette.borderLight,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
    );
  }
}

/// A flat surface: one fill, one hairline, no gradient and no glow.
///
/// This used to be a three-stop gradient over a tinted drop shadow, nested
/// inside other copies of itself. Depth in this system comes from the sheet
/// layer; a panel on the page is only a boundary.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md + 2),
    this.radius = AppRadius.panel,
    this.color,
    this.bordered = true,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;
  final bool bordered;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? palette.bgCard,
        borderRadius: BorderRadius.circular(radius),
        border: bordered ? Border.all(color: palette.border) : null,
      ),
      child: child,
    );
  }
}

/// The app ground. A single flat color — the two radial glows that used to sit
/// behind every screen are gone.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return ColoredBox(color: palette.bgPrimary, child: child);
  }
}

class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.logoSize = 48, this.showName = true});
  final double logoSize;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(logoSize * 0.24),
          child: Image.asset(
            'assets/branding/logo.png',
            width: logoSize,
            height: logoSize,
            filterQuality: FilterQuality.high,
          ),
        ),
        if (showName) ...<Widget>[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              'NeoRecall',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: logoSize > 40 ? 20 : 16,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class InlineMessage extends StatelessWidget {
  const InlineMessage({
    super.key,
    required this.message,
    this.error = false,
    this.icon,
    this.action,
  });
  final String message;
  final bool error;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = error ? palette.danger : palette.accent;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            icon ?? (error ? Icons.error_outline : Icons.info_outline),
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
          if (action != null) ...<Widget>[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

/// A page title. The eyebrow and the description are both optional now: most
/// pages need neither, and a three-line header on top of every screen was a
/// large part of what made the app feel busy.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.description,
    this.trailing,
  });

  final String title;
  final String? eyebrow;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (eyebrow != null) ...<Widget>[
          Text(eyebrow!.toUpperCase(), style: sectionEyebrowStyle(palette)),
          const SizedBox(height: 8),
        ],
        Text(title, style: displayTitleStyle(palette, size: compact ? 26 : 28)),
        if (description != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            description!,
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? AppSpacing.md : AppSpacing.lg),
      child: trailing == null
          ? copy
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: copy),
                const SizedBox(width: AppSpacing.md),
                trailing!,
              ],
            ),
    );
  }
}

/// A section label with a hairline running to a trailing count — the divider
/// that separates groups of rows without drawing a filled bar over them.
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.label,
    this.trailing,
    this.emphasized = false,
    this.padding = const EdgeInsets.only(bottom: 6),
  });

  final String label;
  final String? trailing;

  /// A day header reads as a heading; a group label ("DEVICES") reads as mono.
  final bool emphasized;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Text(
            emphasized ? label : label.toUpperCase(),
            style: emphasized
                ? TextStyle(
                    color: palette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  )
                : sectionEyebrowStyle(palette),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: palette.border)),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 10),
            Text(
              trailing!.toUpperCase(),
              style: sectionEyebrowStyle(palette).copyWith(letterSpacing: 1.3),
            ),
          ],
        ],
      ),
    );
  }
}

/// The list row this design is built on: a hairline above, a leading gutter, a
/// title with optional supporting line, and one trailing affordance.
///
/// Every list in the app — moments, memories, speakers, sources, settings —
/// uses this. That is the point: they were five different row shapes before.
class HairlineRow extends StatelessWidget {
  const HairlineRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.below,
    this.onTap,
    this.showDivider = true,
    this.titleColor,
    this.minHeight = 56,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Extra content under the supporting line — a status chip, for instance.
  final Widget? below;
  final VoidCallback? onTap;
  final bool showDivider;
  final Color? titleColor;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, const SizedBox(width: 13)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor ?? palette.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
                if (below != null) ...<Widget>[
                  const SizedBox(height: 6),
                  below!,
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );

    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      decoration: showDivider
          ? BoxDecoration(
              border: Border(top: BorderSide(color: palette.border)),
            )
          : null,
      child: onTap == null
          ? row
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.tag),
              child: row,
            ),
    );
  }
}

/// The trailing chevron on a row that opens something.
class RowChevron extends StatelessWidget {
  const RowChevron({super.key});

  @override
  Widget build(BuildContext context) => Icon(
    Icons.chevron_right_rounded,
    size: 18,
    color: neoRecallPaletteOf(context).textMuted,
  );
}

/// A small filled dot carrying one state — connected, waiting, offline.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 7});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// The segmented control that carries Library's three lists.
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelected,
  });

  final List<({T value, String label})> segments;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: palette.bgTertiary,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        children: <Widget>[
          for (final segment in segments)
            Expanded(
              child: Semantics(
                selected: segment.value == selected,
                button: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  onTap: () => onSelected(segment.value),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: segment.value == selected
                          ? palette.accentMuted
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      border: Border.all(
                        color: segment.value == selected
                            ? palette.accent.withValues(alpha: 0.3)
                            : Colors.transparent,
                      ),
                    ),
                    child: Text(
                      segment.label,
                      style: TextStyle(
                        color: segment.value == selected
                            ? palette.accentHover
                            : palette.textMuted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One bottom-sheet shape for the whole app.
///
/// Everything about machines — devices, sources, sync, diagnostics — lives in
/// a sheet rather than on a page, so the sheet is a first-class surface and
/// only has to be built once.
class AppSheet extends StatelessWidget {
  const AppSheet({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding:
            padding ??
            const EdgeInsets.fromLTRB(
              AppSpacing.lg - 4,
              10,
              AppSpacing.lg - 4,
              AppSpacing.lg,
            ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SheetHandle(),
            Flexible(
              child: DefaultTextStyle.merge(
                style: TextStyle(color: palette.textPrimary),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens [builder] as the app's standard modal sheet.
///
/// Scrollable and height-capped: a sheet that lists devices or sources grows
/// with what the account actually has, and must never run off a short phone.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: isDismissible,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => AppSheet(
      child: SingleChildScrollView(child: Builder(builder: builder)),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 26, color: palette.textMuted),
              const SizedBox(height: 16),
              Text(
                title,
                style: heroTitleStyle(palette, size: 17),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textMuted,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: AppSpacing.md),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MetaPill extends StatelessWidget {
  const MetaPill({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
  });
  final IconData icon;
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = active ? palette.accentHover : palette.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: active ? palette.accentMuted : palette.bgTertiary,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(
          color: active
              ? palette.accent.withValues(alpha: 0.3)
              : palette.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.eyebrow,
    required this.child,
    this.trailing,
  });
  final String eyebrow;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  eyebrow.toUpperCase(),
                  style: sectionEyebrowStyle(palette),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

/// The tinted, softly-bordered surface every status chip and badge is built on.
///
/// Ten files had written out the same `Container` — a fill at ~12% of a tint,
/// a border at ~29% of the same tint, a pill or rounded radius. Keeping the two
/// alphas in one place is what stops them drifting apart between screens.
class TintedSurface extends StatelessWidget {
  const TintedSurface({
    super.key,
    required this.tint,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    this.radius,
    this.fillOpacity = 0.13,
    this.borderOpacity = 0.30,
  });

  final Color tint;
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Defaults to a full pill; pass a value for a rounded rectangle.
  final double? radius;
  final double fillOpacity;
  final double borderOpacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: fillOpacity),
        borderRadius: BorderRadius.circular(radius ?? AppRadius.pill),
        border: Border.all(color: tint.withValues(alpha: borderOpacity)),
      ),
      child: child,
    );
  }
}
