package systems.neolabs.neorecall.wear.state

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
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
 *
 * Nothing here waits to be asked. Recording state is pushed by whichever part of
 * the app wrote it, the phone link is pushed by Play services and swept on a
 * slow timer while a screen is actually on, and an optimistic tap expires by
 * itself. A screen that is open is therefore never showing a state the watch
 * left behind minutes ago.
 */
class WatchStateRepository private constructor(private val context: Context) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val refreshLock = Mutex()
  private val _state = MutableStateFlow(WatchUiState())
  @Volatile private var pendingRecording: Boolean? = null
  @Volatile private var pendingRecordingSinceMs = 0L

  /** How many screens are currently on. Guarded by [watchLock], never negative. */
  private val watchLock = Any()
  private var watchers = 0
  private var sweep: Job? = null

  /**
   * Held as a field on purpose: [SharedPreferences] keeps only a weak reference
   * to its listeners, so a local one is collected and the screen goes quiet
   * again a few minutes later.
   */
  @Suppress("unused")
  private val recordingWatcher: SharedPreferences.OnSharedPreferenceChangeListener =
    WatchRecordingService.observeState(context) { refresh() }

  private val capabilityListener = CapabilityClient.OnCapabilityChangedListener {
    scope.launch { refreshPhoneLink() }
  }

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
        val recorded = WatchRecordingService.isRecording(context)
        val recording = resolveRecording(recorded)
        _state.update { current ->
          current.copy(
            loaded = true,
            recording = recording,
            recordingStartedAtMs = if (recording) {
              WatchRecordingService.sessionStartedAt(context)
                ?: current.recordingStartedAtMs
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
      if (includePhoneLink) refreshPhoneLink()
    }
  }

  /**
   * Keeps this state live for as long as a screen is showing it.
   *
   * Balanced by [stopWatching]. Play services pushes capability changes, which
   * covers the phone app being installed or uninstalled; a Bluetooth link simply
   * going out of range is not announced, so a slow sweep covers that — cheap,
   * because it only ever runs while the display is already on.
   */
  fun startWatching() {
    synchronized(watchLock) {
      watchers += 1
      if (watchers > 1) return@synchronized
      runCatching {
        Wearable.getCapabilityClient(context)
          .addListener(capabilityListener, WearDigestProtocol.CAPABILITY_PHONE_APP)
      }
      sweep = scope.launch {
        while (isActive) {
          delay(SWEEP_INTERVAL_MS)
          refresh(includePhoneLink = true)
        }
      }
    }
    refresh(includePhoneLink = true)
  }

  /** Undoes one [startWatching]. */
  fun stopWatching() {
    synchronized(watchLock) {
      if (watchers == 0) return
      watchers -= 1
      if (watchers > 0) return
      sweep?.cancel()
      sweep = null
      runCatching { Wearable.getCapabilityClient(context).removeListener(capabilityListener) }
    }
  }

  /**
   * Reflects a tap before the service has had time to report it.
   *
   * The service announces its real state a moment later and overwrites this;
   * without it the button would sit unchanged for as long as the microphone
   * takes to open, which reads as a missed tap. The deadline below is what
   * happens when that announcement never comes.
   */
  fun setRecordingOptimistically(recording: Boolean) {
    pendingRecording = recording
    pendingRecordingSinceMs = SystemClock.elapsedRealtime()
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
    scope.launch {
      delay(OPTIMISTIC_GRACE_MS)
      refresh()
    }
  }

  /**
   * A tap updates the button before the service has written its preference.
   * Keep that flip until the service agrees, otherwise a refresh that ran a
   * moment too early snaps the control back to idle while the microphone is
   * already open.
   *
   * It is kept for a few seconds and no longer. A start the system refused —
   * a revoked microphone, a foreground service it declined to launch — would
   * otherwise leave the control claiming to be recording for the rest of the
   * process's life, which is the one wrong answer this screen can give.
   */
  private fun resolveRecording(recorded: Boolean): Boolean {
    val pending = pendingRecording ?: return recorded
    if (pending == recorded) {
      pendingRecording = null
      return recorded
    }
    if (SystemClock.elapsedRealtime() - pendingRecordingSinceMs >= OPTIMISTIC_GRACE_MS) {
      pendingRecording = null
      return recorded
    }
    return pending
  }

  private fun refreshPhoneLink() {
    val link = readPhoneLink()
    _state.update { it.copy(phone = link) }
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
    /** How long a tap is allowed to speak for the service before it must prove itself. */
    private const val OPTIMISTIC_GRACE_MS = 6_000L

    /** How often an open screen re-checks the parts nothing announces. */
    private const val SWEEP_INTERVAL_MS = 20_000L

    @Volatile private var instance: WatchStateRepository? = null

    fun get(context: Context): WatchStateRepository = instance ?: synchronized(this) {
      instance ?: WatchStateRepository(context.applicationContext).also { instance = it }
    }
  }
}
