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
 * Sticky Android foreground host for always-on background work.
 *
 * Flutter owns chunking, Bluetooth protocol, and upload reliability. This
 * service only keeps the process alive across backgrounding/swipe-away, and it
 * does so for a *set of holds* rather than one capture mode: live microphone
 * capture, live wearable capture, and an idle wearable link (reconnect, device
 * storage sync, upload) can be active in any combination. Foreground service
 * types are the union of what the active holds require.
 */
class BackgroundCaptureService : Service() {
  private var wakeLock: PowerManager.WakeLock? = null
  private var holds: Set<String> = emptySet()
  private var explicitlyStopped = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    createChannel()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopHost()
        return START_NOT_STICKY
      }
      ACTION_REQUEST_STOP -> {
        requestGracefulStop()
        return START_STICKY
      }
      else -> {
        val requested = intent?.getStringArrayListExtra(EXTRA_HOLDS)?.toSet()
          // A null Intent means Android recreated the service after reclaiming
          // the process. Restore the holds that were active when it died.
          ?: persistedHolds()
        if (requested.isEmpty()) {
          stopHost()
          return START_NOT_STICKY
        }
        val title = intent?.getStringExtra(EXTRA_TITLE)
        val text = intent?.getStringExtra(EXTRA_TEXT)
        applyHolds(
          requested,
          title = title ?: persisted().getString(KEY_TITLE, null),
          text = text ?: persisted().getString(KEY_TEXT, null),
          startedFromBackgroundBoot = intent?.getBooleanExtra(EXTRA_FROM_BOOT, false) == true,
        )
      }
    }
    return START_STICKY
  }

  private fun applyHolds(
    requested: Set<String>,
    title: String?,
    text: String?,
    startedFromBackgroundBoot: Boolean,
  ) {
    explicitlyStopped = false
    // A process the system started on its own may not take microphone holds:
    // Android forbids background microphone access, and Android 15 forbids the
    // microphone service type entirely when the start came from BOOT_COMPLETED.
    // Dropping only that hold keeps wearable capture and sync alive instead of
    // losing the whole host.
    val bootSafe = if (startedFromBackgroundBoot) requested - MICROPHONE_HOLDS else requested
    var effective = bootSafe
    var microphoneUnavailable = startedFromBackgroundBoot && bootSafe != requested

    if (!enterForeground(effective, title, text)) {
      val reduced = effective - MICROPHONE_HOLDS
      if (reduced.isEmpty() || !enterForeground(reduced, title, text)) {
        notifyHost("NeoRecall could not start its background host on this device.")
        stopHost()
        return
      }
      effective = reduced
      microphoneUnavailable = true
    }

    holds = effective
    if (effective.any { it in WAKE_LOCK_HOLDS }) acquireWakeLock() else releaseWakeLock()
    persisted().edit()
      .putBoolean(KEY_RUNNING, true)
      .putStringSet(KEY_HOLDS, effective)
      .putString(KEY_TITLE, title)
      .putString(KEY_TEXT, text)
      .putBoolean(KEY_MICROPHONE_UNAVAILABLE, microphoneUnavailable)
      .apply()
    if (microphoneUnavailable) {
      notifyHost(
        "Phone-microphone recording cannot resume without the app open. Bluetooth capture and sync are running.",
      )
    }
  }

  /** Returns false when the platform refuses the requested service types. */
  private fun enterForeground(requested: Set<String>, title: String?, text: String?): Boolean {
    if (requested.isEmpty()) return false
    val notification = buildNotification(requested, title, text)
    return try {
      val types = serviceTypes(requested)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && types != 0) {
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }
      true
    } catch (_: Throwable) {
      false
    }
  }

  private fun serviceTypes(requested: Set<String>): Int {
    var types = 0
    if (requested.contains(HOLD_MICROPHONE)) {
      types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
    }
    if (requested.any { it in CONNECTED_DEVICE_HOLDS }) {
      types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
    }
    return types
  }

  private fun stopHost() {
    explicitlyStopped = true
    holds = emptySet()
    releaseWakeLock()
    persisted().edit()
      .putBoolean(KEY_RUNNING, false)
      .putStringSet(KEY_HOLDS, emptySet())
      .putBoolean(KEY_MICROPHONE_UNAVAILABLE, false)
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
    channel()?.notifyStopRequested()
    Handler(Looper.getMainLooper()).postDelayed({
      if (isRunning(this)) stopHost()
    }, GRACEFUL_STOP_TIMEOUT_MS)
  }

  private fun notifyHost(message: String) {
    channel()?.notifyHostMessage(message)
  }

  private fun channel(): BackgroundCaptureChannel? = runCatching {
    (application as? NeoRecallApplication)?.backgroundCaptureChannel
  }.getOrNull()

  private fun releaseWakeLock() {
    try {
      if (wakeLock?.isHeld == true) wakeLock?.release()
    } catch (_: Throwable) {
    }
    wakeLock = null
  }

  private fun persisted() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun persistedHolds(): Set<String> =
    persisted().getStringSet(KEY_HOLDS, emptySet()) ?: emptySet()

  private fun createChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = getSystemService(NotificationManager::class.java)
    val channel = NotificationChannel(
      CHANNEL_ID,
      "NeoRecall background",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "Keeps NeoRecall recording and syncing while the app is closed"
      setShowBadge(false)
    }
    manager.createNotificationChannel(channel)
  }

  private fun buildNotification(
    requested: Set<String>,
    title: String?,
    text: String?,
  ): Notification {
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
    val capturing = requested.any { it in CAPTURE_HOLDS }
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(
        title ?: if (capturing) "NeoRecall is recording" else "NeoRecall stays connected",
      )
      .setContentText(
        text ?: when {
          capturing -> "Audio is being captured"
          requested.contains(HOLD_WEARABLE_SYNC) -> "Syncing recordings from your device"
          else -> "Your device stays linked so recordings sync on their own"
        },
      )
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
    // Preserve the requested holds when Android reclaims the service. START_STICKY
    // can then recreate it with a null Intent and restore them. Explicit user/app
    // stops clear the flag in stopHost().
    if (explicitlyStopped) {
      persisted().edit().putBoolean(KEY_RUNNING, false).apply()
    }
    super.onDestroy()
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    // Keep the sticky host alive after swipe-away while holds remain.
    if (isRunning(this) && holds.isNotEmpty()) {
      val restart = Intent(applicationContext, BackgroundCaptureService::class.java)
        .putStringArrayListExtra(EXTRA_HOLDS, ArrayList(holds))
        .putExtra(EXTRA_TITLE, persisted().getString(KEY_TITLE, null))
        .putExtra(EXTRA_TEXT, persisted().getString(KEY_TEXT, null))
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
    const val EXTRA_HOLDS = "holds"
    const val EXTRA_TITLE = "title"
    const val EXTRA_TEXT = "text"
    const val EXTRA_FROM_BOOT = "fromBoot"
    const val ACTION_STOP = "systems.neolabs.neorecall.STOP_CAPTURE"
    const val ACTION_REQUEST_STOP =
      "systems.neolabs.neorecall.REQUEST_STOP_CAPTURE"

    const val HOLD_MICROPHONE = "microphoneCapture"
    const val HOLD_WEARABLE_CAPTURE = "wearableCapture"
    const val HOLD_WEARABLE_LINK = "wearableLink"
    const val HOLD_WEARABLE_SYNC = "wearableSync"

    /** Holds that stream audio, i.e. the ones the notification calls recording. */
    private val CAPTURE_HOLDS = setOf(HOLD_MICROPHONE, HOLD_WEARABLE_CAPTURE)

    /**
     * Holds whose work would be stretched across sleep cycles without the CPU:
     * live capture, and an in-flight transfer off a device. A merely linked
     * device is excluded on purpose — a round-the-clock wake lock for an idle
     * link would cost battery for nothing.
     */
    private val WAKE_LOCK_HOLDS = CAPTURE_HOLDS + HOLD_WEARABLE_SYNC
    private val MICROPHONE_HOLDS = setOf(HOLD_MICROPHONE)
    private val CONNECTED_DEVICE_HOLDS =
      setOf(HOLD_WEARABLE_CAPTURE, HOLD_WEARABLE_LINK, HOLD_WEARABLE_SYNC)

    private const val GRACEFUL_STOP_TIMEOUT_MS = 15_000L
    private const val PREFS = "neorecall_background_capture"
    private const val KEY_RUNNING = "running"
    private const val KEY_HOLDS = "holds"
    private const val KEY_TITLE = "title"
    private const val KEY_TEXT = "text"
    private const val KEY_MICROPHONE_UNAVAILABLE = "microphoneUnavailable"

    private fun prefs(context: Context) =
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isRunning(context: Context): Boolean =
      prefs(context).getBoolean(KEY_RUNNING, false)

    fun activeHolds(context: Context): Set<String> =
      prefs(context).getStringSet(KEY_HOLDS, emptySet()) ?: emptySet()

    fun microphoneUnavailable(context: Context): Boolean =
      prefs(context).getBoolean(KEY_MICROPHONE_UNAVAILABLE, false)

    fun requestHolds(
      context: Context,
      holds: List<String>,
      title: String?,
      text: String?,
      fromBoot: Boolean = false,
    ) {
      val intent = Intent(context, BackgroundCaptureService::class.java)
        .putStringArrayListExtra(EXTRA_HOLDS, ArrayList(holds))
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_TEXT, text)
        .putExtra(EXTRA_FROM_BOOT, fromBoot)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        context.startForegroundService(intent)
      } else {
        context.startService(intent)
      }
    }

    /**
     * Restores the host after a reboot for every hold that may legally start
     * from the background. Microphone capture is intentionally not restored:
     * Android denies microphone access to a process with no UI, so claiming it
     * would produce a silent recording instead of an honest gap.
     */
    fun restoreAfterBoot(context: Context) {
      if (!isRunning(context)) return
      val restorable = activeHolds(context).filter { it != HOLD_MICROPHONE }
      if (restorable.isEmpty()) {
        // Nothing may run headlessly. Record why, and do not claim a live host.
        prefs(context).edit()
          .putBoolean(KEY_RUNNING, false)
          .putBoolean(KEY_MICROPHONE_UNAVAILABLE, true)
          .apply()
        return
      }
      requestHolds(
        context,
        restorable,
        prefs(context).getString(KEY_TITLE, null),
        prefs(context).getString(KEY_TEXT, null),
        fromBoot = true,
      )
    }
  }
}
