package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.widget.RemoteViews
import systems.neolabs.neorecall.R
import systems.neolabs.neorecall.widgets.WidgetRender.background
import systems.neolabs.neorecall.widgets.WidgetRender.meter
import systems.neolabs.neorecall.widgets.WidgetRender.show
import systems.neolabs.neorecall.widgets.WidgetRender.surface
import systems.neolabs.neorecall.widgets.WidgetRender.tint

/**
 * What capture and processing are doing right now.
 *
 * Every line is the same text the ongoing notification shows, so the two
 * surfaces can never contradict each other, and the three figures underneath
 * are chosen from whatever is actually true at the time rather than reserved
 * for metrics that may be zero.
 */
internal object StatusWidgetRenderer : WidgetRenderer {
  private const val COMPACT_MAX_HEIGHT_DP = 110

  private data class Stat(val value: String, val label: String, val color: Int?)

  override fun render(
    context: Context,
    manager: AppWidgetManager,
    appWidgetId: Int,
  ): RemoteViews {
    val theme = WidgetKind.STATUS.theme(context, appWidgetId)
    val snapshot = WidgetStore.snapshot(context)
    val now = System.currentTimeMillis()
    val height = try {
      manager.getAppWidgetOptions(appWidgetId)
        .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
    } catch (_: Exception) {
      0
    }
    val compact = height in 1 until COMPACT_MAX_HEIGHT_DP
    val views = RemoteViews(
      context.packageName,
      if (compact) R.layout.neorecall_status_widget_compact
      else R.layout.neorecall_status_widget,
    )
    views.surface(theme)

    val capture = snapshot.capture
    val accent = phaseColor(theme, capture.phase)
    views.setImageViewResource(R.id.widget_phase_icon, phaseIcon(capture.phase))
    views.tint(R.id.widget_phase_icon, accent)
    views.background(R.id.widget_phase_icon, theme.actionSoft)

    val title = when {
      !snapshot.present -> context.getString(R.string.widget_waiting_title)
      !snapshot.signedIn -> context.getString(R.string.widget_signed_out_title)
      else -> capture.title.ifBlank { context.getString(R.string.widget_status_ready) }
    }
    val detail = when {
      !snapshot.present -> context.getString(R.string.widget_waiting_detail)
      !snapshot.signedIn -> context.getString(R.string.widget_signed_out_detail)
      else -> capture.detail
    }
    views.setTextViewText(R.id.widget_title, title)
    views.setTextColor(R.id.widget_title, theme.textPrimary)
    views.setTextViewText(R.id.widget_subtitle, detail)
    views.setTextColor(R.id.widget_subtitle, theme.textSecondary)

    val active = capture.recording || ACTIVE_PHASES.contains(capture.phase)
    val fraction = when {
      capture.recording -> 1.0
      !snapshot.usable -> 0.0
      capture.progress != null -> capture.progress
      active -> null
      else -> 0.0
    }
    views.meter(theme, fraction, alert = capture.issue != null || capture.phase == "storageFull")
    views.show(R.id.widget_meter, snapshot.usable || !snapshot.present)

    val stats = stats(context, snapshot, theme, now)
    views.show(R.id.widget_stats, !compact && stats.isNotEmpty())
    STAT_SLOTS.forEachIndexed { index, slot ->
      val stat = stats.getOrNull(index)
      views.show(slot.container, stat != null)
      if (stat == null) return@forEachIndexed
      views.setTextViewText(slot.value, stat.value)
      views.setTextColor(slot.value, stat.color ?: theme.textPrimary)
      views.setTextViewText(slot.label, stat.label)
      views.setTextColor(slot.label, theme.textMuted)
    }

    val issue = capture.issue
    views.show(R.id.widget_issue, !compact && issue != null)
    if (issue != null) {
      views.background(R.id.widget_issue, theme.chipDanger)
      views.setTextViewText(R.id.widget_issue_text, issue)
      views.setTextColor(R.id.widget_issue_text, theme.danger)
      views.tint(R.id.widget_issue_icon, theme.danger)
    }

    val page = if (WidgetKind.STATUS.option(context, appWidgetId, WidgetOptionKeys.TAP) == "timeline") {
      WidgetIntents.PAGE_TIMELINE
    } else {
      WidgetIntents.PAGE_RECORD
    }
    views.setOnClickPendingIntent(
      R.id.widget_root,
      WidgetIntents.open(context, appWidgetId, page),
    )
    views.show(R.id.widget_configure, !compact)
    views.setOnClickPendingIntent(
      R.id.widget_configure,
      WidgetIntents.configure(context, appWidgetId),
    )
    views.setContentDescription(R.id.widget_root, "$title. $detail")
    return views
  }

  /**
   * Three figures, chosen in the order they matter. A queue that is empty is
   * not worth a slot, so the widget shows what the day actually holds instead.
   */
  private fun stats(
    context: Context,
    snapshot: WidgetSnapshot,
    theme: WidgetTheme,
    nowMillis: Long,
  ): List<Stat> {
    if (!snapshot.usable) return emptyList()
    val capture = snapshot.capture
    val today = snapshot.today
    val candidates = ArrayList<Stat>(6)
    val startedAt = capture.startedAtMillis
    if (capture.recording && startedAt != null && startedAt > 0L) {
      candidates.add(
        Stat(
          WidgetFormat.duration(((nowMillis - startedAt) / 1000L).toInt()),
          "RECORDING",
          theme.danger,
        ),
      )
    }
    if (capture.pendingSeconds > 0) {
      candidates.add(Stat(WidgetFormat.duration(capture.pendingSeconds), "QUEUED", theme.accent))
    } else if (capture.pendingBytes > 0L) {
      candidates.add(Stat(WidgetFormat.bytes(capture.pendingBytes), "QUEUED", theme.accent))
    }
    val eta = capture.etaSeconds
    if (eta != null && eta > 0) {
      candidates.add(Stat(WidgetFormat.duration(eta), "LEFT", theme.info))
    }
    val device = snapshot.device
    if (device != null && device.connected && device.batteryPercent != null) {
      candidates.add(
        Stat(
          "${device.batteryPercent}%",
          device.label.uppercase(java.util.Locale.getDefault()).take(10),
          if (device.batteryPercent <= 15) theme.danger else theme.accentAlt,
        ),
      )
    }
    // Day counts are dropped rather than shown stale once the snapshot is from
    // a previous day; the open-commitment total is a running figure and is not.
    if (snapshot.coversToday(nowMillis)) {
      val talk = WidgetFormat.talkTime(today.talkSeconds)
      candidates.add(Stat("${talk.value}${talk.unit}", "TODAY", null))
      candidates.add(Stat(today.memories.toString(), "MEMORIES", null))
    }
    if (today.openTasks > 0) {
      candidates.add(
        Stat(
          today.openTasks.toString(),
          if (today.overdue > 0) "OPEN · ${today.overdue} LATE" else "OPEN",
          if (today.overdue > 0) theme.danger else null,
        ),
      )
    }
    return candidates.take(3)
  }

  private fun phaseIcon(phase: String) = when (phase) {
    "recording" -> R.drawable.ic_widget_wave
    "watchTransfer" -> R.drawable.ic_widget_bluetooth
    "uploading" -> R.drawable.ic_widget_upload
    "transcribing" -> R.drawable.ic_widget_transcript
    "finalizing" -> R.drawable.ic_widget_seal
    "storageFull" -> R.drawable.ic_widget_alert
    "connected" -> R.drawable.ic_widget_bluetooth
    "queued" -> R.drawable.ic_widget_clock
    else -> R.drawable.ic_widget_clock
  }

  private fun phaseColor(theme: WidgetTheme, phase: String) = when (phase) {
    "storageFull" -> theme.danger
    "recording" -> theme.danger
    "idle" -> theme.textMuted
    "connected" -> theme.accentAlt
    else -> theme.accent
  }

  private val ACTIVE_PHASES =
    setOf("watchTransfer", "uploading", "transcribing", "finalizing", "queued")

  private data class Slot(val container: Int, val value: Int, val label: Int)

  private val STAT_SLOTS = listOf(
    Slot(R.id.widget_stat_1, R.id.widget_stat_1_value, R.id.widget_stat_1_label),
    Slot(R.id.widget_stat_2, R.id.widget_stat_2_value, R.id.widget_stat_2_label),
    Slot(R.id.widget_stat_3, R.id.widget_stat_3_value, R.id.widget_stat_3_label),
  )
}
