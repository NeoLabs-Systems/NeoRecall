package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews
import systems.neolabs.neorecall.R
import systems.neolabs.neorecall.widgets.WidgetRender.background
import systems.neolabs.neorecall.widgets.WidgetRender.show
import systems.neolabs.neorecall.widgets.WidgetRender.surface
import systems.neolabs.neorecall.widgets.WidgetRender.textOrHide
import systems.neolabs.neorecall.widgets.WidgetRender.week

/**
 * Today as one headline number, read against the week behind it.
 *
 * The trailing week is what makes the number mean anything: forty minutes is a
 * quiet day or a busy one depending entirely on the six days before it.
 */
internal object TodayWidgetRenderer : WidgetRenderer {
  private const val COMPACT_MAX_HEIGHT_DP = 120

  private data class Metric(
    val value: String,
    val unit: String,
    val label: String,
    val series: List<Int>,
    val labels: List<String>,
    val todayIndex: Int,
    val page: String,
  )

  private data class Stat(val id: String, val value: String, val label: String, val color: Int?)

  override fun render(
    context: Context,
    manager: AppWidgetManager,
    appWidgetId: Int,
  ): RemoteViews {
    val kind = WidgetKind.TODAY
    val theme = kind.theme(context, appWidgetId)
    val choice = kind.option(context, appWidgetId, WidgetOptionKeys.METRIC)
    val snapshot = WidgetStore.snapshot(context)
    val height = try {
      manager.getAppWidgetOptions(appWidgetId)
        .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
    } catch (_: Exception) {
      0
    }
    val compact = height in 1 until COMPACT_MAX_HEIGHT_DP
    val views = RemoteViews(
      context.packageName,
      if (compact) R.layout.neorecall_today_widget_compact else R.layout.neorecall_today_widget,
    )
    views.surface(theme)

    val today = snapshot.today
    val metric = metric(choice, today)
    // "Commitments open" is a running total rather than a count of today, so it
    // stays true across a day boundary where the other three do not.
    val current = snapshot.coversToday(System.currentTimeMillis()) || choice == "open"
    views.setTextViewText(R.id.widget_value, if (current) metric.value else "—")
    views.setTextColor(R.id.widget_value, theme.textPrimary)
    views.setTextViewText(R.id.widget_unit, if (current) metric.unit else "")
    views.setTextColor(R.id.widget_unit, theme.accent)
    views.setTextViewText(
      R.id.widget_label,
      when {
        current -> metric.label
        snapshot.usable -> context.getString(R.string.widget_stale_label)
        else ->
          context.getString(R.string.widget_waiting_title).uppercase(java.util.Locale.getDefault())
      },
    )
    views.setTextColor(R.id.widget_label, theme.textMuted)

    val trend = trend(choice, today, metric.series)
    views.textOrHide(R.id.widget_trend, if (current) trend?.first else null)
    if (trend != null) {
      val danger = trend.second
      views.setTextColor(R.id.widget_trend, if (danger) theme.danger else theme.accentAlt)
      views.background(R.id.widget_trend, if (danger) theme.chipDanger else theme.chipAlt)
    }

    views.week(theme, metric.series, metric.labels, metric.todayIndex)
    views.show(R.id.widget_week, current && metric.series.isNotEmpty())

    val stats = if (current) stats(choice, today, snapshot, theme) else emptyList()
    views.show(R.id.widget_stats, !compact && stats.isNotEmpty())
    STAT_SLOTS.forEachIndexed { index, slot ->
      val stat = stats.getOrNull(index)
      views.show(slot.container, stat != null)
      if (stat == null) return@forEachIndexed
      views.setTextViewText(slot.value, stat.value)
      views.setTextColor(slot.value, stat.color ?: theme.textPrimary)
      views.setTextViewText(slot.label, stat.label)
      views.setTextColor(slot.label, theme.textMuted)
      views.setOnClickPendingIntent(
        slot.container,
        WidgetIntents.open(context, appWidgetId, pageFor(stat.id), statSlot = index + 1),
      )
    }

    val review = snapshot.dayInReview?.takeIf { !compact && current }
    views.textOrHide(R.id.widget_review, review)
    views.setTextColor(R.id.widget_review, theme.textSecondary)

    views.setOnClickPendingIntent(
      R.id.widget_root,
      WidgetIntents.open(context, appWidgetId, metric.page),
    )
    views.show(R.id.widget_configure, !compact)
    views.setOnClickPendingIntent(
      R.id.widget_configure,
      WidgetIntents.configure(context, appWidgetId),
    )
    views.setContentDescription(
      R.id.widget_root,
      "${metric.value} ${metric.unit} ${metric.label.lowercase(java.util.Locale.getDefault())}",
    )
    return views
  }

  private fun metric(choice: String, today: WidgetSnapshot.Today): Metric = when (choice) {
    "memories" -> Metric(
      value = today.memories.toString(),
      unit = if (today.memories == 1) "memory" else "memories",
      label = "WRITTEN TODAY · LAST 7 DAYS",
      series = today.days.map(WidgetSnapshot.Day::memories),
      labels = today.days.map(WidgetSnapshot.Day::label),
      todayIndex = today.days.indexOfFirst(WidgetSnapshot.Day::today),
      page = WidgetIntents.PAGE_MEMORIES,
    )
    "highlights" -> Metric(
      value = today.highlights.toString(),
      unit = if (today.highlights == 1) "highlight" else "highlights",
      label = "FOUND TODAY · LAST 7 DAYS",
      series = today.days.map(WidgetSnapshot.Day::highlights),
      labels = today.days.map(WidgetSnapshot.Day::label),
      todayIndex = today.days.indexOfFirst(WidgetSnapshot.Day::today),
      page = WidgetIntents.PAGE_MEMORIES,
    )
    // The only metric that looks forwards: a bare count of what is open says
    // nothing about whether the week is manageable, and the due dates do.
    "open" -> Metric(
      value = today.openTasks.toString(),
      unit = "open",
      label = "COMMITMENTS · DUE THIS WEEK",
      series = today.dueDays.map(WidgetSnapshot.Day::due),
      labels = today.dueDays.map(WidgetSnapshot.Day::label),
      todayIndex = today.dueDays.indexOfFirst(WidgetSnapshot.Day::today),
      page = WidgetIntents.PAGE_HIGHLIGHTS,
    )
    else -> {
      val measure = WidgetFormat.talkTime(today.talkSeconds)
      Metric(
        value = measure.value,
        unit = measure.unit,
        label = "CAPTURED TODAY · LAST 7 DAYS",
        series = today.days.map(WidgetSnapshot.Day::talkSeconds),
        labels = today.days.map(WidgetSnapshot.Day::label),
        todayIndex = today.days.indexOfFirst(WidgetSnapshot.Day::today),
        page = WidgetIntents.PAGE_TIMELINE,
      )
    }
  }

  /**
   * Today against the six days before it. Percentages are only honest once
   * there is something to compare with, so a first week says nothing at all.
   */
  private fun trend(
    choice: String,
    today: WidgetSnapshot.Today,
    series: List<Int>,
  ): Pair<String, Boolean>? {
    if (choice == "open") {
      return if (today.overdue > 0) "${today.overdue} LATE" to true else null
    }
    if (series.size < 3) return null
    val current = series.last()
    val previous = series.dropLast(1)
    val average = previous.sum().toDouble() / previous.size
    if (average <= 0.0 || previous.count { it > 0 } < 2) return null
    val change = ((current - average) / average * 100).toInt()
    return when {
      change >= 10 -> "+$change%" to false
      change <= -10 -> "$change%" to false
      else -> "STEADY" to false
    }
  }

  private fun stats(
    choice: String,
    today: WidgetSnapshot.Today,
    snapshot: WidgetSnapshot,
    theme: WidgetTheme,
  ): List<Stat> {
    val talk = WidgetFormat.talkTime(today.talkSeconds)
    val all = listOf(
      Stat("talk", "${talk.value}${talk.unit}", "CAPTURED", null),
      Stat("memories", today.memories.toString(), "MEMORIES", null),
      Stat("highlights", today.highlights.toString(), "HIGHLIGHTS", null),
      Stat(
        "open",
        today.openTasks.toString(),
        if (today.dueToday > 0) "OPEN · ${today.dueToday} DUE" else "OPEN",
        if (today.overdue > 0) theme.danger else null,
      ),
    )
    val device = snapshot.device
    val withDevice = if (device != null && device.connected && device.batteryPercent != null) {
      all + Stat(
        "device",
        "${device.batteryPercent}%",
        device.label.uppercase(java.util.Locale.getDefault()).take(9),
        if (device.batteryPercent <= 15) theme.danger else theme.accentAlt,
      )
    } else {
      all
    }
    return withDevice.filter { it.id != choice }.take(3)
  }

  private fun pageFor(id: String) = when (id) {
    "memories" -> WidgetIntents.PAGE_MEMORIES
    "highlights", "open" -> WidgetIntents.PAGE_HIGHLIGHTS
    else -> WidgetIntents.PAGE_TIMELINE
  }

  private data class Slot(val container: Int, val value: Int, val label: Int)

  private val STAT_SLOTS = listOf(
    Slot(R.id.widget_stat_1, R.id.widget_stat_1_value, R.id.widget_stat_1_label),
    Slot(R.id.widget_stat_2, R.id.widget_stat_2_value, R.id.widget_stat_2_label),
    Slot(R.id.widget_stat_3, R.id.widget_stat_3_value, R.id.widget_stat_3_label),
  )
}
