package systems.neolabs.neorecall

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews

/** Premium home-screen entry point for persistent phone-microphone capture. */
class RecordWidgetProvider : AppWidgetProvider() {
  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray,
  ) {
    appWidgetIds.forEach { appWidgetId ->
      update(context, appWidgetManager, appWidgetId)
    }
  }

  override fun onAppWidgetOptionsChanged(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetId: Int,
    newOptions: Bundle,
  ) {
    super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
    appWidgetManager.updateAppWidget(appWidgetId, views(context, newOptions))
  }

  companion object {
    // Android reports widget bounds in dp. Keep the breakpoints in one place so
    // every launcher resize follows the same layout policy.
    private const val ICON_MAX_WIDTH_DP = 109
    private const val COMPACT_MAX_WIDTH_DP = 219
    private const val COMPACT_MAX_HEIGHT_DP = 95

    private enum class LayoutMode {
      ICON,
      COMPACT,
      FULL,
    }

    fun updateAll(context: Context) {
      val manager = AppWidgetManager.getInstance(context)
      val component = ComponentName(context, RecordWidgetProvider::class.java)
      val ids = manager.getAppWidgetIds(component)
      ids.forEach { id -> update(context, manager, id) }
    }

    private fun update(
      context: Context,
      manager: AppWidgetManager,
      appWidgetId: Int,
    ) {
      manager.updateAppWidget(
        appWidgetId,
        views(context, manager.getAppWidgetOptions(appWidgetId)),
      )
    }

    private fun views(context: Context, options: Bundle?): RemoteViews {
      val recording = BackgroundCaptureService.activeHolds(context)
        .contains(BackgroundCaptureService.HOLD_MICROPHONE)
      val pending = BackgroundCaptureChannel
        .isWidgetPhoneRecordingPending(context) && !recording
      val layoutMode = layoutMode(options)
      val layout = when (layoutMode) {
        LayoutMode.ICON -> R.layout.neorecall_record_widget_icon
        LayoutMode.COMPACT -> R.layout.neorecall_record_widget_compact
        LayoutMode.FULL -> R.layout.neorecall_record_widget
      }
      val views = RemoteViews(context.packageName, layout)

      when {
        recording -> {
          views.setTextViewText(R.id.widget_status, context.getString(R.string.widget_status_live))
          views.setTextViewText(
            R.id.widget_title,
            context.getString(
              if (layoutMode == LayoutMode.FULL) R.string.widget_title_recording
              else R.string.widget_compact_title_recording,
            ),
          )
          views.setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_subtitle_recording))
          views.setViewVisibility(R.id.widget_live_dot, View.VISIBLE)
          views.setImageViewResource(R.id.widget_action, R.drawable.ic_widget_wave)
          views.setInt(
            R.id.widget_action,
            "setBackgroundResource",
            R.drawable.widget_action_recording,
          )
        }
        pending -> {
          views.setTextViewText(R.id.widget_status, context.getString(R.string.widget_status_starting))
          views.setTextViewText(
            R.id.widget_title,
            context.getString(
              if (layoutMode == LayoutMode.FULL) R.string.widget_title_starting
              else R.string.widget_compact_title_starting,
            ),
          )
          views.setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_subtitle_starting))
          views.setViewVisibility(R.id.widget_live_dot, View.VISIBLE)
          views.setImageViewResource(R.id.widget_action, R.drawable.ic_widget_wave)
          views.setInt(
            R.id.widget_action,
            "setBackgroundResource",
            R.drawable.widget_action_recording,
          )
        }
        else -> {
          views.setTextViewText(R.id.widget_status, context.getString(R.string.widget_status_ready))
          views.setTextViewText(
            R.id.widget_title,
            context.getString(
              if (layoutMode == LayoutMode.FULL) R.string.widget_title_ready
              else R.string.widget_compact_title_ready,
            ),
          )
          views.setTextViewText(R.id.widget_subtitle, context.getString(R.string.widget_subtitle_ready))
          views.setViewVisibility(R.id.widget_live_dot, View.GONE)
          views.setImageViewResource(R.id.widget_action, R.drawable.ic_widget_mic)
          views.setInt(
            R.id.widget_action,
            "setBackgroundResource",
            R.drawable.widget_action_ready,
          )
        }
      }

      val launch = Intent(context, MainActivity::class.java).apply {
        action = MainActivity.ACTION_START_PHONE_RECORDING
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
          Intent.FLAG_ACTIVITY_CLEAR_TOP or
          Intent.FLAG_ACTIVITY_SINGLE_TOP
      }
      val tap = PendingIntent.getActivity(
        context,
        41001,
        launch,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
      views.setOnClickPendingIntent(R.id.widget_root, tap)
      views.setOnClickPendingIntent(R.id.widget_action, tap)
      views.setContentDescription(
        R.id.widget_root,
        context.getString(
          if (recording) R.string.widget_description_recording
          else R.string.widget_description_ready,
        ),
      )
      return views
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
}
