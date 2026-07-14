import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// Gold is the fixed NeoLabs family accent. Muted rose is NeoRecall's
// product-specific recording accent.
class NeoRecallPalette {
  const NeoRecallPalette({
    required this.scaffold,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceMuted,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textSoft,
    required this.textMuted,
    required this.accent,
    required this.accentStrong,
    required this.accentSoft,
    required this.onAccent,
    required this.secondary,
    required this.success,
    required this.warning,
    required this.error,
    required this.shadow,
    required this.glassFill,
    required this.glassBorder,
    required this.backgroundGradient,
    required this.panelGradient,
  });

  final Color scaffold;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceMuted;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textSoft;
  final Color textMuted;
  final Color accent;
  final Color accentStrong;
  final Color accentSoft;
  final Color onAccent;
  final Color secondary;
  final Color success;
  final Color warning;
  final Color error;
  final Color shadow;
  final Color glassFill;
  final Color glassBorder;
  final Gradient backgroundGradient;
  final Gradient panelGradient;
}

// Deep charcoal-navy ground with the fixed NeoLabs gold accent.
const NeoRecallPalette _darkPalette = NeoRecallPalette(
  scaffold: Color(0xFF0A0D13),
  surface: Color(0xFF12161F),
  surfaceRaised: Color(0xFF181D29),
  surfaceMuted: Color(0xFF1E2433),
  border: Color(0x1AFFFFFF),
  borderStrong: Color(0x26FFFFFF),
  text: Color(0xFFF1F2F6),
  textSoft: Color(0xFFB7BCCC),
  textMuted: Color(0xFF7E8499),
  accent: Color(0xFFE3B655),
  accentStrong: Color(0xFFF1C871),
  accentSoft: Color(0x26E3B655),
  onAccent: Color(0xFF1A1306),
  secondary: Color(0xFFD98AA6),
  success: Color(0xFF5FC793),
  warning: Color(0xFFE3B655),
  error: Color(0xFFE57F7F),
  shadow: Color(0x70000000),
  glassFill: Color(0x99151A24),
  glassBorder: Color(0x1FFFFFFF),
  backgroundGradient: LinearGradient(
    colors: <Color>[Color(0xFF080A0F), Color(0xFF0C0F17), Color(0xFF11141F)],
    stops: <double>[0, 0.5, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  panelGradient: LinearGradient(
    colors: <Color>[Color(0xE6171B26), Color(0xE6141821), Color(0xF20F121A)],
    stops: <double>[0, 0.4, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
);

const NeoRecallPalette _lightPalette = NeoRecallPalette(
  scaffold: Color(0xFFF4F3EE),
  surface: Color(0xFFFFFFFF),
  surfaceRaised: Color(0xFFFCFBF7),
  surfaceMuted: Color(0xFFEEEBE1),
  border: Color(0x141A211B),
  borderStrong: Color(0x221A211B),
  text: Color(0xFF1A1D24),
  textSoft: Color(0xFF4A4F5C),
  textMuted: Color(0xFF767C8C),
  accent: Color(0xFFB1812B),
  accentStrong: Color(0xFF8F6A22),
  accentSoft: Color(0x1CB1812B),
  onAccent: Color(0xFFFFFFFF),
  secondary: Color(0xFFA8506E),
  success: Color(0xFF2F8A5C),
  warning: Color(0xFF9A6B1E),
  error: Color(0xFFB6473F),
  shadow: Color(0x140E120F),
  glassFill: Color(0xCCFFFFFF),
  glassBorder: Color(0x1F1A211B),
  backgroundGradient: LinearGradient(
    colors: <Color>[Color(0xFFF6F4ED), Color(0xFFF8F6F0), Color(0xFFECE8DC)],
    stops: <double>[0, 0.5, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
  panelGradient: LinearGradient(
    colors: <Color>[Color(0xFAFFFFFF), Color(0xFAFAF8F2), Color(0xF5F4F1E7)],
    stops: <double>[0, 0.4, 1],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
);

NeoRecallPalette neoRecallPaletteFor(Brightness brightness) =>
    brightness == Brightness.dark ? _darkPalette : _lightPalette;

NeoRecallPalette neoRecallPaletteOf(BuildContext context) =>
    neoRecallPaletteFor(Theme.of(context).brightness);

TextStyle sectionEyebrowStyle(NeoRecallPalette palette) => TextStyle(
  color: palette.accentStrong,
  fontWeight: FontWeight.w700,
  fontSize: 12,
  letterSpacing: 1.6,
);

TextStyle displayTitleStyle(NeoRecallPalette palette, {double size = 28}) =>
    TextStyle(
      color: palette.text,
      fontWeight: FontWeight.w800,
      fontSize: size,
      letterSpacing: -0.9,
      height: 1.1,
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
    scaffoldBackgroundColor: palette.scaffold,
    colorScheme: base.colorScheme.copyWith(
      primary: palette.accent,
      secondary: palette.secondary,
      tertiary: palette.secondary,
      surface: palette.surface,
      onSurface: palette.text,
      error: palette.error,
    ),
    textTheme: GoogleFonts.geistTextTheme(
      base.textTheme,
    ).apply(bodyColor: palette.text, displayColor: palette.text),
    splashFactory: InkSparkle.splashFactory,
    cardTheme: CardThemeData(
      color: palette.surface.withValues(
        alpha: brightness == Brightness.dark ? 0.92 : 0.97,
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: palette.shadow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: palette.borderStrong),
      ),
    ),
    dividerColor: palette.border,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceMuted.withValues(
        alpha: brightness == Brightness.dark ? 0.82 : 0.88,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      labelStyle: TextStyle(
        color: palette.textMuted,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      hintStyle: TextStyle(color: palette.textMuted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.accent, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.error, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        disabledBackgroundColor: palette.surfaceMuted,
        disabledForegroundColor: palette.textMuted,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.1,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.text,
        backgroundColor: palette.surface.withValues(
          alpha: brightness == Brightness.dark ? 0.3 : 0.65,
        ),
        side: BorderSide(color: palette.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accentStrong,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
    iconTheme: IconThemeData(color: palette.textSoft),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: palette.surfaceMuted,
      selectedColor: palette.accentSoft,
      side: BorderSide(color: palette.borderStrong),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: TextStyle(
        color: palette.textSoft,
        fontWeight: FontWeight.w600,
        fontSize: 12,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: palette.textMuted,
      textColor: palette.text,
      selectedTileColor: palette.accentSoft,
      selectedColor: palette.accentStrong,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderStrong),
      ),
      textStyle: TextStyle(color: palette.text, fontSize: 12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return palette.accent;
        return palette.textMuted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return palette.accentSoft;
        return palette.surfaceMuted;
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: palette.accentSoft,
      selectedIconTheme: IconThemeData(color: palette.accent),
      selectedLabelTextStyle: TextStyle(
        color: palette.text,
        fontWeight: FontWeight.w700,
      ),
      unselectedIconTheme: IconThemeData(color: palette.textMuted),
      unselectedLabelTextStyle: TextStyle(color: palette.textMuted),
      labelType: NavigationRailLabelType.all,
    ),
  );
}
