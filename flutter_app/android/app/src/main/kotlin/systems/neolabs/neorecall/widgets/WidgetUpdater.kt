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
    refresh(context, manager, kind, ids)
  }

  /** Shared, failure-isolated path for app- and launcher-triggered updates. */
  internal fun refresh(
    context: Context,
    manager: AppWidgetManager,
    kind: WidgetKind,
    ids: IntArray,
  ) {
    if (ids.isEmpty()) return
    val renderer = try {
      kind.renderer
    } catch (_: Throwable) {
      return
    }
    ids.forEach { appWidgetId ->
      try {
        manager.updateAppWidget(appWidgetId, renderer.render(context, manager, appWidgetId))
      } catch (_: Throwable) {
        // Widget rendering is auxiliary. Even a class-initialization failure
        // must not terminate capture, upload, or the main application process.
      }
    }
    try {
      renderer.collectionViewId?.let { viewId ->
        manager.notifyAppWidgetViewDataChanged(ids, viewId)
      }
    } catch (_: Throwable) {
      // A broken collection renderer must not take down unrelated widgets.
    }
  }
}
