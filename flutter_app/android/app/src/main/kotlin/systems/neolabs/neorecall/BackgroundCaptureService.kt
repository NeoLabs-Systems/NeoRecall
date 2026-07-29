package systems.neolabs.neorecall

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Sticky Android foreground host for always-on capture.
 *
 * Flutter owns chunking + upload reliability. This service keeps the process
 * alive across backgrounding/swipes with a persistent notification and a
 * partial wake lock while capture is active.
 */
class BackgroundCaptureService : Service() {
  private var wakeLock: PowerManager.WakeLock? = null
  private var mode: String = "microphone"

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    createChannel()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopCapture()
        return START_NOT_STICKY
      }
      ACTION_REQUEST_STOP -> {
        requestGracefulStop()
        return START_STICKY
      }
      else -> {
        mode = intent?.getStringExtra(EXTRA_MODE) ?: mode
        startCapture(mode)
      }
    }
    return START_STICKY
  }

  private fun startCapture(mode: String) {
    this.mode = mode
    val notification = buildNotification(mode)
    val serviceType = if (mode == MODE_BLUETOOTH) {
      ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
    } else {
      ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      ServiceCompat.startForeground(
        this,
        NOTIFICATION_ID,
        notification,
        serviceType,
      )
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
    acquireWakeLock()
    getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(KEY_RUNNING, true)
      .putString(KEY_MODE, mode)
      .apply()
  }

  private fun stopCapture() {
    releaseWakeLock()
    getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(KEY_RUNNING, false)
      .apply()
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
  }

  private fun acquireWakeLock() {
    if (wakeLock?.isHeld == true) return
    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
    wakeLock = pm.newWakeLock(
      PowerManager.PARTIAL_WAKE_LOCK,
      "NeoRecall:BackgroundCapture",
    ).apply {
      setReferenceCounted(false)
      acquire()
    }
  }

  private fun requestGracefulStop() {
    (application as? NeoRecallApplication)
      ?.backgroundCaptureChannel
      ?.notifyStopRequested()
    Handler(Looper.getMainLooper()).postDelayed({
      if (isRunning(this)) stopCapture()
    }, GRACEFUL_STOP_TIMEOUT_MS)
  }

  private fun releaseWakeLock() {
    try {
      if (wakeLock?.isHeld == true) wakeLock?.release()
    } catch (_: Throwable) {
    }
    wakeLock = null
  }

  private fun createChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = getSystemService(NotificationManager::class.java)
    val channel = NotificationChannel(
      CHANNEL_ID,
      "NeoRecall capture",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "Keeps NeoRecall recording while the app is in the background"
      setShowBadge(false)
    }
    manager.createNotificationChannel(channel)
  }

  private fun buildNotification(mode: String): Notification {
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
    val contentIntent = PendingIntent.getActivity(
      this,
      0,
      launchIntent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val stopIntent = Intent(this, BackgroundCaptureService::class.java).apply {
      action = ACTION_REQUEST_STOP
    }
    val stopPending = PendingIntent.getService(
      this,
      1,
      stopIntent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val text = when (mode) {
      MODE_BLUETOOTH -> "Connected wearable audio is being captured"
      else -> "Microphone audio is being captured"
    }
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("NeoRecall is recording")
      .setContentText(text)
      .setSmallIcon(android.R.drawable.ic_btn_speak_now)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .setContentIntent(contentIntent)
      .addAction(0, "Stop", stopPending)
      .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
      .build()
  }

  override fun onDestroy() {
    releaseWakeLock()
    getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(KEY_RUNNING, false)
      .apply()
    super.onDestroy()
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    // Keep sticky service alive after swipe-away when recording.
    val running = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .getBoolean(KEY_RUNNING, false)
    if (running) {
      val restart = Intent(applicationContext, BackgroundCaptureService::class.java)
        .putExtra(EXTRA_MODE, mode)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        applicationContext.startForegroundService(restart)
      } else {
        applicationContext.startService(restart)
      }
    }
    super.onTaskRemoved(rootIntent)
  }

  companion object {
    const val CHANNEL_ID = "neorecall_capture"
    const val NOTIFICATION_ID = 45001
    const val EXTRA_MODE = "mode"
    const val ACTION_STOP = "systems.neolabs.neorecall.STOP_CAPTURE"
    const val ACTION_REQUEST_STOP =
      "systems.neolabs.neorecall.REQUEST_STOP_CAPTURE"
    const val MODE_BLUETOOTH = "bluetooth"
    private const val GRACEFUL_STOP_TIMEOUT_MS = 15_000L
    private const val PREFS = "neorecall_background_capture"
    private const val KEY_RUNNING = "running"
    private const val KEY_MODE = "mode"

    fun isRunning(context: Context): Boolean =
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getBoolean(KEY_RUNNING, false)
  }
}
