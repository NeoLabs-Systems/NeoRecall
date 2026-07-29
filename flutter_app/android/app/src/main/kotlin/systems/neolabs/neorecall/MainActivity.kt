package systems.neolabs.neorecall

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  override fun provideFlutterEngine(context: Context): FlutterEngine =
    (application as NeoRecallApplication).flutterEngine

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) = Unit

  override fun shouldDestroyEngineWithHost(): Boolean = false
}
