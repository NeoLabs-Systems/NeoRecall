package systems.neolabs.neorecall.wear.ui.common

import android.text.format.DateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

/**
 * Short forms for a screen measured in millimetres.
 *
 * Every helper answers with the shortest form that is still unambiguous, and
 * never with a placeholder where a real zero would do — the same rule the phone
 * widgets follow, so the two surfaces read alike.
 */
object WatchFormat {
  /** "07:21", "1:04:09" — a running clock, so it stays legible at a glance. */
  fun elapsed(millis: Long): String {
    val total = (millis / 1000).coerceAtLeast(0L)
    val hours = total / 3600
    val minutes = (total % 3600) / 60
    val seconds = total % 60
    return if (hours > 0) {
      String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      String.format(Locale.US, "%02d:%02d", minutes, seconds)
    }
  }

  /** "1h 12m", "42m", "35s" — for lines that read as prose. */
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

  /** "now", "12m", "3h", "Tue", "12 Mar" — coarsening with age. */
  fun relativeTime(atMillis: Long, nowMillis: Long): String {
    if (atMillis <= 0L) return ""
    val elapsed = nowMillis - atMillis
    if (elapsed < TimeUnit.MINUTES.toMillis(1)) return "now"
    if (elapsed < TimeUnit.HOURS.toMillis(1)) return "${TimeUnit.MILLISECONDS.toMinutes(elapsed)}m"
    if (isSameDay(atMillis, nowMillis)) return "${TimeUnit.MILLISECONDS.toHours(elapsed)}h"
    if (elapsed < TimeUnit.DAYS.toMillis(7)) return weekdayShort(atMillis)
    return dayAndMonth(atMillis)
  }

  /** Clock time for a transcript line, which is what a reader scans by. */
  fun clock(atMillis: Long): String =
    if (atMillis <= 0L) "" else DateFormat.format("HH:mm", atMillis).toString()

  /** Due dates read as urgency first, and a date only when that is what is left. */
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
    DateFormat.format("EEE", atMillis).toString()

  private fun dayAndMonth(atMillis: Long): String =
    DateFormat.format("d MMM", atMillis).toString()

  fun isSameDay(first: Long, second: Long): Boolean {
    val left = Calendar.getInstance().apply { timeInMillis = first }
    val right = Calendar.getInstance().apply { timeInMillis = second }
    return left.get(Calendar.YEAR) == right.get(Calendar.YEAR) &&
      left.get(Calendar.DAY_OF_YEAR) == right.get(Calendar.DAY_OF_YEAR)
  }
}
