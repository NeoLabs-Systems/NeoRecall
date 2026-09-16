package systems.neolabs.neorecall.wear.digest

import org.json.JSONArray
import org.json.JSONObject
import systems.neolabs.neorecall.wear.protocol.WearDigestProtocol

/**
 * The phone's account of the day, as the watch is allowed to show it.
 *
 * Parsing is total. A watch that is out of date with its phone must still
 * render: an unknown field is ignored, a missing one falls back to something
 * that draws, and a payload that is not JSON at all yields [empty] rather than
 * an exception on a UI thread the user cannot see.
 */
data class WatchDigest(
  val present: Boolean,
  val signedIn: Boolean,
  val generatedAtMs: Long,
  val receivedAtMs: Long,
  val capture: Capture,
  val today: Today,
  val dayInReview: String?,
  val moment: Moment?,
  val memories: List<Memory>,
  val highlights: List<Highlight>,
) {
  data class Capture(
    val recording: Boolean,
    val title: String,
    val detail: String,
    val pendingSeconds: Int,
    val issue: String?,
  )

  data class Today(
    val talkSeconds: Int,
    val memories: Int,
    val highlights: Int,
    val openTasks: Int,
    val dueToday: Int,
    val overdue: Int,
  )

  /** The newest conversation, with what was said in it. */
  data class Moment(
    val id: String?,
    val title: String?,
    val summary: String?,
    val startedAtMs: Long,
    val endedAtMs: Long,
    val live: Boolean,
    val awaitingWriteUp: Boolean,
    val topics: List<String>,
    val lines: List<Line>,
    /** How many lines the conversation has in total, trimmed or not. */
    val totalLines: Int,
  ) {
    val trimmed: Boolean get() = totalLines > lines.size
  }

  data class Line(val speaker: String?, val text: String, val atMs: Long)

  data class Memory(
    val id: String,
    val emoji: String,
    val title: String,
    val summary: String,
    val typeLabel: String,
    val atMs: Long,
    val highlightCount: Int,
  )

  data class Highlight(
    val id: String,
    val emoji: String,
    val text: String,
    val dueMs: Long?,
    val overdue: Boolean,
    val dueToday: Boolean,
    val memoryTitle: String?,
  )

  /** True once a signed-in phone has sent at least one digest. */
  val usable: Boolean get() = present && signedIn

  /** True when there is something worth opening the digest screen for. */
  val hasContent: Boolean
    get() = usable &&
      (moment != null || memories.isNotEmpty() || highlights.isNotEmpty() ||
        !dayInReview.isNullOrBlank())

  companion object {
    val empty = WatchDigest(
      present = false,
      signedIn = false,
      generatedAtMs = 0L,
      receivedAtMs = 0L,
      capture = Capture(
        recording = false,
        title = "",
        detail = "",
        pendingSeconds = 0,
        issue = null,
      ),
      today = Today(0, 0, 0, 0, 0, 0),
      dayInReview = null,
      moment = null,
      memories = emptyList(),
      highlights = emptyList(),
    )

    fun parse(payload: String?, receivedAtMs: Long): WatchDigest {
      if (payload.isNullOrBlank()) return empty
      val root = try {
        JSONObject(payload)
      } catch (_: Exception) {
        return empty
      }
      return WatchDigest(
        present = true,
        signedIn = root.optBoolean("signedIn", false),
        generatedAtMs = root.optLong("generatedAtMs", 0L),
        receivedAtMs = receivedAtMs,
        capture = capture(root.optJSONObject("capture")),
        today = today(root.optJSONObject("today")),
        dayInReview = root.optString("dayInReview").trimToNull(),
        moment = moment(root.optJSONObject("moment")),
        memories = root.optJSONArray("memories")
          .map(::memory)
          .take(WearDigestProtocol.MAX_MEMORIES),
        highlights = root.optJSONArray("highlights")
          .map(::highlight)
          .take(WearDigestProtocol.MAX_HIGHLIGHTS),
      )
    }

    private fun capture(json: JSONObject?): Capture {
      if (json == null) return empty.capture
      return Capture(
        recording = json.optBoolean("recording", false),
        title = json.optString("title"),
        detail = json.optString("detail"),
        pendingSeconds = json.optInt("pendingSeconds", 0),
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
      )
    }

    private fun moment(json: JSONObject?): Moment? {
      if (json == null) return null
      val lines = json.optJSONArray("lines")
        .map(::line)
        .filter { it.text.isNotBlank() }
        .take(WearDigestProtocol.MAX_TRANSCRIPT_LINES)
      val title = json.optString("title").trimToNull()
      val summary = json.optString("summary").trimToNull()
      if (lines.isEmpty() && title == null && summary == null) return null
      return Moment(
        id = json.optString("id").trimToNull(),
        title = title,
        summary = summary,
        startedAtMs = json.optLong("startedAtMs", 0L),
        endedAtMs = json.optLong("endedAtMs", 0L),
        live = json.optBoolean("live", false),
        awaitingWriteUp = json.optBoolean("awaitingWriteUp", false),
        topics = json.optJSONArray("topics").strings(),
        lines = lines,
        totalLines = json.optInt("totalLines", lines.size).coerceAtLeast(lines.size),
      )
    }

    private fun line(json: JSONObject) = Line(
      speaker = json.optString("speaker").trimToNull(),
      text = json.optString("text").trim(),
      atMs = json.optLong("atMs", 0L),
    )

    private fun memory(json: JSONObject) = Memory(
      id = json.optString("id"),
      emoji = json.optString("emoji").trimToNull() ?: "💭",
      title = json.optString("title").trimToNull() ?: "Untitled memory",
      summary = json.optString("summary").trim(),
      typeLabel = json.optString("typeLabel").trimToNull() ?: "Moment",
      atMs = json.optLong("atMs", 0L),
      highlightCount = json.optInt("highlightCount", 0),
    )

    private fun highlight(json: JSONObject) = Highlight(
      id = json.optString("id"),
      emoji = json.optString("emoji").trimToNull() ?: "✨",
      text = json.optString("text").trim(),
      dueMs = json.optLongOrNull("dueMs"),
      overdue = json.optBoolean("overdue", false),
      dueToday = json.optBoolean("dueToday", false),
      memoryTitle = json.optString("memoryTitle").trimToNull(),
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

    private fun JSONArray?.strings(): List<String> {
      if (this == null) return emptyList()
      val items = ArrayList<String>(length())
      for (index in 0 until length()) {
        val value = optString(index).trim()
        if (value.isNotEmpty()) items.add(value)
      }
      return items
    }

    private fun JSONObject.optLongOrNull(key: String): Long? =
      if (has(key) && !isNull(key)) optLong(key) else null

    private fun String?.trimToNull(): String? = this?.trim()?.ifEmpty { null }
  }
}
