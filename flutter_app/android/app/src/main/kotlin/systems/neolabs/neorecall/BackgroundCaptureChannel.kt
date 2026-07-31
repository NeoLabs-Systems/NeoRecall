package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
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
        else -> result.notImplemented()
      }
    }
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
  }
}
