package systems.neolabs.neorecall.widgets

/**
 * The receivers Android places on the home screen. Each is a thin shell; the
 * drawing lives in the renderer its [WidgetKind] names.
 */
class StatusWidgetProvider : NeoRecallAppWidget() {
  override val kind: WidgetKind get() = WidgetKind.STATUS
}

class HighlightsWidgetProvider : NeoRecallAppWidget() {
  override val kind: WidgetKind get() = WidgetKind.HIGHLIGHTS
}

class MemoriesWidgetProvider : NeoRecallAppWidget() {
  override val kind: WidgetKind get() = WidgetKind.MEMORIES
}

class TodayWidgetProvider : NeoRecallAppWidget() {
  override val kind: WidgetKind get() = WidgetKind.TODAY
}
