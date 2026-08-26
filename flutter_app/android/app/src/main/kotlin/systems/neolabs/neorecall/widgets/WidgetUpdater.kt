package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context

/**
 * Redraws placed widgets.
 *
 * Called whenever the published snapshot changes, a widget's own settings
 * change, or the system's night mode flips. Kinds with no widget placed cost
 * one id lookup and nothing else.
 */
object WidgetUpdater {
  @JvmStatic
  fun refreshAll(context: Context) {
    val application = context.applicationContext
    val manager = AppWidgetManager.getInstance(application)
    WidgetKind.entries.forEach { kind -> refresh(application, manager, kind) }
  }

  internal fun refresh(context: Context, kind: WidgetKind) =
    refresh(context.applicationContext, AppWidgetManager.getInstance(context), kind)

  private fun refresh(context: Context, manager: AppWidgetManager, kind: WidgetKind) {
    val ids = try {
      kind.ids(context)
    } catch (_: Exception) {
      // A launcher that is mid-restore can refuse the lookup. Nothing here is
      // worth taking the app's process down for.
      return
    }
    if (ids.isEmpty()) return
    ids.forEach { appWidgetId ->
      try {
        manager.updateAppWidget(appWidgetId, kind.renderer.render(context, manager, appWidgetId))
      } catch (_: Exception) {
        // One widget failing to render must not stop the others.
      }
    }
    kind.renderer.collectionViewId?.let { viewId ->
      manager.notifyAppWidgetViewDataChanged(ids, viewId)
    }
  }
}
