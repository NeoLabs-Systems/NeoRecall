import 'package:flutter/material.dart';

import 'main_spacing.dart';
import 'main_theme.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = AppRadius.panel,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: palette.panelGradient,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.glassBorder),
        boxShadow: softPanelShadow(palette),
      ),
      child: child,
    );
  }
}

class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: palette.backgroundGradient),
      child: Stack(
        children: <Widget>[
          Positioned(
            top: -120,
            right: -40,
            child: _Glow(
              color: palette.accent.withValues(alpha: 0.14),
              size: 280,
            ),
          ),
          Positioned(
            bottom: -140,
            left: -60,
            child: _Glow(
              color: palette.accentAlt.withValues(alpha: 0.10),
              size: 320,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0)],
        ),
      ),
    ),
  );
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
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(logoSize * 0.24),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: palette.accent.withValues(alpha: 0.18),
                blurRadius: 14,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
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
                fontWeight: FontWeight.w800,
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
  });
  final String message;
  final bool error;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final color = error ? palette.danger : palette.accent;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.input),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            icon ?? (error ? Icons.error_outline : Icons.info_outline),
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: palette.textSecondary, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.description,
    this.trailing,
  });
  final String eyebrow;
  final String title;
  final String description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    final compact = MediaQuery.sizeOf(context).width < AppBreakpoints.mobile;
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(eyebrow, style: sectionEyebrowStyle(palette)),
        const SizedBox(height: 8),
        Text(title, style: displayTitleStyle(palette, size: compact ? 24 : 32)),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(color: palette.textSecondary, height: 1.5),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 16 : 24),
      child: compact && trailing != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[copy, const SizedBox(height: 16), trailing!],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: copy),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: 16),
                  trailing!,
                ],
              ],
            ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: palette.accentMuted,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: palette.borderLight),
                ),
                child: Icon(icon, size: 30, color: palette.accentHover),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: heroTitleStyle(palette, size: 20),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.textMuted, height: 1.5),
              ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? palette.accentMuted
            : palette.bgSecondary.withValues(alpha: 0.7),
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
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
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
    return GlassSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(eyebrow, style: sectionEyebrowStyle(palette)),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 16),
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
