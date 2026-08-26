package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.os.Bundle
import android.os.SystemClock
import android.widget.RemoteViews
import systems.neolabs.neorecall.BackgroundCaptureChannel
import systems.neolabs.neorecall.BackgroundCaptureService
import systems.neolabs.neorecall.R
import systems.neolabs.neorecall.widgets.WidgetRender.background
import systems.neolabs.neorecall.widgets.WidgetRender.meter
import systems.neolabs.neorecall.widgets.WidgetRender.show
import systems.neolabs.neorecall.widgets.WidgetRender.surface
import systems.neolabs.neorecall.widgets.WidgetRender.textOrHide
import systems.neolabs.neorecall.widgets.WidgetRender.tint

/**
 * The recorder: one button that starts capture and, once capture is running,
 * stops it — with the elapsed time ticking underneath it.
 *
 * Recording state comes from the foreground host rather than the published
 * snapshot, so the widget is right about what it controls even before the app
 * has published anything.
 */
internal object RecordWidgetRenderer : WidgetRenderer {
  // Android reports widget bounds in dp. Keeping the breakpoints in one place
  // means every launcher resize follows the same layout policy.
  private const val ICON_MAX_WIDTH_DP = 109
  private const val COMPACT_MAX_WIDTH_DP = 219
  private const val COMPACT_MAX_HEIGHT_DP = 95

  private enum class LayoutMode { ICON, COMPACT, FULL }

  override fun render(
    context: Context,
    manager: AppWidgetManager,
    appWidgetId: Int,
  ): RemoteViews {
    val options = try {
      manager.getAppWidgetOptions(appWidgetId)
    } catch (_: Exception) {
      null
    }
    val mode = layoutMode(options)
    val theme = WidgetKind.RECORD.theme(context, appWidgetId)
    val tap = WidgetKind.RECORD.option(context, appWidgetId, WidgetOptionKeys.TAP)
    val snapshot = WidgetStore.snapshot(context)
    val now = System.currentTimeMillis()

    val recording = BackgroundCaptureService.activeHolds(context)
      .contains(BackgroundCaptureService.HOLD_MICROPHONE) || snapshot.capture.recording
    val starting = !recording &&
      BackgroundCaptureChannel.isWidgetPhoneRecordingPending(context)

    val views = RemoteViews(
      context.packageName,
      when (mode) {
        LayoutMode.ICON -> R.layout.neorecall_record_widget_icon
        LayoutMode.COMPACT -> R.layout.neorecall_record_widget_compact
        LayoutMode.FULL -> R.layout.neorecall_record_widget
      },
    )
    views.surface(theme)

    val statusText: Int
    val statusColor: Int
    when {
      recording -> {
        statusText = R.string.widget_status_live
        statusColor = theme.danger
      }
      starting -> {
        statusText = R.string.widget_status_starting
        statusColor = theme.accent
      }
      else -> {
        statusText = R.string.widget_status_ready
        statusColor = theme.textMuted
      }
    }
    views.setTextViewText(R.id.widget_status, context.getString(statusText))
    views.setTextColor(R.id.widget_status, statusColor)
    views.setTextColor(R.id.widget_live_dot, theme.danger)
    views.show(R.id.widget_live_dot, recording || starting)

    val compactTitles = mode != LayoutMode.FULL
    val title = when {
      recording -> snapshot.capture.title.takeIf { it.isNotBlank() && !compactTitles }
        ?: context.getString(
          if (compactTitles) R.string.widget_compact_title_recording
          else R.string.widget_title_recording,
        )
      starting -> context.getString(
        if (compactTitles) R.string.widget_compact_title_starting
        else R.string.widget_title_starting,
      )
      else -> context.getString(
        if (compactTitles) R.string.widget_compact_title_ready else R.string.widget_title_ready,
      )
    }
    views.setTextViewText(R.id.widget_title, title)
    views.setTextColor(R.id.widget_title, theme.textPrimary)

    // The elapsed time is a Chronometer, so it keeps counting between updates
    // instead of freezing at whatever second the last redraw happened to catch.
    val startedAt = snapshot.capture.startedAtMillis
    val showElapsed = recording && startedAt != null && startedAt > 0L
    if (showElapsed) {
      views.setChronometer(
        R.id.widget_elapsed,
        SystemClock.elapsedRealtime() - (now - startedAt!!).coerceAtLeast(0L),
        null,
        true,
      )
      views.setTextColor(R.id.widget_elapsed, theme.accent)
    } else {
      views.setChronometer(R.id.widget_elapsed, SystemClock.elapsedRealtime(), null, false)
    }
    views.show(R.id.widget_elapsed, showElapsed)

    val subtitle = when {
      recording && tap == "smart" -> context.getString(R.string.widget_subtitle_recording)
      recording -> snapshot.capture.detail.ifBlank {
        context.getString(R.string.widget_subtitle_recording_open)
      }
      starting -> context.getString(R.string.widget_subtitle_starting)
      snapshot.usable && snapshot.capture.detail.isNotBlank() && !snapshot.capture.recording &&
        snapshot.capture.phase != "idle" -> snapshot.capture.detail
      else -> context.getString(R.string.widget_subtitle_ready)
    }
    views.setTextViewText(R.id.widget_subtitle, subtitle)
    views.setTextColor(R.id.widget_subtitle, theme.textSecondary)
    views.show(R.id.widget_subtitle, mode == LayoutMode.FULL)

    // The right-hand slot only ever carries a fact: what is queued, or how long
    // the pipeline still needs. It stays empty rather than repeating the state.
    val meta = meta(snapshot)
    views.textOrHide(R.id.widget_meta, meta)
    views.setTextColor(R.id.widget_meta, theme.textMuted)

    val progress = snapshot.capture.progress
    val showMeter = mode == LayoutMode.FULL && snapshot.usable &&
      (progress != null || snapshot.capture.pendingSeconds > 0)
    if (showMeter) views.meter(theme, progress, alert = snapshot.capture.issue != null)
    views.show(R.id.widget_meter, showMeter)

    val stopping = recording && tap == "smart"
    views.setImageViewResource(
      R.id.widget_action,
      when {
        stopping -> R.drawable.ic_widget_stop
        recording || starting -> R.drawable.ic_widget_wave
        else -> R.drawable.ic_widget_mic
      },
    )
    views.background(
      R.id.widget_action,
      if (recording || starting) theme.actionRecording else theme.actionReady,
    )
    views.tint(R.id.widget_action, theme.onAccent)
    views.setContentDescription(
      R.id.widget_action,
      context.getString(
        if (stopping) R.string.widget_action_stop_description
        else R.string.widget_action_description,
      ),
    )

    val openApp = WidgetIntents.open(context, appWidgetId, WidgetIntents.PAGE_RECORD)
    views.setOnClickPendingIntent(R.id.widget_root, openApp)
    views.setOnClickPendingIntent(
      R.id.widget_action,
      when {
        tap == "open" -> openApp
        stopping -> WidgetIntents.stopRecording(context, appWidgetId)
        else -> WidgetIntents.startRecording(context, appWidgetId)
      },
    )
    views.show(R.id.widget_configure, mode == LayoutMode.FULL)
    views.setOnClickPendingIntent(
      R.id.widget_configure,
      WidgetIntents.configure(context, appWidgetId),
    )
    views.setContentDescription(
      R.id.widget_root,
      context.getString(
        if (recording) R.string.widget_description_recording
        else R.string.widget_description_ready,
      ),
    )
    return views
  }

  private fun meta(snapshot: WidgetSnapshot): String? {
    if (!snapshot.usable) return null
    val capture = snapshot.capture
    return when {
      capture.pendingSeconds > 0 -> "${WidgetFormat.duration(capture.pendingSeconds)} queued"
      capture.pendingBytes > 0L -> "${WidgetFormat.bytes(capture.pendingBytes)} queued"
      capture.etaSeconds != null && capture.etaSeconds > 0 ->
        "~${WidgetFormat.duration(capture.etaSeconds)} left"
      snapshot.today.openTasks > 0 -> "${snapshot.today.openTasks} open"
      else -> null
    }
  }

  private fun layoutMode(options: Bundle?): LayoutMode {
    if (options == null || !options.containsKey(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)) {
      return LayoutMode.FULL
    }
    val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH)
    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT)
    return when {
      width <= ICON_MAX_WIDTH_DP -> LayoutMode.ICON
      width <= COMPACT_MAX_WIDTH_DP || height <= COMPACT_MAX_HEIGHT_DP -> LayoutMode.COMPACT
      else -> LayoutMode.FULL
    }
  }
}
