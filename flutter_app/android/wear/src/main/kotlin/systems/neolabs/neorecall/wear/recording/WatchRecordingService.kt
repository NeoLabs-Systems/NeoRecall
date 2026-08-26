package systems.neolabs.neorecall.wear.recording

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import systems.neolabs.neorecall.wear.WatchMainActivity
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import systems.neolabs.neorecall.wear.sync.WatchSyncManager
import java.util.UUID

/** User-started, notification-visible microphone owner. Recording survives the UI closing. */
class WatchRecordingService : Service() {
  private var recorder: AacChunkRecorder? = null
  private var wakeLock: PowerManager.WakeLock? = null
  private val store by lazy { WatchRecordingStore.get(this) }
  private val preferences by lazy { getSharedPreferences(PREFS, Context.MODE_PRIVATE) }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    createNotificationChannel()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> stopRecording()
      ACTION_START -> startRecording(newSession = !preferences.getBoolean(KEY_ACTIVE, false))
      else -> {
        // START_STICKY restarts are permitted for an already-running foreground
        // service. A boot receiver deliberately never enters this branch.
        if (preferences.getBoolean(KEY_ACTIVE, false)) startRecording(newSession = false)
        else stopSelf()
      }
    }
    return START_STICKY
  }

  private fun startRecording(newSession: Boolean) {
    if (recorder != null) return
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      clearActiveState()
      stopSelf()
      return
    }
    val now = System.currentTimeMillis()
    val sessionId = if (newSession) UUID.randomUUID().toString()
    else preferences.getString(KEY_SESSION_ID, null) ?: UUID.randomUUID().toString()
    val sourceId = if (newSession) UUID.randomUUID().toString()
    else preferences.getString(KEY_SOURCE_ID, null) ?: UUID.randomUUID().toString()
    val sessionStartedAt = if (newSession) now else preferences.getLong(KEY_STARTED_AT, now)
    var sequence = if (newSession) 0 else preferences.getInt(KEY_SEQUENCE, 0)
    var offset = if (newSession) 0L else preferences.getLong(KEY_OFFSET, 0L)

    preferences.edit()
      .putBoolean(KEY_ACTIVE, true)
      .putString(KEY_SESSION_ID, sessionId)
      .putString(KEY_SOURCE_ID, sourceId)
      .putLong(KEY_STARTED_AT, sessionStartedAt)
      .putInt(KEY_SEQUENCE, sequence)
      .putLong(KEY_OFFSET, offset)
      .commit()

    ServiceCompat.startForeground(
      this,
      NOTIFICATION_ID,
      notification(),
      ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
    )
    if (!newSession) {
      AacChunkRecorder.recoverPartial(
        this,
        sessionId,
        sourceId,
        sessionStartedAt,
        sequence,
        offset,
        isFinal = false,
      )?.let { recovered ->
        store.add(
          recovered.recordingId,
          sessionId,
          sourceId,
          recovered.sequence,
          sessionStartedAt,
          recovered.startedAtMs,
          recovered.monotonicOffsetMs,
          recovered.durationMs,
          recovered.file,
          recovered.isFinal,
        )
        sequence += 1
        offset += recovered.durationMs
        preferences.edit().putInt(KEY_SEQUENCE, sequence).putLong(KEY_OFFSET, offset).commit()
        WatchSyncManager.get(this).syncPending()
      }
    }
    wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
      .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NeoRecall:WatchRecording")
      .apply { acquire() }

    recorder = AacChunkRecorder(
      context = this,
      sessionId = sessionId,
      sourceId = sourceId,
      sessionStartedAtMs = sessionStartedAt,
      startingSequence = sequence,
      startingOffsetMs = offset,
      onChunk = { chunk ->
        store.add(
          chunk.recordingId,
          sessionId,
          sourceId,
          chunk.sequence,
          sessionStartedAt,
          chunk.startedAtMs,
          chunk.monotonicOffsetMs,
          chunk.durationMs,
          chunk.file,
          chunk.isFinal,
        )
        preferences.edit()
          .putInt(KEY_SEQUENCE, chunk.sequence + 1)
          .putLong(KEY_OFFSET, chunk.monotonicOffsetMs + chunk.durationMs)
          .commit()
        WatchSyncManager.get(this).syncPending()
        broadcastState()
      },
      onFailure = {
        recorder = null
        clearActiveState()
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        broadcastState()
      },
    ).also { it.start() }
    broadcastState()
  }

  private fun stopRecording() {
    val active = recorder
    recorder = null
    active?.stopAndJoin()
    clearActiveState()
    releaseWakeLock()
    stopForeground(STOP_FOREGROUND_REMOVE)
    stopSelf()
    WatchSyncManager.get(this).syncPending(includeEnqueued = true)
    broadcastState()
  }

  private fun clearActiveState() {
    preferences.edit().putBoolean(KEY_ACTIVE, false).commit()
  }

  private fun releaseWakeLock() {
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
  }

  override fun onDestroy() {
    recorder?.stopAndJoin()
    recorder = null
    releaseWakeLock()
    super.onDestroy()
  }

  private fun notification() = NotificationCompat.Builder(this, CHANNEL_ID)
    .setSmallIcon(android.R.drawable.ic_btn_speak_now)
    .setContentTitle("NeoRecall is recording")
    .setContentText("Audio stays safe on your watch until it is processed.")
    .setOngoing(true)
    .setCategory(NotificationCompat.CATEGORY_SERVICE)
    .setContentIntent(
      PendingIntent.getActivity(
        this,
        0,
        Intent(this, WatchMainActivity::class.java),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      ),
    )
    .addAction(
      android.R.drawable.ic_media_pause,
      "Stop",
      PendingIntent.getService(
        this,
        1,
        Intent(this, WatchRecordingService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
      ),
    )
    .build()

  private fun createNotificationChannel() {
    (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
      NotificationChannel(CHANNEL_ID, "Watch recording", NotificationManager.IMPORTANCE_LOW),
    )
  }

  private fun broadcastState() {
    sendBroadcast(Intent(ACTION_STATE_CHANGED).setPackage(packageName))
  }

  companion object {
    const val ACTION_START = "systems.neolabs.neorecall.wear.START_RECORDING"
    const val ACTION_STOP = "systems.neolabs.neorecall.wear.STOP_RECORDING"
    const val ACTION_STATE_CHANGED = "systems.neolabs.neorecall.wear.RECORDING_STATE_CHANGED"
    private const val CHANNEL_ID = "watch_recording"
    private const val NOTIFICATION_ID = 4102
    private const val PREFS = "neorecall_watch_recording"
    private const val KEY_ACTIVE = "active"
    private const val KEY_SESSION_ID = "session_id"
    private const val KEY_SOURCE_ID = "source_id"
    private const val KEY_STARTED_AT = "started_at"
    private const val KEY_SEQUENCE = "sequence"
    private const val KEY_OFFSET = "offset"

    fun isRecording(context: Context): Boolean = context
      .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      .getBoolean(KEY_ACTIVE, false)

    /** Finalizes an interrupted tail but never starts the boot-prohibited mic FGS. */
    fun recoverAfterBoot(context: Context) {
      val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
      if (!preferences.getBoolean(KEY_ACTIVE, false)) return
      val sessionId = preferences.getString(KEY_SESSION_ID, null) ?: return
      val sourceId = preferences.getString(KEY_SOURCE_ID, null) ?: return
      val startedAt = preferences.getLong(KEY_STARTED_AT, 0L)
      val sequence = preferences.getInt(KEY_SEQUENCE, 0)
      val offset = preferences.getLong(KEY_OFFSET, 0L)
      AacChunkRecorder.recoverPartial(
        context,
        sessionId,
        sourceId,
        startedAt,
        sequence,
        offset,
        isFinal = true,
      )?.let { recovered ->
        WatchRecordingStore.get(context).add(
          recovered.recordingId,
          sessionId,
          sourceId,
          recovered.sequence,
          startedAt,
          recovered.startedAtMs,
          recovered.monotonicOffsetMs,
          recovered.durationMs,
          recovered.file,
          recovered.isFinal,
        )
      }
      preferences.edit().putBoolean(KEY_ACTIVE, false).commit()
      WatchSyncManager.get(context).syncPending(includeEnqueued = true)
    }
  }
}
