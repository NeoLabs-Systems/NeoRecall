package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import systems.neolabs.neorecall.R

/** Serves the rows of the memories widget to the launcher. */
class MemoriesWidgetService : RemoteViewsService() {
  override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
    MemoriesRowFactory(
      applicationContext,
      intent.getIntExtra(
        AppWidgetManager.EXTRA_APPWIDGET_ID,
        AppWidgetManager.INVALID_APPWIDGET_ID,
      ),
    )
}

internal class MemoriesRowFactory(
  private val context: Context,
  private val appWidgetId: Int,
) : RemoteViewsService.RemoteViewsFactory {
  private var rows: List<WidgetSnapshot.Memory> = emptyList()
  private var theme: WidgetTheme = WidgetTheme.of(context, WidgetTheme.AUTO)
  private var showSummary = true
  private var now = System.currentTimeMillis()

  override fun onCreate() = Unit

  override fun onDataSetChanged() {
    val kind = WidgetKind.MEMORIES
    val snapshot = WidgetStore.snapshot(context)
    theme = kind.theme(context, appWidgetId)
    showSummary = kind.option(context, appWidgetId, WidgetOptionKeys.SUMMARY) != "hide"
    now = System.currentTimeMillis()
    rows = if (snapshot.usable) {
      WidgetFilters.memories(snapshot, kind.option(context, appWidgetId, WidgetOptionKeys.FILTER))
    } else {
      emptyList()
    }
  }

  override fun onDestroy() {
    rows = emptyList()
  }

  override fun getCount() = rows.size

  override fun getViewAt(position: Int): RemoteViews {
    val row = rows.getOrNull(position)
      ?: return RemoteViews(context.packageName, R.layout.neorecall_widget_memory_row)
    val views = RemoteViews(context.packageName, R.layout.neorecall_widget_memory_row)
    views.setInt(R.id.row_root, "setBackgroundResource", theme.row)
    views.setTextViewText(R.id.row_emoji, row.emoji)
    views.setTextViewText(R.id.row_title, row.title)
    views.setTextColor(R.id.row_title, theme.textPrimary)
    views.setTextViewText(R.id.row_time, WidgetFormat.relativeTime(row.atMillis, now))
    views.setTextColor(R.id.row_time, theme.textMuted)

    val summary = row.summary.takeIf { showSummary && it.isNotBlank() }
    views.setViewVisibility(R.id.row_summary, if (summary == null) View.GONE else View.VISIBLE)
    if (summary != null) {
      views.setTextViewText(R.id.row_summary, summary)
      views.setTextColor(R.id.row_summary, theme.textSecondary)
    }

    // The chip carries whatever this memory has that the title does not: how
    // many highlights came out of it, or that it is pinned, or its kind.
    val chip = when {
      row.pinned -> "PINNED"
      row.highlightCount > 0 ->
        WidgetFormat.count(row.highlightCount, "HIGHLIGHT", "HIGHLIGHTS")
      else -> row.typeLabel.uppercase(java.util.Locale.getDefault())
    }
    views.setViewVisibility(R.id.row_chip, if (showSummary) View.VISIBLE else View.GONE)
    views.setTextViewText(R.id.row_chip, chip)
    views.setTextColor(R.id.row_chip, if (row.pinned) theme.accent else theme.accentAlt)
    views.setInt(
      R.id.row_chip,
      "setBackgroundResource",
      if (row.pinned) theme.chipAccent else theme.chipAlt,
    )

    views.setOnClickFillInIntent(
      R.id.row_root,
      WidgetIntents.openFill(WidgetIntents.PAGE_MEMORIES, row.id),
    )
    views.setContentDescription(R.id.row_root, "${row.title}. ${row.summary}")
    return views
  }

  override fun getLoadingView(): RemoteViews? = null

  override fun getViewTypeCount() = 1

  override fun getItemId(position: Int) = rows.getOrNull(position)?.id?.hashCode()?.toLong()
    ?: position.toLong()

  override fun hasStableIds() = true
}
