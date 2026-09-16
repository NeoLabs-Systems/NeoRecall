package systems.neolabs.neorecall.wear.complications

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import systems.neolabs.neorecall.wear.WatchMainActivity

/**
 * Every NeoRecall complication opens the app, and none of them act on their own.
 *
 * A watch face is read at a glance and pressed by accident; a complication that
 * started or stopped the microphone from a tap the wearer did not mean to make
 * would be the worst possible failure on this surface. The tile is where the
 * one-gesture control belongs, because a tile is looked at before it is touched.
 */
internal fun openAppIntent(context: Context, requestCode: Int): PendingIntent =
  PendingIntent.getActivity(
    context,
    requestCode,
    Intent(context, WatchMainActivity::class.java)
      .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
  )
