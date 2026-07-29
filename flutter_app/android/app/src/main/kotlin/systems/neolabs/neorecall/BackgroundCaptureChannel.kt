package systems.neolabs.neorecall

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Process-level bridge used by both the Activity and foreground service. */
class BackgroundCaptureChannel(private val context: Context) {
  private lateinit var channel: MethodChannel

  fun register(messenger: BinaryMessenger) {
    channel = MethodChannel(messenger, CHANNEL)
    channel.setMethodCallHandler { call, result ->
      when (call.method) {
        "startBackgroundCapture" -> {
          val mode = call.argument<String>("mode") ?: "microphone"
          val intent = Intent(context, BackgroundCaptureService::class.java)
            .putExtra(BackgroundCaptureService.EXTRA_MODE, mode)
          try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
              context.startForegroundService(intent)
            } else {
              context.startService(intent)
            }
            result.success(true)
          } catch (error: Exception) {
            result.error("BACKGROUND_START_FAILED", error.message, null)
          }
        }
        "stopBackgroundCapture" -> {
          val intent = Intent(context, BackgroundCaptureService::class.java)
            .setAction(BackgroundCaptureService.ACTION_STOP)
          try {
            context.startService(intent)
            result.success(true)
          } catch (_: Exception) {
            context.stopService(Intent(context, BackgroundCaptureService::class.java))
            result.success(true)
          }
        }
        "isBackgroundCaptureRunning" -> {
          result.success(BackgroundCaptureService.isRunning(context))
        }
        else -> result.notImplemented()
      }
    }
  }

  fun notifyStopRequested() {
    Handler(Looper.getMainLooper()).post {
      if (::channel.isInitialized) {
        channel.invokeMethod("backgroundStopRequested", null)
      }
    }
  }

  companion object {
    const val CHANNEL = "systems.neolabs.neorecall/background_capture"
  }
}
