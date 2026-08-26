package systems.neolabs.neorecall.widgets

import android.content.Context
import systems.neolabs.neorecall.R

/** Tasks and promises, tickable without leaving the home screen. */
internal object HighlightsWidgetRenderer : ListWidgetRenderer(
  kind = WidgetKind.HIGHLIGHTS,
  serviceClass = HighlightsWidgetService::class.java,
  headerIcon = R.drawable.ic_widget_check_circle,
  emptyIcon = R.drawable.ic_widget_check_circle,
) {
  override fun heading(context: Context, filter: String) = when (filter) {
    WidgetFilters.HIGHLIGHTS_TODAY -> "Due today"
    WidgetFilters.HIGHLIGHTS_OVERDUE -> "Overdue"
    WidgetFilters.HIGHLIGHTS_PROMISES -> "Promises"
    else -> "Open"
  }

  override fun emptyText(context: Context, filter: String) = when (filter) {
    WidgetFilters.HIGHLIGHTS_TODAY -> "Nothing is due today."
    WidgetFilters.HIGHLIGHTS_OVERDUE -> "Nothing is overdue."
    WidgetFilters.HIGHLIGHTS_PROMISES -> "No open promises."
    else -> context.getString(R.string.widget_empty_highlights)
  }

  override fun count(snapshot: WidgetSnapshot, context: Context, filter: String) =
    WidgetFilters.highlights(snapshot, filter, WidgetStore.completedLocally(context)).size

  override fun meta(snapshot: WidgetSnapshot, context: Context, filter: String): String? {
    val overdue = snapshot.today.overdue
    val dueToday = snapshot.today.dueToday
    return when {
      filter != WidgetFilters.HIGHLIGHTS_OVERDUE && overdue > 0 -> "$overdue LATE"
      filter == WidgetFilters.HIGHLIGHTS_OPEN && dueToday > 0 -> "$dueToday TODAY"
      else -> null
    }
  }

  override fun page() = WidgetIntents.PAGE_HIGHLIGHTS
}
