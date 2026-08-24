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
      Color.lerp(bgPrimary, bgSecondary, 0.55)!,
      bgPrimary,
    ],
    stops: const <double>[0, 0.62, 1],
    begin: const Alignment(-0.95, -1),
    end: const Alignment(1, 0.92),
  );
  Gradient get panelGradient => LinearGradient(
    colors: <Color>[bgCard, Color.lerp(bgCard, bgSecondary, 0.25)!],
    begin: const Alignment(-0.85, -1),
    end: const Alignment(1, 1),
  );
}

const NeoRecallPalette _darkPalette = NeoRecallPalette(
  bgPrimary: Color(0xFF151514),
  bgSecondary: Color(0xFF1E1E1C),
  bgTertiary: Color(0xFF272725),
  bgCard: Color(0xFF20201E),
  textPrimary: Color(0xFFF4F3EE),
  textSecondary: Color(0xFFC3C1B8),
  textMuted: Color(0xFF8D8B83),
  accent: Color(0xFF8FA0FF),
  accentHover: Color(0xFFAAB6FF),
  accentAlt: Color(0xFF8BB7A4),
  accentMuted: Color(0x248FA0FF),
  secondary: Color(0xFFFF786D),
  border: Color(0x18FFFFFF),
  borderLight: Color(0x2AFFFFFF),
  success: Color(0xFF82C79B),
  warning: Color(0xFFE2B66A),
  danger: Color(0xFFFF786D),
  info: Color(0xFF8FA0FF),
  onAccent: Color(0xFF111110),
  shadow: Color(0xA0000000),
);

const NeoRecallPalette _lightPalette = NeoRecallPalette(
  bgPrimary: Color(0xFFF8F7F2),
  bgSecondary: Color(0xFFF0EFE9),
  bgTertiary: Color(0xFFE8E7E1),
  bgCard: Color(0xFFFFFFFF),
  textPrimary: Color(0xFF151514),
  textSecondary: Color(0xFF51504B),
  textMuted: Color(0xFF85837C),
  accent: Color(0xFF5E73E8),
  accentHover: Color(0xFF495FD2),
  accentAlt: Color(0xFF5F8F7B),
  accentMuted: Color(0x1F5E73E8),
  secondary: Color(0xFFE5534B),
  border: Color(0x14000000),
  borderLight: Color(0x24000000),
  success: Color(0xFF3F7A58),
  warning: Color(0xFF9A6B1E),
  danger: Color(0xFFC6403A),
  info: Color(0xFF495FD2),
  onAccent: Color(0xFFFFFFFF),
  shadow: Color(0x22000000),
);

NeoRecallPalette neoRecallPaletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? _darkPalette : _lightPalette;

NeoRecallPalette neoRecallPaletteOf(BuildContext context) =>
    neoRecallPaletteFor(Theme.of(context).brightness);

TextStyle sectionEyebrowStyle(NeoRecallPalette palette) =>
    GoogleFonts.geistMono(
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
      letterSpacing: -0.9,
      height: 1.08,
    );

TextStyle heroTitleStyle(NeoRecallPalette palette, {double size = 24}) =>
    TextStyle(
      color: palette.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: size,
      letterSpacing: -0.8,
      height: 1.08,
    );

List<BoxShadow> softPanelShadow(NeoRecallPalette palette) => <BoxShadow>[
  BoxShadow(color: palette.shadow, blurRadius: 24, offset: const Offset(0, 10)),
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
    textTheme: GoogleFonts.geistTextTheme(
      base.textTheme,
    ).apply(bodyColor: palette.textPrimary, displayColor: palette.textPrimary),
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
