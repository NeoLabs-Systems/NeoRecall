package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import systems.neolabs.neorecall.R

/** Serves the rows of the commitments widget to the launcher. */
class HighlightsWidgetService : RemoteViewsService() {
  override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
    HighlightsRowFactory(
      applicationContext,
      intent.getIntExtra(
        AppWidgetManager.EXTRA_APPWIDGET_ID,
        AppWidgetManager.INVALID_APPWIDGET_ID,
      ),
    )
}

internal class HighlightsRowFactory(
  private val context: Context,
  private val appWidgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
  private var rows: List<WidgetSnapshot.Highlight> = emptyList()
  private var theme: WidgetTheme = WidgetTheme.of(context, WidgetTheme.AUTO)
  private var showSource = true
  private var now = System.currentTimeMillis()

  override fun onCreate() = Unit

  /**
   * Called by the launcher before every redraw, on a background thread. Reading
   * configuration here rather than from the adapter intent is what lets a
   * settings change take effect without replacing the widget.
   */
  override fun onDataSetChanged() {
    val kind = WidgetKind.HIGHLIGHTS
    val snapshot = WidgetStore.snapshot(context)
    theme = kind.theme(context, appWidgetId)
    showSource = kind.option(context, appWidgetId, WidgetOptionKeys.SOURCE) != "hide"
    now = System.currentTimeMillis()
    rows = if (snapshot.usable) {
      WidgetFilters.highlights(
        snapshot,
        kind.option(context, appWidgetId, WidgetOptionKeys.FILTER),
        WidgetStore.completedLocally(context),
      )
    } else {
      emptyList()
    }
  }

  override fun onDestroy() {
    rows = emptyList()
  }

  override fun getCount() = rows.size

  override fun getViewAt(position: Int): RemoteViews {
    val row = rows.getOrNull(position) ?: return loadingView()
    val views = RemoteViews(context.packageName, R.layout.neorecall_widget_highlight_row)
    views.setInt(R.id.row_root, "setBackgroundResource", theme.row)
    views.setTextViewText(R.id.row_text, row.text)
    views.setTextColor(R.id.row_text, theme.textPrimary)

    views.setInt(R.id.row_tick, "setBackgroundResource", theme.actionGhost)
    views.setInt(R.id.row_tick, "setColorFilter", if (row.overdue) theme.danger else theme.accent)

    val due = WidgetFormat.dueLabel(row.dueMillis, row.overdue, now)
    views.setViewVisibility(R.id.row_due, if (due == null) View.GONE else View.VISIBLE)
    if (due != null) {
      views.setTextViewText(R.id.row_due, due)
      views.setTextColor(R.id.row_due, if (row.overdue) theme.danger else theme.accent)
      views.setInt(
        R.id.row_due,
        "setBackgroundResource",
        if (row.overdue) theme.chipDanger else theme.chipAccent,
      )
    }

    val source = row.memoryTitle?.takeIf { showSource && it.isNotBlank() }
    views.setViewVisibility(R.id.row_source, if (source == null) View.GONE else View.VISIBLE)
    if (source != null) {
      views.setTextViewText(R.id.row_source, "${row.emoji}  $source")
      views.setTextColor(R.id.row_source, theme.textMuted)
    }
    views.setViewVisibility(
      R.id.row_meta,
      if (due == null && source == null) View.GONE else View.VISIBLE,
    )

    views.setOnClickFillInIntent(
      R.id.row_root,
      WidgetIntents.openFill(WidgetIntents.PAGE_HIGHLIGHTS, row.id),
    )
    views.setOnClickFillInIntent(R.id.row_tick, WidgetIntents.completeFill(row.id))
    views.setContentDescription(R.id.row_root, row.text)
    return views
  }

  private fun loadingView() =
    RemoteViews(context.packageName, R.layout.neorecall_widget_highlight_row)

  override fun getLoadingView(): RemoteViews? = null

  override fun getViewTypeCount() = 1

  override fun getItemId(position: Int) = rows.getOrNull(position)?.id?.hashCode()?.toLong()
    ?: position.toLong()

  override fun hasStableIds() = true
}
