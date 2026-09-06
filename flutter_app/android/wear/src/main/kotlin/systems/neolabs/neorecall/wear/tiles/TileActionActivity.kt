package systems.neolabs.neorecall.wear.tiles

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.state.WatchStateRepository

/**
 * Ends capture from a tile tap, and shows nothing while it does.
 *
 * A tile cannot start a service itself, only launch an Activity, so this is the
 * shortest legal path from the tap to the stop. It finishes before it would
 * ever draw, which is what keeps the tile button feeling like a button rather
 * than a shortcut into the app.
 *
 * Starting deliberately does not come through here: Android refuses a
 * microphone foreground service to a process with no attached UI, so the tile's
 * START opens [systems.neolabs.neorecall.wear.WatchMainActivity] instead. This
 * is the same split the phone's record widget makes.
 */
class TileActionActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    WatchStateRepository.get(this).setRecordingOptimistically(false)
    startService(
      Intent(this, WatchRecordingService::class.java)
        .setAction(WatchRecordingService.ACTION_STOP),
    )
    finish()
  }
}
