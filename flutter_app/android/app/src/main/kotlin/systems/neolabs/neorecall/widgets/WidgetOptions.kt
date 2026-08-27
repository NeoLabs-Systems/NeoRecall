package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import systems.neolabs.neorecall.RecordWidgetProvider

/** One configurable choice, with the plain reason to pick it. */
internal data class WidgetChoice(
  val value: String,
  val label: String,
  val description: String? = null,
)

/**
 * Option keys, at file scope because an enum entry cannot reach its own
 * companion object while the entries are still being constructed.
 */
internal object WidgetOptionKeys {
  const val THEME = "theme"
  const val TAP = "tap"
  const val FILTER = "filter"
  const val SOURCE = "source"
  const val SUMMARY = "summary"
  const val METRIC = "metric"
}

private fun themeOption() = WidgetOption(
  key = WidgetOptionKeys.THEME,
  title = "APPEARANCE",
  default = WidgetTheme.AUTO,
  choices = listOf(
    WidgetChoice(WidgetTheme.AUTO, "Match the system", "Follows light and dark mode."),
    WidgetChoice(WidgetTheme.DARK, "Always dark"),
    WidgetChoice(WidgetTheme.LIGHT, "Always light"),
  ),
)

internal data class WidgetOption(
  val key: String,
  val title: String,
  val default: String,
  val choices: List<WidgetChoice>,
)

/**
 * The five home-screen widgets, their configuration, and how to find the kind
 * behind an app widget id.
 *
 * Every option is answered with a default that works, so a widget dropped
 * without opening this screen still shows something worth keeping.
 */
internal enum class WidgetKind(
  val id: String,
  val providerClass: Class<out NeoRecallAppWidget>,
  val title: String,
  val subtitle: String,
  val options: List<WidgetOption>,
) {
  RECORD(
    id = "record",
    providerClass = RecordWidgetProvider::class.java,
    title = "Recorder",
    subtitle = "Start and stop persistent capture, with the elapsed time on the button.",
    options = listOf(
      WidgetOption(
        key = WidgetOptionKeys.TAP,
        title = "WHEN RECORDING, THE BUTTON",
        default = "smart",
        choices = listOf(
          WidgetChoice("smart", "Stops the recording", "Tap the card itself to open NeoRecall."),
          WidgetChoice("record", "Keeps starting capture", "Restarts phone capture instead of stopping."),
          WidgetChoice("open", "Opens NeoRecall", "The widget never changes capture on its own."),
        ),
      ),
      themeOption(),
    ),
  ),
  STATUS(
    id = "status",
    providerClass = StatusWidgetProvider::class.java,
    title = "Capture status",
    subtitle = "What capture and processing are doing, in the same words as the notification.",
    options = listOf(
      WidgetOption(
        key = WidgetOptionKeys.TAP,
        title = "TAPPING THE WIDGET OPENS",
        default = "record",
        choices = listOf(
          WidgetChoice("record", "The recorder", "Where capture is started and stopped."),
          WidgetChoice("timeline", "The timeline", "Everything captured, newest first."),
        ),
      ),
      themeOption(),
    ),
  ),
  HIGHLIGHTS(
    id = "highlights",
    providerClass = HighlightsWidgetProvider::class.java,
    title = "Commitments",
    subtitle = "Tasks and promises picked out of your conversations. Tick one without opening the app.",
    options = listOf(
      WidgetOption(
        key = WidgetOptionKeys.FILTER,
        title = "SHOW",
        default = "open",
        choices = listOf(
          WidgetChoice("open", "Everything still open", "Most important first."),
          WidgetChoice("today", "Due today", "Plus anything already overdue."),
          WidgetChoice("overdue", "Overdue only", "The list you want to be empty."),
          WidgetChoice("promises", "Promises to people", "What you said you would do."),
        ),
      ),
      WidgetOption(
        key = WidgetOptionKeys.SOURCE,
        title = "SOURCE CONVERSATION",
        default = "show",
        choices = listOf(
          WidgetChoice("show", "Show where it came from"),
          WidgetChoice("hide", "Hide it", "Fits more commitments in the same space."),
        ),
      ),
      themeOption(),
    ),
  ),
  MEMORIES(
    id = "memories",
    providerClass = MemoriesWidgetProvider::class.java,
    title = "Memories",
    subtitle = "What your conversations turned into. Tap one to open it.",
    options = listOf(
      WidgetOption(
        key = WidgetOptionKeys.FILTER,
        title = "SHOW",
        default = "recent",
        choices = listOf(
          WidgetChoice("recent", "Newest first"),
          WidgetChoice("pinned", "Pinned only", "The ones you marked to keep close."),
          WidgetChoice("meeting", "Meetings and projects"),
          WidgetChoice("decision", "Decisions and lessons"),
        ),
      ),
      WidgetOption(
        key = WidgetOptionKeys.SUMMARY,
        title = "SUMMARY LINES",
        default = "show",
        choices = listOf(
          WidgetChoice("show", "Show a two-line summary"),
          WidgetChoice("hide", "Titles only", "Fits about twice as many memories."),
        ),
      ),
      themeOption(),
    ),
  ),
  TODAY(
    id = "today",
    providerClass = TodayWidgetProvider::class.java,
    title = "Today",
    subtitle = "One headline number against the week behind it.",
    options = listOf(
      WidgetOption(
        key = WidgetOptionKeys.METRIC,
        title = "HEADLINE NUMBER",
        default = "talk",
        choices = listOf(
          WidgetChoice("talk", "Time captured today"),
          WidgetChoice("memories", "Memories written today"),
          WidgetChoice("highlights", "Highlights found today"),
          WidgetChoice("open", "Commitments still open", "Counts everything open, not just today's."),
        ),
      ),
      themeOption(),
    ),
  ),
  ;

  /**
   * Resolve renderers only after enum construction is complete.
   *
   * The scrolling renderers need their [WidgetKind] for options and theming.
   * Eagerly storing their singleton in the enum constructor therefore creates
   * a static-initialization cycle (`WidgetKind` -> renderer -> `WidgetKind`),
   * which Android turns into an unrecoverable startup crash.
   */
  val renderer: WidgetRenderer
    get() = when (this) {
      RECORD -> RecordWidgetRenderer
      STATUS -> StatusWidgetRenderer
      HIGHLIGHTS -> HighlightsWidgetRenderer
      MEMORIES -> MemoriesWidgetRenderer
      TODAY -> TodayWidgetRenderer
    }

  fun option(context: Context, appWidgetId: Int, key: String): String {
    val option = options.firstOrNull { it.key == key } ?: return ""
    val stored = WidgetStore.option(context, appWidgetId, key, option.default)
    return if (option.choices.any { it.value == stored }) stored else option.default
  }

  fun theme(context: Context, appWidgetId: Int): WidgetTheme =
    WidgetTheme.of(context, option(context, appWidgetId, WidgetOptionKeys.THEME))

  fun ids(context: Context): IntArray = AppWidgetManager.getInstance(context)
    .getAppWidgetIds(ComponentName(context, providerClass))

  companion object {
    fun of(id: String?): WidgetKind? = entries.firstOrNull { it.id == id }

    /** Resolves the kind from a placed widget, which is all a launcher hands us. */
    fun forWidget(context: Context, appWidgetId: Int): WidgetKind? {
      val provider = AppWidgetManager.getInstance(context)
        .getAppWidgetInfo(appWidgetId)?.provider?.className ?: return null
      return entries.firstOrNull { it.providerClass.name == provider }
    }
  }
}
