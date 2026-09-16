package systems.neolabs.neorecall.wear.sync

import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import systems.neolabs.neorecall.wear.digest.WatchDigestStore
import systems.neolabs.neorecall.wear.protocol.WearDigestProtocol
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import systems.neolabs.neorecall.wear.surfaces.WatchSurfaces
import java.time.Instant

/**
 * Everything the phone sends the watch, in one listener.
 *
 * Two unrelated things arrive here: the terminal receipts that release held
 * audio, and the day digest the watch displays. They are kept in one service
 * because the Data Layer delivers them through one callback, and kept strictly
 * apart inside it because only the first is allowed to delete a recording.
 */
class WatchDataListenerService : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    events.forEach { event ->
      if (event.type != DataEvent.TYPE_CHANGED) return@forEach
      val item = event.dataItem
      val path = item.uri.path.orEmpty()
      if (path == WearDigestProtocol.DIGEST_PATH) {
        acceptDigest(DataMapItem.fromDataItem(item).dataMap)
        return@forEach
      }
      if (!path.startsWith(WearTransferProtocol.ACK_PATH_PREFIX)) return@forEach
      val map = DataMapItem.fromDataItem(item).dataMap
      val recordingId = map.getString(WearTransferProtocol.KEY_RECORDING_ID).orEmpty()
      if (recordingId.isEmpty() || !hasTerminalProof(map)) return@forEach
      if (WatchRecordingStore.get(this).acknowledge(recordingId)) {
        // The clip is gone from the watch the moment the receipt proves it is
        // safe. Everything that counts held clips has to be told now, or the
        // wrist keeps showing a backlog that no longer exists.
        WatchSurfaces.refreshAll(this)
        Wearable.getDataClient(this)
          .deleteDataItems(item.uri)
        val localNodeId = runCatching {
          Tasks.await(Wearable.getNodeClient(this).localNode).id
        }.getOrNull()
        if (localNodeId == null) return@forEach
        Wearable.getDataClient(this).deleteDataItems(
          Uri.Builder()
            .scheme("wear")
            .authority(localNodeId)
            .path(WearTransferProtocol.RECORDING_PATH_PREFIX + recordingId)
            .build(),
        )
      }
    }
  }

  /**
   * Stores a digest and redraws everything that shows one.
   *
   * A digest is display only: it is never allowed to influence what the watch
   * holds or releases, so an unreadable or future-versioned one is simply
   * ignored and the previous day stays on screen.
   */
  private fun acceptDigest(map: com.google.android.gms.wearable.DataMap) {
    if (map.getInt(WearDigestProtocol.KEY_VERSION) != WearDigestProtocol.VERSION) return
    val payload = map.getString(WearDigestProtocol.KEY_PAYLOAD).orEmpty()
    if (payload.isBlank()) return
    val publishedAt = map.getLong(WearDigestProtocol.KEY_PUBLISHED_AT_MS)
      .takeIf { it > 0L } ?: System.currentTimeMillis()
    if (WatchDigestStore.publish(this, payload, publishedAt)) {
      WatchSurfaces.refreshAll(this)
    }
  }

  private fun hasTerminalProof(map: com.google.android.gms.wearable.DataMap): Boolean {
    val state = map.getString(WearTransferProtocol.KEY_RECEIPT_STATE)
    if (state != "transcribed" && state != "silent") return false
    val persisted = map.getString(WearTransferProtocol.KEY_PERSISTED_AT).orEmpty()
    val deleted = map.getString(WearTransferProtocol.KEY_SERVER_AUDIO_DELETED_AT).orEmpty()
    return runCatching { Instant.parse(persisted) }.isSuccess &&
      runCatching { Instant.parse(deleted) }.isSuccess &&
      map.getString(WearTransferProtocol.KEY_SERVER_CHUNK_ID).orEmpty().isNotBlank() &&
      map.getString(WearTransferProtocol.KEY_TRANSCRIPT_SHA256).orEmpty().isNotBlank()
  }
}
