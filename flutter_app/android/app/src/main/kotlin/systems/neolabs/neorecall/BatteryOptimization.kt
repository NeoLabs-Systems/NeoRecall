package systems.neolabs.neorecall

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/** Android's authoritative Doze allowlist state and user-facing request flow. */
internal object BatteryOptimization {
  fun isExempt(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
    val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    return power.isIgnoringBatteryOptimizations(context.packageName)
  }

  /**
   * Opens Android's normal confirmation dialog for this package.
   *
   * Some vendor builds remove that activity. Their safe fallback is Android's
   * battery-optimization list, not the generic app-details screen that cannot
   * grant this exemption directly.
   */
  fun requestExemption(context: Context) {
    if (isExempt(context)) return
    val direct = Intent(
      Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
      Uri.parse("package:${context.packageName}"),
    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
      context.startActivity(direct)
    } catch (_: ActivityNotFoundException) {
      context.startActivity(
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
          .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
      )
    }
  }
}
