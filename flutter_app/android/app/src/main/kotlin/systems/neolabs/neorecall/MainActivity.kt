package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import systems.neolabs.neorecall.widgets.WidgetIntents

class MainActivity : FlutterActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    handleLaunchIntent(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    handleLaunchIntent(intent)
  }

  private fun handleLaunchIntent(intent: Intent?) {
    if (intent == null) return
    val channel = (application as NeoRecallApplication).backgroundCaptureChannel
    if (intent.action == ACTION_START_PHONE_RECORDING) {
      channel.requestWidgetPhoneRecording()
      return
    }
    // A widget that opens the app records where it wanted to go, so a cold
    // start lands in the right place instead of on whatever page was last open.
    val page = intent.getStringExtra(EXTRA_WIDGET_PAGE) ?: return
    val targetId = intent.getStringExtra(EXTRA_WIDGET_TARGET_ID)
    val action = when {
      targetId.isNullOrEmpty() -> ACTION_OPEN_PAGE
      page == WidgetIntents.PAGE_MEMORIES -> ACTION_OPEN_MEMORY
      page == WidgetIntents.PAGE_HIGHLIGHTS -> ACTION_OPEN_HIGHLIGHT
      else -> ACTION_OPEN_PAGE
    }
    channel.requestWidgetAction(
      action,
      if (action == ACTION_OPEN_PAGE) page else targetId,
    )
    // Claimed once. Reopening the app from Recents must not navigate again.
    intent.removeExtra(EXTRA_WIDGET_PAGE)
    intent.removeExtra(EXTRA_WIDGET_TARGET_ID)
  }

  override fun provideFlutterEngine(context: Context): FlutterEngine =
    (application as NeoRecallApplication).flutterEngine

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) = Unit

  override fun shouldDestroyEngineWithHost(): Boolean = false

  companion object {
    const val ACTION_START_PHONE_RECORDING =
      "systems.neolabs.neorecall.START_PHONE_RECORDING"
    const val EXTRA_WIDGET_PAGE = "systems.neolabs.neorecall.WIDGET_PAGE"
    const val EXTRA_WIDGET_TARGET_ID = "systems.neolabs.neorecall.WIDGET_TARGET_ID"

    const val ACTION_OPEN_PAGE = "openPage"
    const val ACTION_OPEN_MEMORY = "openMemory"
    const val ACTION_OPEN_HIGHLIGHT = "openHighlight"

    /** The intent a widget uses to open the app on [page], optionally on one item. */
    @JvmStatic
    fun widgetIntent(context: Context, page: String, targetId: String?): Intent =
      Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
          Intent.FLAG_ACTIVITY_CLEAR_TOP or
          Intent.FLAG_ACTIVITY_SINGLE_TOP
        putExtra(EXTRA_WIDGET_PAGE, page)
        if (!targetId.isNullOrEmpty()) putExtra(EXTRA_WIDGET_TARGET_ID, targetId)
      }
  }
}
