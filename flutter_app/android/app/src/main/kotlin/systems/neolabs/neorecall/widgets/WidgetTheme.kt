package systems.neolabs.neorecall.widgets

import android.content.Context
import android.content.res.Configuration
import systems.neolabs.neorecall.R

/**
 * The colour and drawable set one widget renders with.
 *
 * Widgets are inflated in the launcher's process, where `?attr` lookups and
 * theme overlays are unavailable, so every state-dependent colour is resolved
 * here and pushed as a literal. The layouts still reference the night-qualified
 * `@color`/`@drawable` aliases, which is what makes a widget look right in the
 * picker preview and at first placement, before the app has published anything.
 */
internal class WidgetTheme private constructor(val dark: Boolean) {
  val textPrimary = color(0xFFECEFE5, 0xFF1C2117)
  val textSecondary = color(0xFFAEB7A6, 0xFF49503F)
  val textMuted = color(0xFF7E8877, 0xFF7E8470)
  val accent = color(0xFFE1B052, 0xFFB07D2B)
  val accentAlt = color(0xFF84BA87, 0xFF5E6B4C)
  val danger = color(0xFFDE8A78, 0xFFAE473C)
  val success = color(0xFF74C07C, 0xFF527C4F)
  val info = color(0xFF6FB0A4, 0xFF2F7D6E)
  val onAccent = color(0xFF0E1511, 0xFFFFFFFF)

  val surface = drawable(R.drawable.widget_surface_dark, R.drawable.widget_surface_light)
  val panel = drawable(R.drawable.widget_panel_dark, R.drawable.widget_panel_light)
  val row = drawable(R.drawable.widget_row_dark, R.drawable.widget_row_light)
  val divider = drawable(R.drawable.widget_divider_dark, R.drawable.widget_divider_light)
  val pipOn = drawable(R.drawable.widget_pip_on_dark, R.drawable.widget_pip_on_light)
  val pipOff = drawable(R.drawable.widget_pip_off_dark, R.drawable.widget_pip_off_light)
  val pipAlert = drawable(R.drawable.widget_pip_alert_dark, R.drawable.widget_pip_alert_light)
  val blockOn = drawable(R.drawable.widget_block_on_dark, R.drawable.widget_block_on_light)
  val blockToday = drawable(R.drawable.widget_block_today_dark, R.drawable.widget_block_today_light)
  val blockOff = drawable(R.drawable.widget_block_off_dark, R.drawable.widget_block_off_light)
  val chipAccent = drawable(R.drawable.widget_chip_accent_dark, R.drawable.widget_chip_accent_light)
  val chipAlt = drawable(R.drawable.widget_chip_alt_dark, R.drawable.widget_chip_alt_light)
  val chipDanger = drawable(R.drawable.widget_chip_danger_dark, R.drawable.widget_chip_danger_light)
  val chipMuted = drawable(R.drawable.widget_chip_muted_dark, R.drawable.widget_chip_muted_light)
  val actionReady =
    drawable(R.drawable.widget_action_ready_dark, R.drawable.widget_action_ready_light)
  val actionRecording =
    drawable(R.drawable.widget_action_recording_dark, R.drawable.widget_action_recording_light)
  val actionGhost =
    drawable(R.drawable.widget_action_ghost_dark, R.drawable.widget_action_ghost_light)
  val actionSoft =
    drawable(R.drawable.widget_action_soft_dark, R.drawable.widget_action_soft_light)

  private fun color(darkValue: Long, lightValue: Long) =
    (if (dark) darkValue else lightValue).toInt()

  private fun drawable(darkId: Int, lightId: Int) = if (dark) darkId else lightId

  companion object {
    const val AUTO = "auto"
    const val DARK = "dark"
    const val LIGHT = "light"

    private val darkTheme = WidgetTheme(dark = true)
    private val lightTheme = WidgetTheme(dark = false)

    /**
     * "Auto" follows the app process's own night mode, which tracks the system
     * setting. A widget resolved while the app was dead can therefore lag a
     * theme change by one update, so [systems.neolabs.neorecall.NeoRecallApplication]
     * refreshes every widget when its configuration changes.
     */
    fun of(context: Context, mode: String?): WidgetTheme = when (mode) {
      DARK -> darkTheme
      LIGHT -> lightTheme
      else -> if (isSystemDark(context)) darkTheme else lightTheme
    }

    private fun isSystemDark(context: Context): Boolean =
      (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
        Configuration.UI_MODE_NIGHT_YES
  }
}
