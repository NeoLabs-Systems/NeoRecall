package systems.neolabs.neorecall.wear.sync

import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import java.time.Instant

class WatchDataListenerService : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    events.forEach { event ->
      if (event.type != DataEvent.TYPE_CHANGED) return@forEach
      val item = event.dataItem
      if (!item.uri.path.orEmpty().startsWith(WearTransferProtocol.ACK_PATH_PREFIX)) return@forEach
      val map = DataMapItem.fromDataItem(item).dataMap
      val recordingId = map.getString(WearTransferProtocol.KEY_RECORDING_ID).orEmpty()
      if (recordingId.isEmpty() || !hasTerminalProof(map)) return@forEach
      if (WatchRecordingStore.get(this).acknowledge(recordingId)) {
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
