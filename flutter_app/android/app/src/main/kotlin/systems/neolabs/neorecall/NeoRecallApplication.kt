package systems.neolabs.neorecall

import android.app.Application
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Owns one process-scoped Flutter engine.
 *
 * Recording, the durable chunk ledger, Bluetooth reconnect, and uploads must
 * outlive the Activity when the user backgrounds or swipes away the UI. The
 * foreground service keeps this process alive while capture is requested.
 */
class NeoRecallApplication : Application() {
  lateinit var flutterEngine: FlutterEngine
    private set
  lateinit var backgroundCaptureChannel: BackgroundCaptureChannel
    private set

  override fun onCreate() {
    super.onCreate()
    val loader = FlutterInjector.instance().flutterLoader()
    loader.startInitialization(this)
    loader.ensureInitializationComplete(this, null)

    // This process-owned engine is registered exactly once below. Leaving the
    // constructor's automatic registration enabled and then invoking the
    // generated registrant again can leave global plugin channels (notably
    // audioplayers) attached inconsistently across Activity reattachments.
    flutterEngine = FlutterEngine(this, null, false)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    backgroundCaptureChannel = BackgroundCaptureChannel(this).also {
      it.register(flutterEngine.dartExecutor.binaryMessenger)
    }
    flutterEngine.dartExecutor.executeDartEntrypoint(
      DartExecutor.DartEntrypoint.createDefault(),
    )
    FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
  }

  companion object {
    const val ENGINE_ID = "neorecall_process_engine"
  }
}
