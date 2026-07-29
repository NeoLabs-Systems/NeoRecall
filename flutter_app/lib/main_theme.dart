import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'main_spacing.dart';

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
  Color get glassFill => bgCard.withValues(alpha: 0.86);
  Color get glassBorder => borderLight;
  Color get borderStrong => borderLight;
  Gradient get backgroundGradient => LinearGradient(
        colors: <Color>[
          bgPrimary,
          Color.lerp(bgSecondary, accentAlt, 0.08)!.withValues(alpha: 0.98),
          Color.lerp(bgPrimary, accent, 0.05)!,
        ],
        stops: const <double>[0, 0.52, 1],
        begin: const Alignment(-0.95, -1),
        end: const Alignment(1, 0.92),
      );
  Gradient get panelGradient => LinearGradient(
        colors: <Color>[
          Colors.white.withValues(alpha: 0.10),
          bgCard.withValues(alpha: 0.94),
          bgSecondary.withValues(alpha: 0.88),
        ],
        stops: const <double>[0, 0.2, 1],
        begin: const Alignment(-0.85, -1),
        end: const Alignment(1, 1),
      );
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
  secondary: Color(0xFFD98AA6),
  border: Color(0x14E0F0E0),
  borderLight: Color(0x24E0F0E0),
  success: Color(0xFF74C07C),
  warning: Color(0xFFE1B052),
  danger: Color(0xFFDE8A78),
  info: Color(0xFF6FB0A4),
  onAccent: Color(0xFF0E1511),
  shadow: Color(0xA0000000),
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
  secondary: Color(0xFFA8506E),
  border: Color(0x1A1C2117),
  borderLight: Color(0x291C2117),
  success: Color(0xFF527C4F),
  warning: Color(0xFF9A6B1E),
  danger: Color(0xFFAE473C),
  info: Color(0xFF2F7D6E),
  onAccent: Color(0xFFFDFCF8),
  shadow: Color(0x241C2117),
);

NeoRecallPalette neoRecallPaletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? _darkPalette : _lightPalette;

NeoRecallPalette neoRecallPaletteOf(BuildContext context) =>
    neoRecallPaletteFor(Theme.of(context).brightness);

TextStyle sectionEyebrowStyle(NeoRecallPalette palette) => GoogleFonts.geistMono(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.7,
      color: palette.accentHover,
    );

TextStyle displayTitleStyle(NeoRecallPalette palette, {double size = 28}) =>
    TextStyle(
      color: palette.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: size,
      letterSpacing: -0.8,
      height: 1.08,
    );

TextStyle heroTitleStyle(NeoRecallPalette palette, {double size = 24}) =>
    TextStyle(
      color: palette.textPrimary,
      fontWeight: FontWeight.w800,
      fontSize: size,
      letterSpacing: -1.0,
      height: 1.1,
    );

List<BoxShadow> softPanelShadow(NeoRecallPalette palette) => <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.18),
        blurRadius: 40,
        offset: const Offset(0, 18),
      ),
      BoxShadow(
        color: palette.accent.withValues(alpha: 0.07),
        blurRadius: 28,
        offset: const Offset(0, 8),
      ),
    ];

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
    textTheme: GoogleFonts.geistTextTheme(base.textTheme).apply(
      bodyColor: palette.textPrimary,
      displayColor: palette.textPrimary,
    ),
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      color: palette.bgCard.withValues(
        alpha: brightness == Brightness.dark ? 0.86 : 0.96,
      ),
      surfaceTintColor: Colors.transparent,
      elevation: brightness == Brightness.dark ? 8 : 3,
      shadowColor: Colors.black.withValues(
        alpha: brightness == Brightness.dark ? 0.24 : 0.12,
      ),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.panel),
        side: BorderSide(
          color: Colors.white.withValues(
            alpha: brightness == Brightness.dark ? 0.08 : 0.22,
          ),
        ),
      ),
    ),
    dividerColor: palette.border,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.bgSecondary.withValues(
        alpha: brightness == Brightness.dark ? 0.82 : 0.84,
      ),
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
        borderSide: BorderSide(color: palette.accentHover, width: 1.4),
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
          side: BorderSide(
            color: Colors.white.withValues(
              alpha: brightness == Brightness.dark ? 0.14 : 0.22,
            ),
          ),
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
        side: BorderSide(
          color: Colors.white.withValues(
            alpha: brightness == Brightness.dark ? 0.12 : 0.26,
          ),
        ),
        backgroundColor: palette.bgCard.withValues(
          alpha: brightness == Brightness.dark ? 0.2 : 0.5,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accentHover,
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.05,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: palette.textSecondary,
      textColor: palette.textPrimary,
      selectedColor: palette.accentHover,
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
        return palette.border;
      }),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: palette.accent,
      inactiveTrackColor: palette.border,
      thumbColor: palette.accentHover,
      overlayColor: palette.accent.withValues(alpha: 0.12),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: palette.textPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: palette.textPrimary,
        fontWeight: FontWeight.w700,
        fontSize: 18,
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: palette.bgSecondary,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.bgCard,
      contentTextStyle: TextStyle(color: palette.textPrimary),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: palette.borderLight),
      ),
    ),
  );
}
