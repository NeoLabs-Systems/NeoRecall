package systems.neolabs.neorecall

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restores the always-on host after a device restart.
 *
 * A reboot ends every process, so a paired wearable would otherwise stay
 * unlinked until the user next opened the app — recordings made on the device in
 * the meantime would not sync. Only holds that may legally start from the
 * background are restored; [BackgroundCaptureService.restoreAfterBoot] records
 * the ones that could not so the app can say so instead of failing silently.
 */
class BootCompletedReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    // Deliberately not ACTION_LOCKED_BOOT_COMPLETED: the host's state lives in
    // credential-encrypted storage, which is unreadable before the first unlock.
    when (intent.action) {
      Intent.ACTION_BOOT_COMPLETED,
      Intent.ACTION_MY_PACKAGE_REPLACED,
      "android.intent.action.QUICKBOOT_POWERON",
      -> BackgroundCaptureService.restoreAfterBoot(context.applicationContext)
    }
  }
}
