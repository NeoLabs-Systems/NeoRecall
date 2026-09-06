package systems.neolabs.neorecall.wear.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme

/**
 * NeoRecall's palette, as it survives the move to a watch.
 *
 * The phone's dark theme sits on a near-black green; a watch panel is OLED, so
 * the page itself drops to true black — that is what makes the round bezel
 * disappear and saves the battery an always-on screen otherwise spends — while
 * cards keep the app's green-grey so the two products still look related.
 */
object NeoRecallPalette {
  val page = Color(0xFF000000)
  val surface = Color(0xFF121914)
  val surfaceHigh = Color(0xFF1B2420)
  val surfaceLow = Color(0xFF0B100D)
  val accent = Color(0xFFE1B052)
  val accentBright = Color(0xFFEAC272)
  val onAccent = Color(0xFF0E1511)
  val green = Color(0xFF84BA87)
  val success = Color(0xFF74C07C)
  val danger = Color(0xFFDE8A78)
  val info = Color(0xFF6FB0A4)
  val textPrimary = Color(0xFFECEFE5)
  val textSecondary = Color(0xFFAEB7A6)
  val textMuted = Color(0xFF7E8877)
  val outline = Color(0xFF2C3730)
}

private val neoRecallColorScheme = ColorScheme(
  primary = NeoRecallPalette.accent,
  primaryDim = Color(0xFFB98F3E),
  primaryContainer = Color(0xFF3A2F16),
  onPrimary = NeoRecallPalette.onAccent,
  onPrimaryContainer = NeoRecallPalette.accentBright,
  secondary = NeoRecallPalette.green,
  secondaryDim = Color(0xFF5F8F63),
  secondaryContainer = Color(0xFF1E2C20),
  onSecondary = NeoRecallPalette.onAccent,
  onSecondaryContainer = Color(0xFFBFE0C1),
  tertiary = NeoRecallPalette.info,
  tertiaryDim = Color(0xFF4C8378),
  tertiaryContainer = Color(0xFF142723),
  onTertiary = NeoRecallPalette.onAccent,
  onTertiaryContainer = Color(0xFFA9D8CE),
  error = NeoRecallPalette.danger,
  errorDim = Color(0xFFA9614F),
  errorContainer = Color(0xFF331914),
  onError = NeoRecallPalette.onAccent,
  onErrorContainer = Color(0xFFF3BCAF),
  background = NeoRecallPalette.page,
  onBackground = NeoRecallPalette.textPrimary,
  surfaceContainerLow = NeoRecallPalette.surfaceLow,
  surfaceContainer = NeoRecallPalette.surface,
  surfaceContainerHigh = NeoRecallPalette.surfaceHigh,
  onSurface = NeoRecallPalette.textPrimary,
  onSurfaceVariant = NeoRecallPalette.textSecondary,
  outline = NeoRecallPalette.outline,
  outlineVariant = Color(0xFF1F2823),
)

@Composable
fun NeoRecallWearTheme(content: @Composable () -> Unit) {
  MaterialTheme(colorScheme = neoRecallColorScheme, content = content)
}
