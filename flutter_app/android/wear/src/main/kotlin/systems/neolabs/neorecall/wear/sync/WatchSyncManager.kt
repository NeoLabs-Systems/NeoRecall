package systems.neolabs.neorecall.wear.sync

import android.content.Context
import android.os.Build
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import systems.neolabs.neorecall.wear.protocol.WearTransferProtocol
import systems.neolabs.neorecall.wear.storage.StoredWatchChunk
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Publishes durable recordings to the phone without treating Data Layer as storage. */
class WatchSyncManager private constructor(private val context: Context) {
  private val store = WatchRecordingStore.get(context)
  private val executor = Executors.newSingleThreadExecutor()
  private val syncing = AtomicBoolean(false)
  private val requested = AtomicBoolean(false)
  private val republishRequested = AtomicBoolean(false)

  fun syncPending(includeEnqueued: Boolean = false) {
    requested.set(true)
    if (includeEnqueued) republishRequested.set(true)
    if (!syncing.compareAndSet(false, true)) return
    executor.execute {
      try {
        while (requested.getAndSet(false)) {
          val republish = republishRequested.getAndSet(false)
          store.transferCandidates(republish).forEach { chunk ->
            // One disconnected transfer must not prevent later calls from
            // rescheduling the durable backlog.
            runCatching { publish(chunk) }
          }
        }
      } finally {
        syncing.set(false)
        // Close the small race between the loop's last check and clearing the
        // running flag without losing the final chunk of a stopped session.
        if (requested.get()) syncPending(republishRequested.get())
      }
    }
  }

  private fun publish(chunk: StoredWatchChunk) {
    val request = PutDataMapRequest.create(
      WearTransferProtocol.RECORDING_PATH_PREFIX + chunk.recordingId,
    ).apply {
      dataMap.putInt(WearTransferProtocol.KEY_VERSION, WearTransferProtocol.VERSION)
      dataMap.putAsset(WearTransferProtocol.KEY_AUDIO, Asset.createFromBytes(chunk.file.readBytes()))
      dataMap.putString(WearTransferProtocol.KEY_RECORDING_ID, chunk.recordingId)
      dataMap.putString(WearTransferProtocol.KEY_SESSION_ID, chunk.sessionId)
      dataMap.putString(WearTransferProtocol.KEY_SOURCE_ID, chunk.sourceId)
      dataMap.putString(WearTransferProtocol.KEY_WATCH_DEVICE_ID, store.stableDeviceId())
      dataMap.putString(WearTransferProtocol.KEY_WATCH_NAME, Build.MODEL)
      dataMap.putInt(WearTransferProtocol.KEY_SEQUENCE, chunk.sequence)
      dataMap.putLong(WearTransferProtocol.KEY_SESSION_STARTED_AT_MS, chunk.sessionStartedAtMs)
      dataMap.putLong(WearTransferProtocol.KEY_STARTED_AT_MS, chunk.startedAtMs)
      dataMap.putLong(WearTransferProtocol.KEY_MONOTONIC_OFFSET_MS, chunk.monotonicOffsetMs)
      dataMap.putLong(WearTransferProtocol.KEY_DURATION_MS, chunk.durationMs)
      dataMap.putInt(WearTransferProtocol.KEY_SAMPLE_RATE, WearTransferProtocol.SAMPLE_RATE)
      dataMap.putBoolean(WearTransferProtocol.KEY_IS_FINAL, chunk.isFinal)
      dataMap.putString(WearTransferProtocol.KEY_SHA256, chunk.sha256)
      dataMap.putString(WearTransferProtocol.KEY_CONTAINER, WearTransferProtocol.CONTAINER)
      dataMap.putString(WearTransferProtocol.KEY_CODEC, WearTransferProtocol.CODEC)
      dataMap.putString(WearTransferProtocol.KEY_CONTENT_TYPE, WearTransferProtocol.CONTENT_TYPE)
    }.asPutDataRequest().setUrgent()
    Tasks.await(Wearable.getDataClient(context).putDataItem(request))
    store.markEnqueued(chunk.recordingId)
  }

  companion object {
    @Volatile private var instance: WatchSyncManager? = null
    fun get(context: Context): WatchSyncManager = instance ?: synchronized(this) {
      instance ?: WatchSyncManager(context.applicationContext).also { instance = it }
    }
  }
}
