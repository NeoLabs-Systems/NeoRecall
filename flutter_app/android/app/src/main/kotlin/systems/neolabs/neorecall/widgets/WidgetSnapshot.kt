package systems.neolabs.neorecall.widgets

import org.json.JSONArray
import org.json.JSONObject

/**
 * The app's published view of itself, as the widgets are allowed to see it.
 *
 * Parsing is total: any missing or malformed field falls back to a value that
 * still renders. A widget that cannot be drawn shows "Problem loading widget"
 * on the home screen, which is a far worse failure than a missing count.
 */
internal data class WidgetSnapshot(
  val present: Boolean,
  val signedIn: Boolean,
  val updatedAtMillis: Long,
  val capture: Capture,
  val today: Today,
  val device: Device?,
  val dayInReview: String?,
  val memories: List<Memory>,
  val highlights: List<Highlight>,
) {
  data class Capture(
    val phase: String,
    val title: String,
    val detail: String,
    val recording: Boolean,
    val startedAtMillis: Long?,
    val progress: Double?,
    val pendingBytes: Long,
    val pendingSeconds: Int,
    val etaSeconds: Int?,
    val issue: String?,
  )

  data class Today(
    val talkSeconds: Int,
    val memories: Int,
    val highlights: Int,
    val openTasks: Int,
    val dueToday: Int,
    val overdue: Int,
    /** The week behind today, oldest first. */
    val days: List<Day>,
    /** The week ahead, today first: what is due, and when. */
    val dueDays: List<Day>,
  )

  data class Day(
    val label: String,
    val talkSeconds: Int,
    val memories: Int,
    val highlights: Int,
    /** Commitments falling due on this day. Only set on [Today.dueDays]. */
    val due: Int,
    val today: Boolean,
  )

  data class Device(
    val label: String,
    val connected: Boolean,
    val batteryPercent: Int?,
    val pendingSeconds: Int,
  )

  data class Memory(
    val id: String,
    val emoji: String,
    val title: String,
    val summary: String,
    val type: String,
    val typeLabel: String,
    val atMillis: Long,
    val pinned: Boolean,
    val highlightCount: Int,
  )

  data class Highlight(
    val id: String,
    val kind: String,
    val emoji: String,
    val text: String,
    val importance: Double,
    val dueMillis: Long?,
    val overdue: Boolean,
    val dueToday: Boolean,
    val memoryTitle: String?,
    val memoryId: String?,
  )

  /** True once the app has published at least one snapshot for a signed-in user. */
  val usable: Boolean get() = present && signedIn

  /**
   * True when the snapshot's day counts are still about today.
   *
   * Widgets are not on a refresh timer, so a phone left alone overnight would
   * otherwise keep yesterday's totals under the word "today", with the day
   * columns labelled a day out. Saying nothing is the honest answer.
   */
  fun coversToday(nowMillis: Long): Boolean =
    usable && WidgetFormat.isSameDay(updatedAtMillis, nowMillis)

  companion object {
    val empty = WidgetSnapshot(
      present = false,
      signedIn = false,
      updatedAtMillis = 0L,
      capture = Capture(
        phase = "idle",
        title = "",
        detail = "",
        recording = false,
        startedAtMillis = null,
        progress = null,
        pendingBytes = 0L,
        pendingSeconds = 0,
        etaSeconds = null,
        issue = null,
      ),
      today = Today(0, 0, 0, 0, 0, 0, emptyList(), emptyList()),
      device = null,
      dayInReview = null,
      memories = emptyList(),
      highlights = emptyList(),
    )

    fun parse(payload: String?, updatedAtMillis: Long): WidgetSnapshot {
      if (payload.isNullOrBlank()) return empty
      val root = try {
        JSONObject(payload)
      } catch (_: Exception) {
        return empty
      }
      return WidgetSnapshot(
        present = true,
        signedIn = root.optBoolean("signedIn", false),
        updatedAtMillis = updatedAtMillis,
        capture = capture(root.optJSONObject("capture")),
        today = today(root.optJSONObject("today")),
        device = device(root.optJSONObject("device")),
        dayInReview = root.optString("dayInReview").trimToNull(),
        memories = root.optJSONArray("memories").map(::memory),
        highlights = root.optJSONArray("highlights").map(::highlight),
      )
    }

    private fun capture(json: JSONObject?): Capture {
      if (json == null) return empty.capture
      return Capture(
        phase = json.optString("phase", "idle"),
        title = json.optString("title"),
        detail = json.optString("detail"),
        recording = json.optBoolean("recording", false),
        startedAtMillis = json.optLongOrNull("startedAtMillis"),
        progress = if (json.has("progress")) json.optDouble("progress") else null,
        pendingBytes = json.optLong("pendingBytes", 0L),
        pendingSeconds = json.optInt("pendingSeconds", 0),
        etaSeconds = json.optIntOrNull("etaSeconds"),
        issue = json.optString("issue").trimToNull(),
      )
    }

    private fun today(json: JSONObject?): Today {
      if (json == null) return empty.today
      return Today(
        talkSeconds = json.optInt("talkSeconds", 0),
        memories = json.optInt("memories", 0),
        highlights = json.optInt("highlights", 0),
        openTasks = json.optInt("openTasks", 0),
        dueToday = json.optInt("dueToday", 0),
        overdue = json.optInt("overdue", 0),
        days = json.optJSONArray("days").map(::day),
        dueDays = json.optJSONArray("dueDays").map(::day),
      )
    }

    private fun day(json: JSONObject) = Day(
      label = json.optString("label"),
      talkSeconds = json.optInt("talkSeconds", 0),
      memories = json.optInt("memories", 0),
      highlights = json.optInt("highlights", 0),
      due = json.optInt("due", 0),
      today = json.optBoolean("today", false),
    )

    private fun device(json: JSONObject?): Device? {
      if (json == null) return null
      val label = json.optString("label").trimToNull() ?: return null
      return Device(
        label = label,
        connected = json.optBoolean("connected", false),
        batteryPercent = json.optIntOrNull("batteryPercent"),
        pendingSeconds = json.optInt("pendingSeconds", 0),
      )
    }

    private fun memory(json: JSONObject) = Memory(
      id = json.optString("id"),
      emoji = json.optString("emoji").trimToNull() ?: "💭",
      title = json.optString("title").trimToNull() ?: "Untitled memory",
      summary = json.optString("summary"),
      type = json.optString("type", "other"),
      typeLabel = json.optString("typeLabel").trimToNull() ?: "Moment",
      atMillis = json.optLong("atMillis", 0L),
      pinned = json.optBoolean("pinned", false),
      highlightCount = json.optInt("highlightCount", 0),
    )

    private fun highlight(json: JSONObject) = Highlight(
      id = json.optString("id"),
      kind = json.optString("kind", "task"),
      emoji = json.optString("emoji").trimToNull() ?: "✨",
      text = json.optString("text"),
      importance = json.optDouble("importance", 5.0),
      dueMillis = json.optLongOrNull("dueMillis"),
      overdue = json.optBoolean("overdue", false),
      dueToday = json.optBoolean("dueToday", false),
      memoryTitle = json.optString("memoryTitle").trimToNull(),
      memoryId = json.optString("memoryId").trimToNull(),
    )

    private fun <T> JSONArray?.map(transform: (JSONObject) -> T): List<T> {
      if (this == null) return emptyList()
      val items = ArrayList<T>(length())
      for (index in 0 until length()) {
        val row = optJSONObject(index) ?: continue
        items.add(transform(row))
      }
      return items
    }

    private fun JSONObject.optLongOrNull(key: String): Long? =
      if (has(key) && !isNull(key)) optLong(key) else null

    private fun JSONObject.optIntOrNull(key: String): Int? =
      if (has(key) && !isNull(key)) optInt(key) else null

    private fun String?.trimToNull(): String? = this?.trim()?.ifEmpty { null }
  }
}
