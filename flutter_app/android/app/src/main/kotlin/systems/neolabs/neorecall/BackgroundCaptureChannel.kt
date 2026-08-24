package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Process-level bridge used by both the Activity and the foreground host. */
class BackgroundCaptureChannel(private val context: Context) {
  private lateinit var channel: MethodChannel

  fun register(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, CHANNEL)
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "applyBackgroundHolds" -> {
          val holds = call.argument<List<String>>("holds").orEmpty()
          try {
            if (holds.isEmpty()) {
              stopHost()
            } else {
              BackgroundCaptureService.requestHolds(
                context,
                holds,
                call.argument<String>("title"),
                call.argument<String>("text"),
              )
            }
            result.success(true)
          } catch (error: Exception) {
            result.error("BACKGROUND_START_FAILED", error.message, null)
          }
        }
        "stopBackgroundCapture" -> {
          stopHost()
          result.success(true)
        }
        "backgroundRuntimeState" -> {
          result.success(
            mapOf(
              "running" to BackgroundCaptureService.isRunning(context),
              "holds" to BackgroundCaptureService.activeHolds(context).toList(),
              "foreground" to
                ((context.applicationContext as? NeoRecallApplication)?.hasVisibleActivity == true),
              "microphoneUnavailable" to
                BackgroundCaptureService.microphoneUnavailable(context),
            ),
          )
        }
        "networkRuntimeState" -> result.success(networkRuntimeState())
        "takePendingWidgetPhoneRecordingRequest" -> {
          val pending = widgetPreferences().getBoolean(
            KEY_WIDGET_PHONE_RECORDING_PENDING,
            false,
          )
          if (pending) {
            widgetPreferences().edit()
              .putBoolean(KEY_WIDGET_PHONE_RECORDING_PENDING, false)
              .commit()
            RecordWidgetProvider.updateAll(context)
          }
          result.success(pending)
        }
        else -> result.notImplemented()
      }
    }
  }

  /**
   * Records the widget action before notifying Dart, so a cold Flutter engine
   * or an Activity/engine attachment race cannot lose the user's tap.
   */
  fun requestWidgetPhoneRecording() {
    widgetPreferences().edit()
      .putBoolean(KEY_WIDGET_PHONE_RECORDING_PENDING, true)
      .commit()
    RecordWidgetProvider.updateAll(context)
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) {
        channel.invokeMethod("widgetPhoneRecordingRequested", null)
      }
    }
  }

  private fun widgetPreferences() =
    context.getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)

  private fun networkRuntimeState(): Map<String, Boolean> {
    val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
    val connected = capabilities?.let {
      it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
        it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    } == true
    return mapOf(
      "connected" to connected,
      "unmetered" to (connected && capabilities?.hasCapability(
        NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
      ) == true),
    )
  }

  private fun stopHost() {
    val intent = Intent(context, BackgroundCaptureService::class.java)
      .setAction(BackgroundCaptureService.ACTION_STOP)
    try {
      context.startService(intent)
    } catch (_: Exception) {
      context.stopService(Intent(context, BackgroundCaptureService::class.java))
    }
  }

  fun notifyStopRequested() {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) {
        channel.invokeMethod("backgroundStopRequested", null)
      }
    }
  }

  /** Surfaces a host-side condition (dropped hold, refused start) in the app. */
  fun notifyHostMessage(message: String) {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) {
        channel.invokeMethod("backgroundHostMessage", mapOf("message" to message))
      }
    }
  }

  companion object {
    const val CHANNEL = "systems.neolabs.neorecall/background_capture"
    private const val WIDGET_PREFS = "neorecall_record_widget"
    private const val KEY_WIDGET_PHONE_RECORDING_PENDING =
      "phoneRecordingPending"

    fun isWidgetPhoneRecordingPending(context: Context): Boolean =
      context.getSharedPreferences(WIDGET_PREFS, Context.MODE_PRIVATE)
        .getBoolean(KEY_WIDGET_PHONE_RECORDING_PENDING, false)
  }
}
