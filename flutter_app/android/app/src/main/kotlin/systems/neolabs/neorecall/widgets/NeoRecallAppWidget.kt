package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.widget.RemoteViews

/** Builds the RemoteViews for one placed widget. Stateless and shared. */
internal interface WidgetRenderer {
  fun render(context: Context, manager: AppWidgetManager, appWidgetId: Int): RemoteViews

  /**
   * The collection view a launcher must be told to re-read, for widgets that
   * have one. Updating a ListView's RemoteViews does not refetch its rows.
   */
  val collectionViewId: Int? get() = null
}

/**
 * Shared behaviour for every NeoRecall home-screen widget: render on update,
 * re-render on resize, and drop the widget's settings when it is removed —
 * which Android does not do for us.
 */
abstract class NeoRecallAppWidget : AppWidgetProvider() {
  internal abstract val kind: WidgetKind

  override fun onUpdate(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetIds: IntArray,
  ) {
    appWidgetIds.forEach { appWidgetId ->
      appWidgetManager.updateAppWidget(
        appWidgetId,
        kind.renderer.render(context, appWidgetManager, appWidgetId),
      )
    }
    kind.renderer.collectionViewId?.let { viewId ->
      appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetIds, viewId)
    }
  }

  override fun onAppWidgetOptionsChanged(
    context: Context,
    appWidgetManager: AppWidgetManager,
    appWidgetId: Int,
    newOptions: Bundle,
  ) {
    super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
    appWidgetManager.updateAppWidget(
      appWidgetId,
      kind.renderer.render(context, appWidgetManager, appWidgetId),
    )
  }

  override fun onDeleted(context: Context, appWidgetIds: IntArray) {
    super.onDeleted(context, appWidgetIds)
    WidgetStore.forget(context, appWidgetIds)
  }
}
