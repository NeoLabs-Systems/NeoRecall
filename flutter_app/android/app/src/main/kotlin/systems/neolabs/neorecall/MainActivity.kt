package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

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
    if (intent?.action == ACTION_START_PHONE_RECORDING) {
      (application as NeoRecallApplication)
        .backgroundCaptureChannel
        .requestWidgetPhoneRecording()
    }
  }

  override fun provideFlutterEngine(context: Context): FlutterEngine =
    (application as NeoRecallApplication).flutterEngine

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) = Unit

  override fun shouldDestroyEngineWithHost(): Boolean = false

  companion object {
    const val ACTION_START_PHONE_RECORDING =
      "systems.neolabs.neorecall.START_PHONE_RECORDING"
  }
}
