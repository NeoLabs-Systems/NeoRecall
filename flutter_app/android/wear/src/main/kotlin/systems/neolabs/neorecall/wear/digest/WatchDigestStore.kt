package systems.neolabs.neorecall.wear.digest

import android.content.Context
import android.content.SharedPreferences

/**
 * The last digest the phone sent, kept across watch reboots.
 *
 * Wear tiles and complications are woken by the system without the app, and a
 * disconnected watch may go a whole day without a fresh publish. Holding the
 * newest payload on disk is what lets every surface answer immediately, and
 * lets the UI be honest about how old the answer is.
 */
object WatchDigestStore {
  private const val PREFS = "neorecall_watch_digest"
  private const val KEY_PAYLOAD = "payload"
  private const val KEY_RECEIVED_AT = "receivedAt"

  @Volatile private var cachedPayload: String? = null

  @Volatile private var cached: WatchDigest = WatchDigest.empty

  private fun prefs(context: Context): SharedPreferences =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  /**
   * Parsed once per payload: home, digest, two tiles and two complications can
   * all ask within the same second, and each would otherwise re-parse the JSON.
   */
  fun digest(context: Context): WatchDigest {
    val store = prefs(context)
    val payload = store.getString(KEY_PAYLOAD, null)
    val receivedAt = store.getLong(KEY_RECEIVED_AT, 0L)
    val current = cached
    if (payload == cachedPayload && current.receivedAtMs == receivedAt) return current
    return WatchDigest.parse(payload, receivedAt).also {
      cachedPayload = payload
      cached = it
    }
  }

  /** Returns true when the payload actually differs from the one already held. */
  fun publish(context: Context, payload: String, receivedAtMs: Long): Boolean {
    val store = prefs(context)
    if (store.getString(KEY_PAYLOAD, null) == payload) return false
    // commit(), not apply(): tiles and complications are refreshed immediately
    // after this returns, in processes that read straight from disk.
    store.edit()
      .putString(KEY_PAYLOAD, payload)
      .putLong(KEY_RECEIVED_AT, receivedAtMs)
      .commit()
    cachedPayload = null
    return true
  }
}
