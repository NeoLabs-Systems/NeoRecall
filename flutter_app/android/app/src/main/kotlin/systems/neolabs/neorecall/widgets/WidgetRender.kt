package systems.neolabs.neorecall.widgets

import android.view.View
import android.widget.RemoteViews
import systems.neolabs.neorecall.R

/**
 * Shared RemoteViews vocabulary.
 *
 * RemoteViews actions on a view that a given layout does not contain are
 * dropped rather than raised, which is what lets one render path address the
 * full, compact, and icon-sized layouts of the same widget without branching on
 * every line.
 */
internal object WidgetRender {
  /** Twelve pips stand in for a progress bar, which cannot be resized before API 31. */
  const val METER_PIPS = 12

  /** Six stacked blocks per day; enough resolution to read a week at a glance. */
  const val WEEK_LEVELS = 6
  const val WEEK_DAYS = 7

  private val pipIds = intArrayOf(
    R.id.widget_pip_1, R.id.widget_pip_2, R.id.widget_pip_3, R.id.widget_pip_4,
    R.id.widget_pip_5, R.id.widget_pip_6, R.id.widget_pip_7, R.id.widget_pip_8,
    R.id.widget_pip_9, R.id.widget_pip_10, R.id.widget_pip_11, R.id.widget_pip_12,
  )

  private val dayLabelIds = intArrayOf(
    R.id.widget_day_1, R.id.widget_day_2, R.id.widget_day_3, R.id.widget_day_4,
    R.id.widget_day_5, R.id.widget_day_6, R.id.widget_day_7,
  )

  private val blockIds = arrayOf(
    intArrayOf(R.id.widget_block_1_1, R.id.widget_block_1_2, R.id.widget_block_1_3, R.id.widget_block_1_4, R.id.widget_block_1_5, R.id.widget_block_1_6),
    intArrayOf(R.id.widget_block_2_1, R.id.widget_block_2_2, R.id.widget_block_2_3, R.id.widget_block_2_4, R.id.widget_block_2_5, R.id.widget_block_2_6),
    intArrayOf(R.id.widget_block_3_1, R.id.widget_block_3_2, R.id.widget_block_3_3, R.id.widget_block_3_4, R.id.widget_block_3_5, R.id.widget_block_3_6),
    intArrayOf(R.id.widget_block_4_1, R.id.widget_block_4_2, R.id.widget_block_4_3, R.id.widget_block_4_4, R.id.widget_block_4_5, R.id.widget_block_4_6),
    intArrayOf(R.id.widget_block_5_1, R.id.widget_block_5_2, R.id.widget_block_5_3, R.id.widget_block_5_4, R.id.widget_block_5_5, R.id.widget_block_5_6),
    intArrayOf(R.id.widget_block_6_1, R.id.widget_block_6_2, R.id.widget_block_6_3, R.id.widget_block_6_4, R.id.widget_block_6_5, R.id.widget_block_6_6),
    intArrayOf(R.id.widget_block_7_1, R.id.widget_block_7_2, R.id.widget_block_7_3, R.id.widget_block_7_4, R.id.widget_block_7_5, R.id.widget_block_7_6),
  )

  fun RemoteViews.background(viewId: Int, drawableId: Int) =
    setInt(viewId, "setBackgroundResource", drawableId)

  fun RemoteViews.tint(viewId: Int, color: Int) = setInt(viewId, "setColorFilter", color)

  fun RemoteViews.show(viewId: Int, visible: Boolean) =
    setViewVisibility(viewId, if (visible) View.VISIBLE else View.GONE)

  /** Sets text and hides the view when there is none, so no empty row is left behind. */
  fun RemoteViews.textOrHide(viewId: Int, value: String?) {
    val trimmed = value?.trim().orEmpty()
    setTextViewText(viewId, trimmed)
    show(viewId, trimmed.isNotEmpty())
  }

  fun RemoteViews.surface(theme: WidgetTheme) {
    background(R.id.widget_root, theme.surface)
    tint(R.id.widget_configure, theme.textMuted)
  }

  /**
   * Draws [fraction] across the pip row. A null fraction means work is under way
   * with no measurable size — every pip is lit at the muted weight rather than
   * left dark, which would read as "nothing is happening".
   */
  fun RemoteViews.meter(theme: WidgetTheme, fraction: Double?, alert: Boolean = false) {
    val lit = when {
      fraction == null -> METER_PIPS
      else -> Math.round(fraction.coerceIn(0.0, 1.0) * METER_PIPS).toInt()
    }
    val on = if (alert) theme.pipAlert else theme.pipOn
    pipIds.forEachIndexed { index, id ->
      setImageViewResource(id, if (index < lit) on else theme.pipOff)
    }
  }

  /** The trailing week as stacked blocks, tallest day full. */
  fun RemoteViews.week(theme: WidgetTheme, days: List<Int>, labels: List<String>, todayIndex: Int) {
    val peak = days.maxOrNull() ?: 0
    for (day in 0 until WEEK_DAYS) {
      val value = days.getOrElse(day) { 0 }
      // A day with anything at all keeps one block, so a quiet day still reads
      // as a day rather than as missing data.
      val filled = when {
        peak <= 0 || value <= 0 -> 0
        else -> ((value.toDouble() / peak) * WEEK_LEVELS).toInt().coerceIn(1, WEEK_LEVELS)
      }
      val on = if (day == todayIndex) theme.blockToday else theme.blockOn
      val column = blockIds[day]
      for (level in 0 until WEEK_LEVELS) {
        setImageViewResource(column[level], if (level < filled) on else theme.blockOff)
      }
      setTextViewText(dayLabelIds[day], labels.getOrElse(day) { "" })
      setTextColor(
        dayLabelIds[day],
        if (day == todayIndex) theme.accentAlt else theme.textMuted,
      )
    }
  }
}
