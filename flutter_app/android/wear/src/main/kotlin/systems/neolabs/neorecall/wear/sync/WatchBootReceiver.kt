package systems.neolabs.neorecall.wear.sync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import systems.neolabs.neorecall.wear.recording.WatchRecordingService

/** Boot may resume transfer, but Android does not permit starting a microphone FGS here. */
class WatchBootReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
      WatchRecordingService.recoverAfterBoot(context)
      WatchSyncManager.get(context).syncPending(includeEnqueued = true)
    }
  }
}
