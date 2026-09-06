package systems.neolabs.neorecall.widgets

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import systems.neolabs.neorecall.MainActivity
import systems.neolabs.neorecall.NeoRecallApplication

/**
 * The landing point for widget taps, drawn as nothing at all.
 *
 * Two jobs. It gives taps that must not open the app — stopping capture,
 * ticking a commitment — an activity start the launcher is allowed to make,
 * instead of a broadcast that recent Android versions would refuse to let start
 * anything. And it gives collection rows one template component whose meaning
 * is filled in per row.
 *
 * The tap is written to [WidgetStore] before anything else happens, so the app
 * applies it whenever it next runs even if this process dies immediately after.
 */
class WidgetTapActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val now = System.currentTimeMillis()
    val tap = intent?.getStringExtra(WidgetIntents.EXTRA_TAP)
    val targetId = intent?.getStringExtra(WidgetIntents.EXTRA_TARGET_ID)
    val page = intent?.getStringExtra(WidgetIntents.EXTRA_PAGE) ?: WidgetIntents.PAGE_RECORD

    when (tap) {
      WidgetIntents.TAP_STOP -> {
        queue(ACTION_STOP_RECORDING, null, now)
        WidgetUpdater.refreshAll(this)
      }
      WidgetIntents.TAP_COMPLETE -> if (!targetId.isNullOrEmpty()) {
        // The row disappears before the server has been told, because a tick
        // that leaves the row sitting there reads as a missed tap.
        WidgetStore.markCompleted(this, targetId, now)
        queue(ACTION_COMPLETE_HIGHLIGHT, targetId, now)
        WidgetUpdater.refreshAll(this)
      }
      // Opening is MainActivity's business, including recording the tap: it is
      // reached directly from several widgets and must behave the same either way.
      else -> startActivity(MainActivity.widgetIntent(this, page, targetId))
    }
    finish()
    overridePendingTransition(0, 0)
  }

  private fun queue(type: String, targetId: String?, nowMillis: Long) {
    WidgetStore.queueAction(this, type, targetId, nowMillis)
    (application as? NeoRecallApplication)
      ?.backgroundCaptureChannel
      ?.notifyWidgetActionRequested()
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    finish()
  }

  companion object {
    const val ACTION_STOP_RECORDING = "stopRecording"
    const val ACTION_COMPLETE_HIGHLIGHT = "completeHighlight"
  }
}
