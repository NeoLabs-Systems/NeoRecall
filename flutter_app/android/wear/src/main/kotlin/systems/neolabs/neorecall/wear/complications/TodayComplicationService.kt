package systems.neolabs.neorecall.wear.complications

import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import systems.neolabs.neorecall.wear.digest.WatchDigestStore
import systems.neolabs.neorecall.wear.ui.common.WatchFormat

/**
 * What today has amounted to, on the watch face.
 *
 * Answers the question the phone app is otherwise opened for — is anything
 * waiting on me — with the number that is actually pressing: overdue first,
 * then what is open, then what was kept.
 */
class TodayComplicationService : SuspendingComplicationDataSourceService() {
  override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
    val digest = WatchDigestStore.digest(this)
    if (!digest.usable) {
      return complication(request.complicationType, "—", "NeoRecall", "Nothing from the phone yet")
    }
    val today = digest.today
    val short: String
    val title: String
    when {
      today.overdue > 0 -> {
        short = "${today.overdue} late"
        title = "Overdue"
      }
      today.dueToday > 0 -> {
        short = "${today.dueToday} due"
        title = "Due today"
      }
      today.openTasks > 0 -> {
        short = "${today.openTasks} open"
        title = "Commitments"
      }
      else -> {
        short = today.memories.toString()
        title = "Kept today"
      }
    }
    val long = buildString {
      append(WatchFormat.count(today.memories, "memory", "memories")).append(" kept")
      if (today.talkSeconds > 0) {
        append(" · ").append(WatchFormat.duration(today.talkSeconds)).append(" talked")
      }
    }
    return complication(request.complicationType, short, title, long)
  }

  override fun getPreviewData(type: ComplicationType): ComplicationData? =
    complication(type, "3 open", "Commitments", "4 memories kept · 52m talked")

  private fun complication(
    type: ComplicationType,
    short: String,
    title: String,
    long: String,
  ): ComplicationData? {
    val description = PlainComplicationText.Builder(long).build()
    return when (type) {
      ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(
        text = PlainComplicationText.Builder(short).build(),
        contentDescription = description,
      ).setTapAction(openAppIntent(this, REQUEST_CODE)).build()

      ComplicationType.LONG_TEXT -> LongTextComplicationData.Builder(
        text = PlainComplicationText.Builder(long).build(),
        contentDescription = description,
      ).setTitle(PlainComplicationText.Builder(title).build())
        .setTapAction(openAppIntent(this, REQUEST_CODE))
        .build()

      else -> null
    }
  }

  private companion object {
    const val REQUEST_CODE = 8_102
  }
}
