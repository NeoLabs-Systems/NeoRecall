package systems.neolabs.neorecall

import android.content.Context
import systems.neolabs.neorecall.widgets.NeoRecallAppWidget
import systems.neolabs.neorecall.widgets.WidgetKind
import systems.neolabs.neorecall.widgets.WidgetUpdater

/**
 * Home-screen entry point for persistent phone-microphone capture.
 *
 * Kept in the application package on purpose: the receiver's component name is
 * part of every already-placed widget, and moving the class would leave those
 * home screens with a hole.
 */
class RecordWidgetProvider : NeoRecallAppWidget() {
  override val kind: WidgetKind get() = WidgetKind.RECORD

  companion object {
    /** Redraws every NeoRecall widget, not only the recorder. */
    @JvmStatic
    fun updateAll(context: Context) = WidgetUpdater.refreshAll(context)
  }
}
