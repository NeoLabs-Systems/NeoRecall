package systems.neolabs.neorecall.wear

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.state.WatchStateRepository
import systems.neolabs.neorecall.wear.sync.WatchSyncManager
import systems.neolabs.neorecall.wear.ui.NeoRecallWatchApp

/**
 * The watch app's single Android entry point.
 *
 * Owns exactly three things the composition cannot: the microphone permission
 * prompt, the broadcast the recording service uses to report itself, and the
 * commands sent to that service. Everything else is state and Compose.
 */
class WatchMainActivity : ComponentActivity() {
  private val repository by lazy { WatchStateRepository.get(this) }

  private val stateReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) = repository.refresh()
  }

  private val permissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestMultiplePermissions(),
  ) { granted ->
    if (granted[Manifest.permission.RECORD_AUDIO] == true) {
      startRecording()
    } else {
      // The optimistic flip made on tap has to be undone, or a refused prompt
      // leaves a button claiming to be recording.
      repository.setRecordingOptimistically(false)
      repository.refresh()
    }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    setContent {
      val state by repository.state.collectAsStateWithLifecycle()
      NeoRecallWatchApp(state = state, onToggleRecording = ::toggleRecording)
    }
    WatchSyncManager.get(this).syncPending(includeEnqueued = true)
    consumeStartRequest(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    consumeStartRequest(intent)
  }

  /**
   * Honours the Record tile's start, once.
   *
   * The extra is cleared before acting so a configuration change, or the
   * activity being returned to from the recents list, cannot replay it and
   * restart a session the wearer has since stopped.
   */
  private fun consumeStartRequest(intent: Intent?) {
    if (intent?.getBooleanExtra(EXTRA_START_ON_OPEN, false) != true) return
    intent.removeExtra(EXTRA_START_ON_OPEN)
    if (WatchRecordingService.isRecording(this)) return
    toggleRecording()
  }

  override fun onStart() {
    super.onStart()
    ContextCompat.registerReceiver(
      this,
      stateReceiver,
      IntentFilter(WatchRecordingService.ACTION_STATE_CHANGED),
      ContextCompat.RECEIVER_NOT_EXPORTED,
    )
    repository.refresh(includePhoneLink = true)
  }

  override fun onStop() {
    unregisterReceiver(stateReceiver)
    super.onStop()
  }

  private fun toggleRecording() {
    if (WatchRecordingService.isRecording(this)) {
      repository.setRecordingOptimistically(false)
      startService(
        Intent(this, WatchRecordingService::class.java)
          .setAction(WatchRecordingService.ACTION_STOP),
      )
      repository.refresh()
      return
    }
    if (hasMicrophonePermission()) {
      repository.setRecordingOptimistically(true)
      startRecording()
      return
    }
    permissionLauncher.launch(
      buildList {
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          add(Manifest.permission.POST_NOTIFICATIONS)
        }
      }.toTypedArray(),
    )
  }

  private fun startRecording() {
    repository.setRecordingOptimistically(true)
    ContextCompat.startForegroundService(
      this,
      Intent(this, WatchRecordingService::class.java)
        .setAction(WatchRecordingService.ACTION_START),
    )
    repository.refresh()
  }

  companion object {
    /** Set by the Record tile, which cannot start a microphone service itself. */
    const val EXTRA_START_ON_OPEN = "systems.neolabs.neorecall.wear.START_ON_OPEN"
  }

  private fun hasMicrophonePermission(): Boolean = ContextCompat.checkSelfPermission(
    this,
    Manifest.permission.RECORD_AUDIO,
  ) == android.content.pm.PackageManager.PERMISSION_GRANTED
}
