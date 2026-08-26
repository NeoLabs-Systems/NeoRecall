package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import systems.neolabs.neorecall.widgets.WidgetStore
import systems.neolabs.neorecall.widgets.WidgetUpdater

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
        "updateLiveStatus" -> {
          val status = call.arguments as? Map<*, *>
          if (status == null) {
            result.error("INVALID_LIVE_STATUS", "Status payload is missing.", null)
          } else {
            BackgroundCaptureService.updateLiveStatus(context, status)
            result.success(true)
          }
        }
        "clearLiveStatus" -> {
          BackgroundCaptureService.clearLiveStatus(context)
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
        "publishWidgetData" -> {
          val payload = call.argument<String>("payload")
          if (payload == null) {
            result.error("INVALID_WIDGET_DATA", "Widget payload is missing.", null)
          } else {
            WidgetStore.publish(context, payload, System.currentTimeMillis())
            RecordWidgetProvider.updateAll(context)
            result.success(true)
          }
        }
        "takePendingWidgetActions" -> result.success(WidgetStore.takeActions(context))
        "takePendingWatchRecordings" -> try {
          result.success(PhoneWearTransferManager.get(context).pending())
        } catch (error: Exception) {
          result.error("WATCH_INBOX_FAILED", error.message, null)
        }
        "markWatchRecordingImported" -> {
          PhoneWearTransferManager.get(context).markImported(
            requireNotNull(call.argument<String>("recordingId")),
          )
          result.success(true)
        }
        "acknowledgeWatchRecording" -> try {
          result.success(
            PhoneWearTransferManager.get(context).acknowledge(
              requireNotNull(call.argument<String>("recordingId")),
              requireNotNull(call.argument<Map<String, Any?>>("receipt")),
            ),
          )
        } catch (error: Exception) {
          result.error("WATCH_ACK_FAILED", error.message, null)
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

  /**
   * Records a widget tap and tells Dart about it.
   *
   * Same order as [requestWidgetPhoneRecording] and for the same reason: the
   * tap is on disk before anything is notified, so a cold engine or an Activity
   * attachment race cannot lose it.
   */
  fun requestWidgetAction(type: String, targetId: String?) {
    WidgetStore.queueAction(context, type, targetId, System.currentTimeMillis())
    notifyWidgetActionRequested()
  }

  fun notifyWidgetActionRequested() {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) channel.invokeMethod("widgetActionRequested", null)
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

  fun notifyWatchRecordingAvailable() {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) channel.invokeMethod("watchRecordingAvailable", null)
    }
  }

  fun notifyWatchTransferStarted() {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) channel.invokeMethod("watchTransferStarted", null)
    }
  }

  fun notifyWatchTransferFinished(error: String? = null) {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) {
        channel.invokeMethod("watchTransferFinished", mapOf("error" to error))
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
