package systems.neolabs.neorecall

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataMap
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol
import java.io.File
import java.io.FileOutputStream
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors

class PhoneWearTransferManager private constructor(private val context: Context) {
  private val inbox = WearInboxStore.get(context)
  private val executor = Executors.newSingleThreadExecutor()

  /** Replays persistent Data Items after a phone process crash or package update. */
  fun recoverPersistentItems(
    onStarted: () -> Unit,
    onInserted: () -> Unit,
    onFinished: (String?) -> Unit,
  ) {
    executor.execute {
      val items = runCatching { Tasks.await(Wearable.getDataClient(context).dataItems) }.getOrNull()
        ?: return@execute
      items.use { buffer ->
        buffer.forEach { item ->
          if (item.uri.path.orEmpty().startsWith(WearTransferProtocol.RECORDING_PATH_PREFIX)) {
            onStarted()
            val transfer = runCatching { receive(item) }
            transfer.onSuccess { if (it) onInserted() }
            onFinished(transfer.exceptionOrNull()?.message)
          }
        }
      }
    }
  }

  fun receive(item: com.google.android.gms.wearable.DataItem): Boolean {
    val map = DataMapItem.fromDataItem(item).dataMap
    require(map.getInt(WearTransferProtocol.KEY_VERSION) == WearTransferProtocol.VERSION)
    val recordingId = required(map, WearTransferProtocol.KEY_RECORDING_ID)
    val asset = requireNotNull(map.getAsset(WearTransferProtocol.KEY_AUDIO))
    val temporary = File(context.cacheDir, "wear-${UUID.randomUUID()}.partial")
    val response = Tasks.await(Wearable.getDataClient(context).getFdForAsset(asset))
    response.inputStream.use { input ->
      FileOutputStream(temporary).use { output ->
        input.copyTo(output)
        output.fd.sync()
      }
    }
    val claimedHash = required(map, WearTransferProtocol.KEY_SHA256)
    if (!WearInboxStore.sha256(temporary).equals(claimedHash, ignoreCase = true)) {
      temporary.delete()
      error("Wear recording hash does not match metadata.")
    }
    return inbox.accept(
      PhoneWearRecording(
        recordingId = recordingId,
        sessionId = required(map, WearTransferProtocol.KEY_SESSION_ID),
        sourceId = required(map, WearTransferProtocol.KEY_SOURCE_ID),
        watchDeviceId = required(map, WearTransferProtocol.KEY_WATCH_DEVICE_ID),
        watchName = required(map, WearTransferProtocol.KEY_WATCH_NAME),
        sequence = map.getInt(WearTransferProtocol.KEY_SEQUENCE),
        sessionStartedAtMs = map.getLong(WearTransferProtocol.KEY_SESSION_STARTED_AT_MS),
        startedAtMs = map.getLong(WearTransferProtocol.KEY_STARTED_AT_MS),
        monotonicOffsetMs = map.getLong(WearTransferProtocol.KEY_MONOTONIC_OFFSET_MS),
        durationMs = map.getLong(WearTransferProtocol.KEY_DURATION_MS),
        sampleRate = map.getInt(WearTransferProtocol.KEY_SAMPLE_RATE),
        isFinal = map.getBoolean(WearTransferProtocol.KEY_IS_FINAL),
        sha256 = claimedHash,
        container = required(map, WearTransferProtocol.KEY_CONTAINER),
        codec = required(map, WearTransferProtocol.KEY_CODEC),
        contentType = required(map, WearTransferProtocol.KEY_CONTENT_TYPE),
        file = temporary,
      ),
    )
  }

  fun pending(): List<Map<String, Any>> = inbox.pending().map { recording ->
    mapOf(
      "recordingId" to recording.recordingId,
      "sessionId" to recording.sessionId,
      "sourceId" to recording.sourceId,
      "watchDeviceId" to recording.watchDeviceId,
      "watchName" to recording.watchName,
      "sequence" to recording.sequence,
      "sessionStartedAtMs" to recording.sessionStartedAtMs,
      "startedAtMs" to recording.startedAtMs,
      "monotonicOffsetMs" to recording.monotonicOffsetMs,
      "durationMs" to recording.durationMs,
      "sampleRate" to recording.sampleRate,
      "isFinal" to recording.isFinal,
      "sha256" to recording.sha256,
      "container" to recording.container,
      "codec" to recording.codec,
      "contentType" to recording.contentType,
      "bytes" to recording.file.readBytes(),
    )
  }

  fun markImported(recordingId: String) = inbox.markImported(recordingId)

  /** Persists the proof in Data Layer before permitting deletion of the phone copy. */
  fun acknowledge(recordingId: String, receipt: Map<*, *>): Boolean {
    val inboxState = inbox.state(recordingId)
    // Most chunks originate on this phone or desktop and have no Wear inbox
    // row. Only an existing, not-yet-imported Wear row blocks release.
    if (inboxState == null || inboxState == WearInboxStore.STATE_ACKNOWLEDGED) return true
    if (inboxState != WearInboxStore.STATE_IMPORTED) return false
    val state = receipt["state"] as? String
    require(state == "transcribed" || state == "silent")
    val serverChunkId = nonEmpty(receipt, "chunkId")
    val persistedAt = nonEmpty(receipt, "persistedAt")
    val deletedAt = nonEmpty(receipt, "serverAudioDeletedAt")
    val transcriptSha256 = nonEmpty(receipt, "transcriptSha256")
    Instant.parse(persistedAt)
    Instant.parse(deletedAt)
    val request = PutDataMapRequest.create(WearTransferProtocol.ACK_PATH_PREFIX + recordingId).apply {
      dataMap.putInt(WearTransferProtocol.KEY_VERSION, WearTransferProtocol.VERSION)
      dataMap.putString(WearTransferProtocol.KEY_RECORDING_ID, recordingId)
      dataMap.putString(WearTransferProtocol.KEY_RECEIPT_STATE, state)
      dataMap.putString(WearTransferProtocol.KEY_SERVER_CHUNK_ID, serverChunkId)
      dataMap.putString(WearTransferProtocol.KEY_PERSISTED_AT, persistedAt)
      dataMap.putString(
        WearTransferProtocol.KEY_SERVER_AUDIO_DELETED_AT,
        deletedAt,
      )
      dataMap.putString(WearTransferProtocol.KEY_TRANSCRIPT_SHA256, transcriptSha256)
    }.asPutDataRequest().setUrgent()
    Tasks.await(Wearable.getDataClient(context).putDataItem(request))
    inbox.markAcknowledged(recordingId)
    return true
  }

  private fun required(map: DataMap, key: String): String =
    map.getString(key)?.takeIf { it.isNotBlank() } ?: error("Missing Wear field $key")

  private fun nonEmpty(receipt: Map<*, *>, key: String): String =
    (receipt[key] as? String)?.takeIf { it.isNotBlank() }
      ?: error("Missing terminal receipt field $key")

  companion object {
    @Volatile private var instance: PhoneWearTransferManager? = null
    fun get(context: Context): PhoneWearTransferManager = instance ?: synchronized(this) {
      instance ?: PhoneWearTransferManager(context.applicationContext).also { instance = it }
    }
  }
}
