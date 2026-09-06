package systems.neolabs.neorecall.wear.state

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import systems.neolabs.neorecall.wear.digest.WatchDigestStore
import systems.neolabs.neorecall.wear.protocol.WearDigestProtocol
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore

/**
 * The one place the watch UI reads state from.
 *
 * Recording state lives in preferences, held audio in SQLite and the phone link
 * behind a blocking Play services call — three sources on three different
 * threads. Funnelling them into one flow keeps every screen off the main thread
 * without each screen having to know that.
 */
class WatchStateRepository private constructor(private val context: Context) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val refreshLock = Mutex()
  private val _state = MutableStateFlow(WatchUiState())

  val state: StateFlow<WatchUiState> = _state.asStateFlow()

  /**
   * Re-reads everything cheap immediately, and the phone link only when asked.
   *
   * The link check is a blocking Play services round trip, so a broadcast that
   * fires once per recorded chunk must not queue one every thirty seconds.
   */
  fun refresh(includePhoneLink: Boolean = false) {
    scope.launch {
      refreshLock.withLock {
        val store = WatchRecordingStore.get(context)
        val recording = WatchRecordingService.isRecording(context)
        _state.update { current ->
          current.copy(
            loaded = true,
            recording = recording,
            recordingStartedAtMs = if (recording) {
              WatchRecordingService.sessionStartedAt(context)
            } else {
              null
            },
            micPermitted = ContextCompat.checkSelfPermission(
              context,
              Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED,
            heldChunks = runCatching { store.pendingCount() }.getOrDefault(current.heldChunks),
            digest = WatchDigestStore.digest(context),
          )
        }
      }
      if (includePhoneLink) {
        val link = readPhoneLink()
        _state.update { it.copy(phone = link) }
      }
    }
  }

  /**
   * Reflects a tap before the service has had time to report it.
   *
   * The service broadcasts its real state a moment later and overwrites this;
   * without it the button would sit unchanged for as long as the microphone
   * takes to open, which reads as a missed tap.
   */
  fun setRecordingOptimistically(recording: Boolean) {
    _state.update {
      it.copy(
        recording = recording,
        recordingStartedAtMs = if (recording) {
          it.recordingStartedAtMs ?: System.currentTimeMillis()
        } else {
          null
        },
      )
    }
  }

  private fun readPhoneLink(): PhoneLink = runCatching {
    val capability = Tasks.await(
      Wearable.getCapabilityClient(context).getCapability(
        WearDigestProtocol.CAPABILITY_PHONE_APP,
        CapabilityClient.FILTER_REACHABLE,
      ),
    )
    if (capability.nodes.any { it.isNearby }) return@runCatching PhoneLink.CONNECTED
    val connected = Tasks.await(Wearable.getNodeClient(context).connectedNodes)
    when {
      connected.isEmpty() -> PhoneLink.DISCONNECTED
      capability.nodes.isEmpty() -> PhoneLink.COMPANION_MISSING
      else -> PhoneLink.CONNECTED
    }
  }.getOrDefault(PhoneLink.UNKNOWN)

  companion object {
    @Volatile private var instance: WatchStateRepository? = null

    fun get(context: Context): WatchStateRepository = instance ?: synchronized(this) {
      instance ?: WatchStateRepository(context.applicationContext).also { instance = it }
    }
  }
}
