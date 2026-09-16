import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'main_spacing.dart';

/// Canonical color tokens for the shared "Control Surface" design system.
///
/// These values are identical to NeoAgent's `lib/src/theme/palette.dart`: the
/// two apps are one product family, so a color that drifts here is a bug, not a
/// style choice. `theme_test.dart` pins the accents for exactly that reason.
class NeoRecallPalette {
  const NeoRecallPalette({
    required this.bgPrimary,
    required this.bgSecondary,
    required this.bgTertiary,
    required this.bgCard,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentHover,
    required this.accentAlt,
    required this.accentMuted,
    required this.secondary,
    required this.border,
    required this.borderLight,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.onAccent,
    required this.shadow,
  });

  final Color bgPrimary;
  final Color bgSecondary;
  final Color bgTertiary;
  final Color bgCard;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentHover;
  final Color accentAlt;
  final Color accentMuted;
  final Color secondary;
  final Color border;
  final Color borderLight;
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;
  final Color onAccent;
  final Color shadow;

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
  bool get isDark => bgPrimary.computeLuminance() < 0.5;
}

const NeoRecallPalette _darkPalette = NeoRecallPalette(
  bgPrimary: Color(0xFF0E1511),
  bgSecondary: Color(0xFF171F1A),
  bgTertiary: Color(0xFF1C261F),
  bgCard: Color(0xFF171F1A),
  textPrimary: Color(0xFFECEFE5),
  textSecondary: Color(0xFFAEB7A6),
  textMuted: Color(0xFF7E8877),
  accent: Color(0xFFE1B052),
  accentHover: Color(0xFFEAC272),
  accentAlt: Color(0xFF84BA87),
  accentMuted: Color(0x24E1B052),
  secondary: Color(0xFFDE8A78),
  border: Color(0x14E0F0E0),
  borderLight: Color(0x24E0F0E0),
  success: Color(0xFF74C07C),
  warning: Color(0xFFD9A24B),
  danger: Color(0xFFDE8A78),
  info: Color(0xFF6FB0A4),
  onAccent: Color(0xFF0E1511),
  shadow: Color(0x2E000000),
);

const NeoRecallPalette _lightPalette = NeoRecallPalette(
  bgPrimary: Color(0xFFF4F1E8),
  bgSecondary: Color(0xFFEDE9DC),
  bgTertiary: Color(0xFFF1EDE1),
  bgCard: Color(0xFFFDFCF8),
  textPrimary: Color(0xFF1C2117),
  textSecondary: Color(0xFF49503F),
  textMuted: Color(0xFF7E8470),
  accent: Color(0xFFB07D2B),
  accentHover: Color(0xFFC8943F),
  accentAlt: Color(0xFF5E6B4C),
  accentMuted: Color(0x24B07D2B),
  secondary: Color(0xFFAE473C),
  border: Color(0x1A1C2117),
  borderLight: Color(0x291C2117),
  success: Color(0xFF527C4F),
  warning: Color(0xFF9A6B1E),
  danger: Color(0xFFAE473C),
  info: Color(0xFF2F7D6E),
  onAccent: Color(0xFFFFFFFF),
  shadow: Color(0x1F000000),
);

NeoRecallPalette neoRecallPaletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? _darkPalette : _lightPalette;

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
