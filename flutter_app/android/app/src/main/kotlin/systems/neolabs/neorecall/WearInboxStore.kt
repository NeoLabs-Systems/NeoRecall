package systems.neolabs.neorecall

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

data class PhoneWearRecording(
  val recordingId: String,
  val sessionId: String,
  val sourceId: String,
  val watchDeviceId: String,
  val watchName: String,
  val sequence: Int,
  val sessionStartedAtMs: Long,
  val startedAtMs: Long,
  val monotonicOffsetMs: Long,
  val durationMs: Long,
  val sampleRate: Int,
  val isFinal: Boolean,
  val sha256: String,
  val container: String,
  val codec: String,
  val contentType: String,
  val file: File,
)

/** Native durable handoff inbox. Flutter explicitly claims each row after its own commit. */
class WearInboxStore private constructor(context: Context) :
  SQLiteOpenHelper(context, "wear_phone_inbox.sqlite3", null, 1) {
  private val directory = File(context.filesDir, "wear_inbox").apply { mkdirs() }

  override fun onCreate(db: SQLiteDatabase) {
    db.execSQL(
      """CREATE TABLE inbox (
        recording_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        watch_device_id TEXT NOT NULL,
        watch_name TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        session_started_at_ms INTEGER NOT NULL,
        started_at_ms INTEGER NOT NULL,
        monotonic_offset_ms INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        sample_rate INTEGER NOT NULL,
        is_final INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        container TEXT NOT NULL,
        codec TEXT NOT NULL,
        content_type TEXT NOT NULL,
        file_path TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      )""",
    )
    db.execSQL("CREATE INDEX inbox_state ON inbox(state, created_at_ms)")
  }

  override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit

  @Synchronized fun accept(recording: PhoneWearRecording): Boolean {
    if (state(recording.recordingId) != null) {
      recording.file.delete()
      return false
    }
    val destination = File(directory, "${recording.recordingId}.${recording.container}")
    if (!recording.file.renameTo(destination)) {
      recording.file.inputStream().use { input ->
        FileOutputStream(destination).use { output ->
          input.copyTo(output)
          output.fd.sync()
        }
      }
      recording.file.delete()
    }
    val values = ContentValues().apply {
      put("recording_id", recording.recordingId)
      put("session_id", recording.sessionId)
      put("source_id", recording.sourceId)
      put("watch_device_id", recording.watchDeviceId)
      put("watch_name", recording.watchName)
      put("sequence", recording.sequence)
      put("session_started_at_ms", recording.sessionStartedAtMs)
      put("started_at_ms", recording.startedAtMs)
      put("monotonic_offset_ms", recording.monotonicOffsetMs)
      put("duration_ms", recording.durationMs)
      put("sample_rate", recording.sampleRate)
      put("is_final", if (recording.isFinal) 1 else 0)
      put("sha256", recording.sha256)
      put("container", recording.container)
      put("codec", recording.codec)
      put("content_type", recording.contentType)
      put("file_path", destination.absolutePath)
      put("state", STATE_RECEIVED)
      put("created_at_ms", System.currentTimeMillis())
    }
    val inserted = writableDatabase.insertWithOnConflict(
      "inbox", null, values, SQLiteDatabase.CONFLICT_IGNORE,
    ) >= 0
    if (!inserted) destination.delete()
    return inserted
  }

  fun pending(limit: Int = 20): List<PhoneWearRecording> = readableDatabase.rawQuery(
    "SELECT * FROM inbox WHERE state=? ORDER BY session_started_at_ms, sequence LIMIT ?",
    arrayOf(STATE_RECEIVED, limit.toString()),
  ).use { cursor ->
    buildList {
      while (cursor.moveToNext()) {
        val file = File(cursor.getString(cursor.getColumnIndexOrThrow("file_path")))
        if (!file.exists()) continue
        add(
          PhoneWearRecording(
            recordingId = cursor.getString(cursor.getColumnIndexOrThrow("recording_id")),
            sessionId = cursor.getString(cursor.getColumnIndexOrThrow("session_id")),
            sourceId = cursor.getString(cursor.getColumnIndexOrThrow("source_id")),
            watchDeviceId = cursor.getString(cursor.getColumnIndexOrThrow("watch_device_id")),
            watchName = cursor.getString(cursor.getColumnIndexOrThrow("watch_name")),
            sequence = cursor.getInt(cursor.getColumnIndexOrThrow("sequence")),
            sessionStartedAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("session_started_at_ms")),
            startedAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("started_at_ms")),
            monotonicOffsetMs = cursor.getLong(cursor.getColumnIndexOrThrow("monotonic_offset_ms")),
            durationMs = cursor.getLong(cursor.getColumnIndexOrThrow("duration_ms")),
            sampleRate = cursor.getInt(cursor.getColumnIndexOrThrow("sample_rate")),
            isFinal = cursor.getInt(cursor.getColumnIndexOrThrow("is_final")) == 1,
            sha256 = cursor.getString(cursor.getColumnIndexOrThrow("sha256")),
            container = cursor.getString(cursor.getColumnIndexOrThrow("container")),
            codec = cursor.getString(cursor.getColumnIndexOrThrow("codec")),
            contentType = cursor.getString(cursor.getColumnIndexOrThrow("content_type")),
            file = file,
          ),
        )
      }
    }
  }

  fun markImported(recordingId: String) {
    writableDatabase.update(
      "inbox",
      ContentValues().apply { put("state", STATE_IMPORTED) },
      "recording_id=? AND state=?",
      arrayOf(recordingId, STATE_RECEIVED),
    )
  }

  fun state(recordingId: String): String? = readableDatabase.rawQuery(
    "SELECT state FROM inbox WHERE recording_id=?",
    arrayOf(recordingId),
  ).use { if (it.moveToFirst()) it.getString(0) else null }

  fun markAcknowledged(recordingId: String) {
    val path = readableDatabase.rawQuery(
      "SELECT file_path FROM inbox WHERE recording_id=?",
      arrayOf(recordingId),
    ).use { if (it.moveToFirst()) it.getString(0) else null }
    writableDatabase.update(
      "inbox",
      ContentValues().apply { put("state", STATE_ACKNOWLEDGED) },
      "recording_id=?",
      arrayOf(recordingId),
    )
    path?.let { File(it).delete() }
  }

  companion object {
    const val STATE_RECEIVED = "received"
    const val STATE_IMPORTED = "imported"
    const val STATE_ACKNOWLEDGED = "acknowledged"
    @Volatile private var instance: WearInboxStore? = null
    fun get(context: Context): WearInboxStore = instance ?: synchronized(this) {
      instance ?: WearInboxStore(context.applicationContext).also { instance = it }
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
