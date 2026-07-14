import 'package:flutter/material.dart';

import 'main_theme.dart';

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final palette = neoRecallPaletteOf(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: palette.panelGradient,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.glassBorder),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: palette.shadow,
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: neoRecallPaletteOf(context).backgroundGradient,
    ),
    child: child,
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
            color: palette.surfaceRaised,
            borderRadius: BorderRadius.circular(logoSize * .25),
            border: Border.all(color: palette.borderStrong),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Icon(
                Icons.radio_button_checked_rounded,
                color: palette.accent,
                size: logoSize * .55,
              ),
              Icon(
                Icons.circle,
                color: palette.secondary,
                size: logoSize * .15,
              ),
            ],
          ),
        ),
        if (showName) ...<Widget>[
          const SizedBox(width: 12),
          Text(
            'NeoRecall',
            style: TextStyle(
              color: palette.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
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
    final color = error ? palette.error : palette.accent;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            icon ?? (error ? Icons.error_outline : Icons.info_outline),
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: palette.textSoft)),
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(eyebrow, style: sectionEyebrowStyle(palette)),
              const SizedBox(height: 7),
              Text(title, style: displayTitleStyle(palette)),
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(color: palette.textSoft, height: 1.5),
              ),
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 16), trailing!],
      ],
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
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 42, color: neoRecallPaletteOf(context).textMuted),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: neoRecallPaletteOf(context).textMuted),
          ),
        ],
      ),
    ),
  );
}
