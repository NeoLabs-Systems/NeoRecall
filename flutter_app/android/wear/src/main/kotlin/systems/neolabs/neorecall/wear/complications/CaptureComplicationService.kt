package systems.neolabs.neorecall.wear.complications

import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import systems.neolabs.neorecall.wear.ui.common.WatchFormat

/**
 * Whether NeoRecall is listening, on the watch face itself.
 *
 * The point of an always-on recorder is trusting that it is on. A complication
 * is the only place that answer costs nothing to check, so it is worth one slot
 * even though it takes no action of its own.
 */
class CaptureComplicationService : SuspendingComplicationDataSourceService() {
  override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
    val recording = WatchRecordingService.isRecording(this)
    val startedAt = WatchRecordingService.sessionStartedAt(this)
    val held = runCatching { WatchRecordingStore.get(this).pendingCount() }.getOrDefault(0)
    val short = when {
      recording && startedAt != null ->
        WatchFormat.elapsed(System.currentTimeMillis() - startedAt)
      recording -> "REC"
      held > 0 -> "$held ⏳"
      else -> "Ready"
    }
    val long = when {
      recording -> "NeoRecall is recording"
      held > 0 -> WatchFormat.count(held, "clip", "clips") + " waiting for the phone"
      else -> "NeoRecall is ready"
    }
    return complication(request.complicationType, short, long)
  }

  override fun getPreviewData(type: ComplicationType): ComplicationData? =
    complication(type, "12:04", "NeoRecall is recording")

  private fun complication(
    type: ComplicationType,
    short: String,
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
      ).setTitle(PlainComplicationText.Builder("NeoRecall").build())
        .setTapAction(openAppIntent(this, REQUEST_CODE))
        .build()

      else -> null
    }
  }

  private companion object {
    const val REQUEST_CODE = 8_101
  }
}
