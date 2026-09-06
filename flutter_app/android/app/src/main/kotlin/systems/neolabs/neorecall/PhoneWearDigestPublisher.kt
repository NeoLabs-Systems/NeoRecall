package systems.neolabs.neorecall

import android.content.Context
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import systems.neolabs.neorecall.wear.protocol.WearDigestProtocol
import java.util.concurrent.Executors

/**
 * Publishes the day to a paired watch, and reports what is paired.
 *
 * Strictly one-directional and strictly cosmetic: the digest is what the watch
 * displays, never what it acts on. Nothing here can release recorded audio —
 * that stays entirely in [PhoneWearTransferManager], behind a terminal receipt.
 */
class PhoneWearDigestPublisher private constructor(private val context: Context) {
  private val executor = Executors.newSingleThreadExecutor()

  @Volatile private var lastPayload: String? = null

  /**
   * Sends a digest, unless the watch already has this exact one.
   *
   * Data Layer puts are queued for a watch that is out of range and delivered
   * when it returns, so a failure here is a real failure rather than a
   * disconnection, and the cached payload is cleared so the next publish
   * genuinely retries.
   */
  fun publish(payload: String, force: Boolean = false, onError: (String?) -> Unit) {
    if (!force && payload == lastPayload) {
      onError(null)
      return
    }
    if (payload.toByteArray(Charsets.UTF_8).size > WearDigestProtocol.MAX_PAYLOAD_BYTES) {
      onError("Watch digest exceeds the ${WearDigestProtocol.MAX_PAYLOAD_BYTES} byte budget.")
      return
    }
    lastPayload = payload
    executor.execute {
      val outcome = runCatching {
        val request = PutDataMapRequest.create(WearDigestProtocol.DIGEST_PATH).apply {
          dataMap.putInt(WearDigestProtocol.KEY_VERSION, WearDigestProtocol.VERSION)
          dataMap.putString(WearDigestProtocol.KEY_PAYLOAD, payload)
          dataMap.putLong(
            WearDigestProtocol.KEY_PUBLISHED_AT_MS,
            System.currentTimeMillis(),
          )
        }.asPutDataRequest().setUrgent()
        Tasks.await(Wearable.getDataClient(context).putDataItem(request))
      }
      if (outcome.isFailure) lastPayload = null
      onError(outcome.exceptionOrNull()?.message)
    }
  }

  /**
   * The watches this phone is paired with, and whether NeoRecall is on them.
   *
   * `connectedNodes` is every paired device currently reachable; the capability
   * query narrows that to the ones actually running the watch app. The
   * difference between the two lists is exactly what a setup screen needs in
   * order to say "paired, but not installed" rather than "no watch found".
   */
  fun nodes(onResult: (List<Map<String, Any?>>) -> Unit) {
    executor.execute { onResult(readNodes()) }
  }

  private fun readNodes(): List<Map<String, Any?>> {
    val connected = runCatching {
      Tasks.await(Wearable.getNodeClient(context).connectedNodes)
    }.getOrDefault(emptyList())
    val installed = runCatching {
      Tasks.await(
        Wearable.getCapabilityClient(context).getCapability(
          WearDigestProtocol.CAPABILITY_WATCH_APP,
          CapabilityClient.FILTER_ALL,
        ),
      ).nodes.map { it.id }.toSet()
    }.getOrDefault(emptySet())
    return connected.map { node ->
      mapOf(
        "id" to node.id,
        "name" to node.displayName,
        "nearby" to node.isNearby,
        "installed" to installed.contains(node.id),
      )
    }
  }

  companion object {
    @Volatile private var instance: PhoneWearDigestPublisher? = null

    fun get(context: Context): PhoneWearDigestPublisher = instance ?: synchronized(this) {
      instance ?: PhoneWearDigestPublisher(context.applicationContext).also { instance = it }
    }
  }
}
