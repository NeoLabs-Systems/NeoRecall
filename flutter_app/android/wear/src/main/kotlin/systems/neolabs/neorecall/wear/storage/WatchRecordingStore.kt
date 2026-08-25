package systems.neolabs.neorecall.wear.storage

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.security.MessageDigest
import java.util.UUID

data class StoredWatchChunk(
  val recordingId: String,
  val sessionId: String,
  val sourceId: String,
  val sequence: Int,
  val sessionStartedAtMs: Long,
  val startedAtMs: Long,
  val monotonicOffsetMs: Long,
  val durationMs: Long,
  val file: File,
  val sha256: String,
  val isFinal: Boolean,
  val state: String,
)

/** Durable watch-side ownership ledger. Files survive until a terminal phone receipt. */
class WatchRecordingStore private constructor(context: Context) :
  SQLiteOpenHelper(context, "watch_recordings.sqlite3", null, 1) {

  private val appContext = context.applicationContext

  override fun onCreate(db: SQLiteDatabase) {
    db.execSQL(
      """CREATE TABLE recordings (
        recording_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        session_started_at_ms INTEGER NOT NULL,
        started_at_ms INTEGER NOT NULL,
        monotonic_offset_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        is_final INTEGER NOT NULL,
        state TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        UNIQUE(source_id, sequence)
      )""",
    )
    db.execSQL("CREATE INDEX recordings_state ON recordings(state, created_at_ms)")
  }

  override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

  fun add(
    recordingId: String,
    sessionId: String,
    sourceId: String,
    sequence: Int,
    sessionStartedAtMs: Long,
    startedAtMs: Long,
    monotonicOffsetMs: Long,
    durationMs: Long,
    file: File,
    isFinal: Boolean,
  ) {
    val values = ContentValues().apply {
      put("recording_id", recordingId)
      put("session_id", sessionId)
      put("source_id", sourceId)
      put("sequence", sequence)
      put("session_started_at_ms", sessionStartedAtMs)
      put("started_at_ms", startedAtMs)
      put("monotonic_offset_ms", monotonicOffsetMs)
      put("duration_ms", durationMs)
      put("file_path", file.absolutePath)
      put("sha256", sha256(file))
      put("is_final", if (isFinal) 1 else 0)
      put("state", STATE_PENDING)
      put("created_at_ms", System.currentTimeMillis())
    }
    writableDatabase.insertWithOnConflict(
      "recordings",
      null,
      values,
      SQLiteDatabase.CONFLICT_IGNORE,
    )
  }

  fun transferCandidates(includeEnqueued: Boolean = false): List<StoredWatchChunk> {
    val states = if (includeEnqueued) arrayOf(STATE_PENDING, STATE_ENQUEUED) else arrayOf(STATE_PENDING)
    val placeholders = states.joinToString(",") { "?" }
    return readableDatabase.rawQuery(
      "SELECT * FROM recordings WHERE state IN ($placeholders) ORDER BY created_at_ms",
      states,
    ).use { cursor ->
      buildList {
        while (cursor.moveToNext()) {
          val file = File(cursor.getString(cursor.getColumnIndexOrThrow("file_path")))
          if (!file.exists()) continue
          add(
            StoredWatchChunk(
              recordingId = cursor.getString(cursor.getColumnIndexOrThrow("recording_id")),
              sessionId = cursor.getString(cursor.getColumnIndexOrThrow("session_id")),
              sourceId = cursor.getString(cursor.getColumnIndexOrThrow("source_id")),
              sequence = cursor.getInt(cursor.getColumnIndexOrThrow("sequence")),
              sessionStartedAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("session_started_at_ms")),
              startedAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("started_at_ms")),
              monotonicOffsetMs = cursor.getLong(cursor.getColumnIndexOrThrow("monotonic_offset_ms")),
              durationMs = cursor.getLong(cursor.getColumnIndexOrThrow("duration_ms")),
              file = file,
              sha256 = cursor.getString(cursor.getColumnIndexOrThrow("sha256")),
              isFinal = cursor.getInt(cursor.getColumnIndexOrThrow("is_final")) == 1,
              state = cursor.getString(cursor.getColumnIndexOrThrow("state")),
            ),
          )
        }
      }
    }
  }

  fun markEnqueued(recordingId: String) {
    writableDatabase.update(
      "recordings",
      ContentValues().apply { put("state", STATE_ENQUEUED) },
      "recording_id=?",
      arrayOf(recordingId),
    )
  }

  fun pendingCount(): Int = readableDatabase.rawQuery(
    "SELECT COUNT(*) FROM recordings",
    null,
  ).use { if (it.moveToFirst()) it.getInt(0) else 0 }

  fun acknowledge(recordingId: String): Boolean {
    val row = readableDatabase.rawQuery(
      "SELECT file_path FROM recordings WHERE recording_id=?",
      arrayOf(recordingId),
    ).use { if (it.moveToFirst()) it.getString(0) else null } ?: return false
    val file = File(row)
    if (file.exists() && !file.delete()) return false
    writableDatabase.delete("recordings", "recording_id=?", arrayOf(recordingId))
    return true
  }

  fun stableDeviceId(): String {
    val preferences = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val existing = preferences.getString(KEY_DEVICE_ID, null)
    if (existing != null) return existing
    return UUID.randomUUID().toString().also {
      preferences.edit().putString(KEY_DEVICE_ID, it).commit()
    }
  }

  companion object {
    const val STATE_PENDING = "pending"
    const val STATE_ENQUEUED = "enqueued"
    private const val PREFS = "neorecall_watch_identity"
    private const val KEY_DEVICE_ID = "device_id"

    @Volatile private var instance: WatchRecordingStore? = null
    fun get(context: Context): WatchRecordingStore = instance ?: synchronized(this) {
      instance ?: WatchRecordingStore(context).also { instance = it }
    }

    fun sha256(file: File): String {
      val digest = MessageDigest.getInstance("SHA-256")
      file.inputStream().use { input ->
        val buffer = ByteArray(32 * 1024)
        while (true) {
          val read = input.read(buffer)
          if (read < 0) break
          digest.update(buffer, 0, read)
        }
      }
      return digest.digest().joinToString("") { "%02x".format(it) }
    }
  }
}
