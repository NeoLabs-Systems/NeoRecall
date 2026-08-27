package systems.neolabs.neorecall.widgets

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class WidgetKindInitializationTest {
  @Test
  fun renderersResolveOnlyAfterEveryKindIsInitialized() {
    assertEquals(5, WidgetKind.entries.size)
    assertSame(RecordWidgetRenderer, WidgetKind.RECORD.renderer)
    assertSame(StatusWidgetRenderer, WidgetKind.STATUS.renderer)
    assertSame(HighlightsWidgetRenderer, WidgetKind.HIGHLIGHTS.renderer)
    assertSame(MemoriesWidgetRenderer, WidgetKind.MEMORIES.renderer)
    assertSame(TodayWidgetRenderer, WidgetKind.TODAY.renderer)
  }
}
