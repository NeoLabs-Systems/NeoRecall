package systems.neolabs.neorecall

import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "startBackgroundCapture" -> {
          val mode = call.argument<String>("mode") ?: "microphone"
          val intent = Intent(this, BackgroundCaptureService::class.java)
            .putExtra(BackgroundCaptureService.EXTRA_MODE, mode)
          try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
              startForegroundService(intent)
            } else {
              startService(intent)
            }
            result.success(true)
          } catch (error: Exception) {
            result.error("BACKGROUND_START_FAILED", error.message, null)
          }
        }
        "stopBackgroundCapture" -> {
          val intent = Intent(this, BackgroundCaptureService::class.java)
            .setAction(BackgroundCaptureService.ACTION_STOP)
          try {
            startService(intent)
            result.success(true)
          } catch (error: Exception) {
            // Fall back to hard stop.
            stopService(Intent(this, BackgroundCaptureService::class.java))
            result.success(true)
          }
        }
        "isBackgroundCaptureRunning" -> {
          val running = getSharedPreferences("neorecall_background_capture", MODE_PRIVATE)
            .getBoolean("running", false)
          result.success(running)
        }
        else -> result.notImplemented()
      }
    }
  }

  companion object {
    private const val CHANNEL = "systems.neolabs.neorecall/background_capture"
  }
}
