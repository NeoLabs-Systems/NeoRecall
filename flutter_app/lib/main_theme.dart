import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:neolabs_flutter/neolabs_flutter.dart'
    show NeoLabsPalette, paletteFor;

import 'main_spacing.dart';

export 'package:neolabs_flutter/neolabs_flutter.dart'
    show NeoLabsPalette, darkPalette, lightPalette, paletteFor, paletteOf;

/// Canonical color tokens for the shared "Control Surface" design system,
/// sourced directly from `neolabs_flutter` so all NeoLabs apps stay in sync.
typedef NeoRecallPalette = NeoLabsPalette;

extension NeoRecallPaletteTokens on NeoLabsPalette {
  bool get isDark => bgPrimary.computeLuminance() < 0.5;
  Color get secondary =>
      isDark ? const Color(0xFFDE8A78) : const Color(0xFFAE473C);
  Color get onAccent =>
      isDark ? const Color(0xFF0E1511) : const Color(0xFFFFFFFF);
  Color get shadow =>
      isDark ? const Color(0x2E000000) : const Color(0x1F000000);

  // Back-compat aliases used across the app.
  Color get scaffold => bgPrimary;
  Color get surface => bgCard;
  Color get surfaceRaised => bgSecondary;
  Color get surfaceMuted => bgTertiary;
  Color get text => textPrimary;
  Color get textSoft => textSecondary;
  Color get accentStrong => accentHover;
  Color get accentSoft => accentMuted;
  Color get error => danger;
}

NeoRecallPalette neoRecallPaletteFor(Brightness brightness) =>
    paletteFor(brightness);

NeoRecallPalette neoRecallPaletteOf(BuildContext context) =>
    neoRecallPaletteFor(Theme.of(context).brightness);

/// Section labels — the only place the mono face is used for chrome.
///
/// One eyebrow style, one size, one tracking. The design system has exactly
/// this and nothing else; a second "smaller eyebrow" is what started the drift
/// the redesign removed.
TextStyle sectionEyebrowStyle(NeoRecallPalette palette) =>
    GoogleFonts.geistMono(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.6,
      color: palette.textMuted,
    );

/// Numeric runs that must not shift width as they tick — clocks, durations,
/// byte counts, battery percentages.
TextStyle monoMetricStyle(
  NeoRecallPalette palette, {
  double size = 11.5,
  Color? color,
  FontWeight weight = FontWeight.w500,
}) => GoogleFonts.geistMono(
  fontSize: size,
  fontWeight: weight,
  color: color ?? palette.textMuted,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

TextStyle displayTitleStyle(NeoRecallPalette palette, {double size = 26}) =>
    TextStyle(
      color: palette.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: size,
      letterSpacing: -0.85,
      height: 1.1,
    );

TextStyle heroTitleStyle(NeoRecallPalette palette, {double size = 22}) =>
    TextStyle(
      color: palette.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: size,
      letterSpacing: -0.7,
      height: 1.15,
    );

ThemeData buildNeoRecallTheme(Brightness brightness) {
  final palette = neoRecallPaletteFor(brightness);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: palette.accent,
      brightness: brightness,
    ),
  );

  return base.copyWith(
    focusColor: palette.accent.withValues(alpha: 0.2),
    scaffoldBackgroundColor: palette.bgPrimary,
    colorScheme: base.colorScheme.copyWith(
      primary: palette.accent,
      secondary: palette.accentHover,
      tertiary: palette.secondary,
      surface: palette.bgCard,
      onSurface: palette.textPrimary,
      error: palette.danger,
    ),
    textTheme: GoogleFonts.geistTextTheme(
      base.textTheme,
    ).apply(bodyColor: palette.textPrimary, displayColor: palette.textPrimary),
    // Flat surfaces: a card is a fill and a hairline, never a gradient with a
    // tinted glow under it. Elevation is zero everywhere on purpose — depth in
    // this system comes from the sheet layer, not from every panel.
    cardTheme: CardThemeData(
      color: palette.bgCard,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(color: palette.border),
      ),
    ),
    dividerColor: palette.border,
    dividerTheme: DividerThemeData(
      color: palette.border,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.bgTertiary,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: TextStyle(
        color: palette.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
      ),
      hintStyle: TextStyle(color: palette.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: palette.borderLight),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: palette.borderLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: palette.accent, width: 1.4),
      ),
    ),
    iconTheme: IconThemeData(color: palette.textSecondary),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        disabledBackgroundColor: palette.bgTertiary,
        disabledForegroundColor: palette.textMuted,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
        ),
        textStyle: const TextStyle(
          fontSize: 14.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: palette.borderLight),
        backgroundColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
        ),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accentHover,
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.05,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: palette.textSecondary,
      textColor: palette.textPrimary,
      selectedColor: palette.accent,
      selectedTileColor: palette.accentMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return palette.accent;
        return palette.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return palette.accentMuted;
        return palette.bgTertiary;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return palette.accent.withValues(alpha: 0.34);
        }
        return palette.border;
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: palette.accent,
      inactiveTrackColor: palette.bgTertiary,
      thumbColor: palette.accent,
      overlayColor: palette.accent.withValues(alpha: 0.12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.bgTertiary,
      side: BorderSide(color: palette.border),
      labelStyle: TextStyle(
        color: palette.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      foregroundColor: palette.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: palette.textPrimary,
        fontWeight: FontWeight.w700,
        fontSize: 18,
        letterSpacing: -0.4,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.bgPrimary,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 21,
          color: selected ? palette.accent : palette.textMuted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: selected ? palette.accent : palette.textMuted,
        );
      }),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: palette.bgSecondary,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.bgCard,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: palette.bgCard,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.panel),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.bgCard,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(color: palette.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.bgCard,
      contentTextStyle: TextStyle(color: palette.textPrimary),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: palette.border),
      ),
    ),
  );
}
