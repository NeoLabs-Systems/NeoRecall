package systems.neolabs.neorecall.widgets

/**
 * The one place a widget filter is interpreted.
 *
 * The renderer counts with it and the row factory lists with it, and a header
 * saying "7" above five rows would be a worse bug than a wrong filter.
 */
internal object WidgetFilters {
  const val HIGHLIGHTS_OPEN = "open"
  const val HIGHLIGHTS_TODAY = "today"
  const val HIGHLIGHTS_OVERDUE = "overdue"
  const val HIGHLIGHTS_PROMISES = "promises"

  const val MEMORIES_RECENT = "recent"
  const val MEMORIES_PINNED = "pinned"
  const val MEMORIES_MEETING = "meeting"
  const val MEMORIES_DECISION = "decision"

  private val MEETING_TYPES = setOf("meeting", "project_discussion", "introduction")
  private val DECISION_TYPES = setOf("decision", "lesson", "experience")

  fun highlights(
    snapshot: WidgetSnapshot,
    filter: String,
    completedLocally: Set<String>,
  ): List<WidgetSnapshot.Highlight> = snapshot.highlights
    .asSequence()
    .filter { !completedLocally.contains(it.id) }
    .filter { highlight ->
      when (filter) {
        HIGHLIGHTS_TODAY -> highlight.dueToday || highlight.overdue
        HIGHLIGHTS_OVERDUE -> highlight.overdue
        HIGHLIGHTS_PROMISES -> highlight.kind == "promise"
        else -> true
      }
    }
    .toList()

  fun memories(snapshot: WidgetSnapshot, filter: String): List<WidgetSnapshot.Memory> =
    snapshot.memories.filter { memory ->
      when (filter) {
        MEMORIES_PINNED -> memory.pinned
        MEMORIES_MEETING -> MEETING_TYPES.contains(memory.type)
        MEMORIES_DECISION -> DECISION_TYPES.contains(memory.type)
        else -> true
      }
    }
}
