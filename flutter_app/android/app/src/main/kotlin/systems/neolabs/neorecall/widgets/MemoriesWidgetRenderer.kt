package systems.neolabs.neorecall.widgets

import android.content.Context
import systems.neolabs.neorecall.R

/** What the conversations turned into, newest first. */
internal object MemoriesWidgetRenderer : ListWidgetRenderer(
  kind = WidgetKind.MEMORIES,
  serviceClass = MemoriesWidgetService::class.java,
  headerIcon = R.drawable.ic_widget_sparkle,
  emptyIcon = R.drawable.ic_widget_sparkle,
) {
  override fun heading(context: Context, filter: String) = when (filter) {
    WidgetFilters.MEMORIES_PINNED -> "Pinned"
    WidgetFilters.MEMORIES_MEETING -> "Meetings"
    WidgetFilters.MEMORIES_DECISION -> "Decisions"
    else -> "Memories"
  }

  override fun emptyText(context: Context, filter: String) =
    context.getString(R.string.widget_empty_memories)

  override fun count(snapshot: WidgetSnapshot, context: Context, filter: String) =
    WidgetFilters.memories(snapshot, filter).size

  override fun meta(snapshot: WidgetSnapshot, context: Context, filter: String): String? {
    val newest = WidgetFilters.memories(snapshot, filter).firstOrNull() ?: return null
    val relative = WidgetFormat.relativeTime(newest.atMillis, System.currentTimeMillis())
    return relative.ifEmpty { null }?.uppercase(java.util.Locale.getDefault())
  }

  override fun page() = WidgetIntents.PAGE_MEMORIES
}
