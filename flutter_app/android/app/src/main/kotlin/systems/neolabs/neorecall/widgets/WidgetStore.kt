package systems.neolabs.neorecall.widgets

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * Everything the widgets read and write, in one place.
 *
 * Widgets are woken by the launcher in whatever process happens to be alive, so
 * this is the only durable channel between them and the app. Three things live
 * here: the published snapshot, per-widget configuration, and the queue of taps
 * the app has not applied yet.
 */
internal object WidgetStore {
  private const val PREFS = "neorecall_widgets"
  private const val KEY_PAYLOAD = "payload"
  private const val KEY_UPDATED_AT = "payloadUpdatedAt"
  private const val KEY_ACTIONS = "pendingActions"
  private const val KEY_COMPLETED = "locallyCompleted"

  /** A tap kept while nothing could serve it survives about a day, not forever. */
  private const val PENDING_LIFETIME_MILLIS = 24L * 60 * 60 * 1000

  /** A runaway queue would be a launcher bug, not a user intent. */
  private const val PENDING_LIMIT = 64

  private val lock = Any()

  @Volatile
  private var cachedPayload: String? = null

  @Volatile
  private var cached: WidgetSnapshot = WidgetSnapshot.empty

  private fun prefs(context: Context): SharedPreferences =
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  // --- Snapshot -----------------------------------------------------------

  /**
   * The last snapshot the app published. Parsed once per payload: a home screen
   * can hold several widgets, and each one would otherwise re-parse the same
   * JSON on every update.
   */
  fun snapshot(context: Context): WidgetSnapshot {
    val store = prefs(context)
    val payload = store.getString(KEY_PAYLOAD, null)
    val updatedAt = store.getLong(KEY_UPDATED_AT, 0L)
    val current = cached
    if (payload == cachedPayload && current.updatedAtMillis == updatedAt) return current
    val parsed = WidgetSnapshot.parse(payload, updatedAt)
    cachedPayload = payload
    cached = parsed
    return parsed
  }

  fun publish(context: Context, payload: String, nowMillis: Long) {
    prefs(context).edit()
      .putString(KEY_PAYLOAD, payload)
      .putLong(KEY_UPDATED_AT, nowMillis)
      .apply()
    cachedPayload = null
    pruneCompleted(context, WidgetSnapshot.parse(payload, nowMillis))
  }

  // --- Per-widget configuration -------------------------------------------

  fun option(context: Context, appWidgetId: Int, key: String, fallback: String): String =
    prefs(context).getString("$appWidgetId.$key", null) ?: fallback

  fun putOption(context: Context, appWidgetId: Int, key: String, value: String) {
    prefs(context).edit().putString("$appWidgetId.$key", value).apply()
  }

  /** Android does not clean these up on removal, so the provider does. */
  fun forget(context: Context, appWidgetIds: IntArray) {
    if (appWidgetIds.isEmpty()) return
    val store = prefs(context)
    val editor = store.edit()
    val prefixes = appWidgetIds.map { "$it." }
    store.all.keys.filter { key -> prefixes.any(key::startsWith) }.forEach(editor::remove)
    editor.apply()
  }

  // --- Taps the app has not applied yet -----------------------------------

  /**
   * Records a tap before anything is launched, so a launcher that kills this
   * process mid-tap loses nothing: the app claims the queue when it next runs.
   */
  fun queueAction(context: Context, type: String, targetId: String?, nowMillis: Long) {
    synchronized(lock) {
      val store = prefs(context)
      val queue = readArray(store, KEY_ACTIONS)
      val kept = JSONArray()
      for (index in 0 until queue.length()) {
        val row = queue.optJSONObject(index) ?: continue
        val fresh = nowMillis - row.optLong("at", 0L) < PENDING_LIFETIME_MILLIS
        val duplicate = row.optString("type") == type &&
          row.optString("targetId", "") == (targetId ?: "")
        if (fresh && !duplicate) kept.put(row)
      }
      kept.put(
        JSONObject()
          .put("type", type)
          .put("targetId", targetId ?: JSONObject.NULL)
          .put("at", nowMillis),
      )
      while (kept.length() > PENDING_LIMIT) kept.remove(0)
      // commit(), not apply(): the tap must be on disk before the Activity or
      // the Dart notification that will claim it.
      store.edit().putString(KEY_ACTIONS, kept.toString()).commit()
    }
  }

  /** Atomically hands the queue to the app. Claimed taps are never replayed. */
  fun takeActions(context: Context): List<Map<String, Any?>> = synchronized(lock) {
    val store = prefs(context)
    val queue = readArray(store, KEY_ACTIONS)
    if (queue.length() == 0) return emptyList()
    store.edit().remove(KEY_ACTIONS).commit()
    val actions = ArrayList<Map<String, Any?>>(queue.length())
    for (index in 0 until queue.length()) {
      val row = queue.optJSONObject(index) ?: continue
      val type = row.optString("type")
      if (type.isEmpty()) continue
      actions.add(
        mapOf(
          "type" to type,
          "targetId" to row.optString("targetId").ifEmpty { null },
        ),
      )
    }
    return actions
  }

  // --- Optimistic completion ---------------------------------------------

  /**
   * A ticked commitment disappears from the widget straight away, before the
   * app has been able to tell the server. Anything else would leave the row
   * sitting there looking like the tap missed.
   */
  fun markCompleted(context: Context, id: String, nowMillis: Long) {
    synchronized(lock) {
      val store = prefs(context)
      val completed = readObject(store, KEY_COMPLETED)
      completed.put(id, nowMillis)
      store.edit().putString(KEY_COMPLETED, completed.toString()).commit()
    }
  }

  fun completedLocally(context: Context): Set<String> {
    val completed = readObject(prefs(context), KEY_COMPLETED)
    if (completed.length() == 0) return emptySet()
    val ids = HashSet<String>(completed.length())
    completed.keys().forEach(ids::add)
    return ids
  }

  /**
   * Once a published snapshot stops carrying a ticked commitment, the server
   * has agreed and the local override has no more work to do. An override that
   * outlives its lifetime is dropped too, so a commitment the server refused
   * comes back rather than staying hidden for good.
   */
  private fun pruneCompleted(context: Context, snapshot: WidgetSnapshot) {
    synchronized(lock) {
      val store = prefs(context)
      val completed = readObject(store, KEY_COMPLETED)
      if (completed.length() == 0) return
      val live = snapshot.highlights.map(WidgetSnapshot.Highlight::id).toSet()
      val kept = JSONObject()
      completed.keys().forEach { id ->
        val at = completed.optLong(id, 0L)
        val expired = snapshot.updatedAtMillis - at >= PENDING_LIFETIME_MILLIS
        if (live.contains(id) && !expired) kept.put(id, at)
      }
      store.edit().putString(KEY_COMPLETED, kept.toString()).commit()
    }
  }

  private fun readArray(store: SharedPreferences, key: String): JSONArray = try {
    JSONArray(store.getString(key, "[]"))
  } catch (_: Exception) {
    JSONArray()
  }

  private fun readObject(store: SharedPreferences, key: String): JSONObject = try {
    JSONObject(store.getString(key, "{}"))
  } catch (_: Exception) {
    JSONObject()
  }
}
