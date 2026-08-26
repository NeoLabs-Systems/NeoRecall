package systems.neolabs.neorecall.widgets

import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Short forms for widget-sized space.
 *
 * Widgets have room for a number and a word, so every helper here answers with
 * the shortest form that is still unambiguous, and never with a placeholder
 * like "--" where a real zero would do.
 */
internal object WidgetFormat {
  /** A headline number split from its unit, so the two can be styled apart. */
  data class Measure(val value: String, val unit: String)

  fun talkTime(seconds: Int): Measure {
    if (seconds < 60) return Measure(seconds.coerceAtLeast(0).toString(), "sec")
    val minutes = seconds / 60
    if (minutes < 60) return Measure(minutes.toString(), "min")
    val hours = minutes / 60
    val remainder = minutes % 60
    if (hours < 10 && remainder != 0) {
      return Measure(String.format(Locale.US, "%d.%d", hours, remainder * 10 / 60), "hrs")
    }
    return Measure(hours.toString(), if (hours == 1) "hr" else "hrs")
  }

  /** "1h 12m", "42m", "35s" — for lines that read as prose rather than a metric. */
  fun duration(seconds: Int): String {
    if (seconds <= 0) return "0m"
    val hours = seconds / 3600
    val minutes = (seconds % 3600) / 60
    return when {
      hours > 0 && minutes > 0 -> "${hours}h ${minutes}m"
      hours > 0 -> "${hours}h"
      minutes > 0 -> "${minutes}m"
      else -> "${seconds}s"
    }
  }

  fun bytes(value: Long): String {
    val kilobyte = 1024L
    return when {
      value < kilobyte -> "$value B"
      value < kilobyte * kilobyte -> "${value / kilobyte} KB"
      value < kilobyte * kilobyte * kilobyte ->
        String.format(Locale.US, "%.1f MB", value.toDouble() / (kilobyte * kilobyte))
      else ->
        String.format(Locale.US, "%.1f GB", value.toDouble() / (kilobyte * kilobyte * kilobyte))
    }
  }

  /** "now", "12m", "3h", "Tue", "12 Mar" — newest first, coarsening with age. */
  fun relativeTime(atMillis: Long, nowMillis: Long): String {
    if (atMillis <= 0L) return ""
    val elapsed = nowMillis - atMillis
    if (elapsed < TimeUnit.MINUTES.toMillis(1)) return "now"
    if (elapsed < TimeUnit.HOURS.toMillis(1)) return "${TimeUnit.MILLISECONDS.toMinutes(elapsed)}m"
    if (isSameDay(atMillis, nowMillis)) return "${TimeUnit.MILLISECONDS.toHours(elapsed)}h"
    if (elapsed < TimeUnit.DAYS.toMillis(7)) return weekdayShort(atMillis)
    return dayAndMonth(atMillis)
  }

  /** Due dates read as urgency first and a date only when that is what is left. */
  fun dueLabel(dueMillis: Long?, overdue: Boolean, nowMillis: Long): String? {
    if (overdue) return "OVERDUE"
    if (dueMillis == null || dueMillis <= 0L) return null
    if (isSameDay(dueMillis, nowMillis)) return "TODAY"
    if (isSameDay(dueMillis, nowMillis + TimeUnit.DAYS.toMillis(1))) return "TOMORROW"
    if (dueMillis - nowMillis < TimeUnit.DAYS.toMillis(7)) {
      return weekdayShort(dueMillis).uppercase(Locale.getDefault())
    }
    return dayAndMonth(dueMillis).uppercase(Locale.getDefault())
  }

  fun count(value: Int, singular: String, plural: String): String =
    "$value ${if (value == 1) singular else plural}"

  private fun weekdayShort(atMillis: Long): String =
    android.text.format.DateFormat.format("EEE", atMillis).toString()

  private fun dayAndMonth(atMillis: Long): String =
    android.text.format.DateFormat.format("d MMM", atMillis).toString()

  fun isSameDay(first: Long, second: Long): Boolean {
    val left = Calendar.getInstance().apply { timeInMillis = first }
    val right = Calendar.getInstance().apply { timeInMillis = second }
    return left.get(Calendar.YEAR) == right.get(Calendar.YEAR) &&
      left.get(Calendar.DAY_OF_YEAR) == right.get(Calendar.DAY_OF_YEAR)
  }
}
