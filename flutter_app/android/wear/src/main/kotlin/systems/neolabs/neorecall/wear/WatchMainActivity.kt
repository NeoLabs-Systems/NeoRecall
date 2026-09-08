package systems.neolabs.neorecall.wear

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
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
 *
 * The screen itself starts nothing. Capture is the Record tile's, and the tile
 * routes its start through this Activity only because Android refuses a
 * microphone foreground service to a process with no attached UI.
 */
class WatchMainActivity : ComponentActivity() {
  private val repository by lazy { WatchStateRepository.get(this) }
  private val permissionPrefs by lazy {
    getSharedPreferences(PERMISSION_PREFS, Context.MODE_PRIVATE)
  }

  private val stateReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) = repository.refresh()
  }

  private val microphonePermissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestPermission(),
  ) { granted ->
    repository.refresh()
    if (granted) {
      requestNotificationPermissionIfNeeded()
      startRecording()
    } else {
      // The optimistic flip made when the start arrived has to be undone, or a
      // refused prompt leaves the screen claiming to be recording.
      repository.setRecordingOptimistically(false)
      if (!shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
        openAppSettings()
      }
    }
  }

  private val notificationPermissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestPermission(),
  ) { repository.refresh() }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    ContextCompat.registerReceiver(
      this,
      stateReceiver,
      IntentFilter(WatchRecordingService.ACTION_STATE_CHANGED),
      ContextCompat.RECEIVER_NOT_EXPORTED,
    )
    setContent {
      val state by repository.state.collectAsStateWithLifecycle()
      NeoRecallWatchApp(state = state)
    }
    WatchSyncManager.get(this).syncPending(includeEnqueued = true)
    consumeStartRequest(intent)
  }

  override fun onDestroy() {
    unregisterReceiver(stateReceiver)
    super.onDestroy()
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
    beginRecording()
  }

  override fun onStart() {
    super.onStart()
    // Everything on screen stays live for as long as the screen is: the phone
    // link is otherwise only ever read here, which is what made a watch that had
    // been open for a minute show a link state from whenever it was opened.
    repository.startWatching()
    if (!hasMicrophonePermission() && !permissionPrefs.getBoolean(KEY_PROMPTED_MICROPHONE, false)) {
      requestMicrophonePermission()
    }
  }

  override fun onStop() {
    repository.stopWatching()
    super.onStop()
  }

  /**
   * Starts capture on the tile's behalf, asking for the microphone first when it
   * has never been granted. Stopping is the tile's own, and never passes here.
   */
  private fun beginRecording() {
    if (hasMicrophonePermission()) {
      requestNotificationPermissionIfNeeded()
      startRecording()
      return
    }
    requestMicrophonePermission()
  }

  /**
   * Asks for the microphone on its own.
   *
   * Wear OS often drops [ActivityResultContracts.RequestMultiplePermissions]
   * without showing a dialog. Asking for one permission, then opening the app
   * settings page when the system will not ask again, is what keeps the tile's
   * start from failing silently on a watch that has never granted the
   * microphone.
   */
  private fun requestMicrophonePermission() {
    if (hasMicrophonePermission()) return
    val alreadyAsked = permissionPrefs.getBoolean(KEY_PROMPTED_MICROPHONE, false)
    permissionPrefs.edit().putBoolean(KEY_PROMPTED_MICROPHONE, true).apply()
    if (alreadyAsked && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)) {
      openAppSettings()
      return
    }
    microphonePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
  }

  private fun requestNotificationPermissionIfNeeded() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
      PackageManager.PERMISSION_GRANTED
    ) {
      return
    }
    notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
  }

  private fun openAppSettings() {
    startActivity(
      Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        .setData(Uri.fromParts("package", packageName, null)),
    )
  }

  private fun startRecording() {
    repository.setRecordingOptimistically(true)
    ContextCompat.startForegroundService(
      this,
      Intent(this, WatchRecordingService::class.java)
        .setAction(WatchRecordingService.ACTION_START),
    )
  }

  companion object {
    /** Set by the Record tile, which cannot start a microphone service itself. */
    const val EXTRA_START_ON_OPEN = "systems.neolabs.neorecall.wear.START_ON_OPEN"
    private const val PERMISSION_PREFS = "neorecall_watch_permissions"
    private const val KEY_PROMPTED_MICROPHONE = "prompted_microphone"
  }

  private fun hasMicrophonePermission(): Boolean = ContextCompat.checkSelfPermission(
    this,
    Manifest.permission.RECORD_AUDIO,
  ) == PackageManager.PERMISSION_GRANTED
}
