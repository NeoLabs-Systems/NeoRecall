package systems.neolabs.neorecall

import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.WearableListenerService
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol

class PhoneWearDataListenerService : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    events.forEach { event ->
      if (event.type != DataEvent.TYPE_CHANGED) return@forEach
      if (!event.dataItem.uri.path.orEmpty().startsWith(WearTransferProtocol.RECORDING_PATH_PREFIX)) return@forEach
      val channel = (application as NeoRecallApplication).backgroundCaptureChannel
      channel.notifyWatchTransferStarted()
      val transfer = runCatching { PhoneWearTransferManager.get(this).receive(event.dataItem) }
      transfer
        .onSuccess { inserted ->
          if (inserted) channel.notifyWatchRecordingAvailable()
        }
      channel.notifyWatchTransferFinished(transfer.exceptionOrNull()?.message)
    }
  }
}
