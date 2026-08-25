package systems.neolabs.neorecall

import android.app.Activity
import android.app.Application
import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Owns one process-scoped Flutter engine.
 *
 * Recording, the durable chunk ledger, Bluetooth reconnect, device-storage sync,
 * and uploads must outlive the Activity when the user backgrounds or swipes away
 * the UI. The foreground host keeps this process alive while any background hold
 * is held.
 */
class NeoRecallApplication : Application() {
  lateinit var flutterEngine: FlutterEngine
    private set
  lateinit var backgroundCaptureChannel: BackgroundCaptureChannel
    private set

  /**
   * True while an Activity is attached and visible.
   *
   * The Dart runtime needs this to tell an ordinary background run apart from a
   * process the system started on its own (boot, sticky restart). Android denies
   * microphone access to the latter, so the runtime must not try to capture from
   * the phone microphone there.
   */
  @Volatile
  var hasVisibleActivity: Boolean = false
    private set

  override fun onCreate() {
    super.onCreate()
    registerActivityLifecycleCallbacks(activityTracker)
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
    PhoneWearTransferManager.get(this).recoverPersistentItems(
      onStarted = backgroundCaptureChannel::notifyWatchTransferStarted,
      onInserted = backgroundCaptureChannel::notifyWatchRecordingAvailable,
      onFinished = backgroundCaptureChannel::notifyWatchTransferFinished,
    )
    flutterEngine.dartExecutor.executeDartEntrypoint(
      DartExecutor.DartEntrypoint.createDefault(),
    )
    FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
  }

  private val activityTracker = object : ActivityLifecycleCallbacks {
    private var started = 0

    override fun onActivityStarted(activity: Activity) {
      started += 1
      hasVisibleActivity = true
    }

    override fun onActivityStopped(activity: Activity) {
      started = (started - 1).coerceAtLeast(0)
      hasVisibleActivity = started > 0
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
  }

  companion object {
    const val ENGINE_ID = "neorecall_process_engine"
  }
}
