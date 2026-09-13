package systems.neolabs.neorecall

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol

class PhoneWearDataListenerService : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    val items = events.mapNotNull { event ->
      if (event.type != DataEvent.TYPE_CHANGED) return@mapNotNull null
      if (!event.dataItem.uri.path.orEmpty().startsWith(WearTransferProtocol.RECORDING_PATH_PREFIX)) {
        return@mapNotNull null
      }
      event.dataItem.freeze()
    }
    if (items.isEmpty()) return
    val channel = (application as NeoRecallApplication).backgroundCaptureChannel
    PhoneWearTransferManager.get(this).receiveAll(
      items,
      onStarted = { channel.notifyWatchTransferStarted() },
      onInserted = { channel.notifyWatchRecordingAvailable() },
      onFinished = { error -> channel.notifyWatchTransferFinished(error) },
    )
  }
}
