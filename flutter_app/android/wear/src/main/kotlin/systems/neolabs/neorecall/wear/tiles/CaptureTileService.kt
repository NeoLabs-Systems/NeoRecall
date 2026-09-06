package systems.neolabs.neorecall.wear.tiles

import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import systems.neolabs.neorecall.wear.digest.WatchDigestStore
import systems.neolabs.neorecall.wear.recording.WatchRecordingService
import systems.neolabs.neorecall.wear.storage.WatchRecordingStore
import systems.neolabs.neorecall.wear.ui.common.WatchFormat

/**
 * Start and stop capture without opening anything.
 *
 * The reason to record from a watch is that it takes one gesture; a tile is the
 * only surface that keeps it to one from the watch face. The tile therefore
 * leads with the control, and spends its remaining space on the two facts that
 * decide whether to press it: how long this has been running, and how much the
 * watch is still holding.
 */
class CaptureTileService : TileService() {
  override fun onTileRequest(
    requestParams: RequestBuilders.TileRequest,
  ): ListenableFuture<TileBuilders.Tile> {
    val recording = WatchRecordingService.isRecording(this)
    val startedAt = WatchRecordingService.sessionStartedAt(this)
    val held = runCatching { WatchRecordingStore.get(this).pendingCount() }.getOrDefault(0)

    val headline = if (recording && startedAt != null) {
      WatchFormat.elapsed(System.currentTimeMillis() - startedAt)
    } else if (recording) {
      "Recording"
    } else {
      "Record"
    }
    val body = TileKit.column(
      TileKit.label(
        value = if (recording) "Listening" else "NeoRecall",
        color = if (recording) TileKit.DANGER else TileKit.ACCENT,
      ),
      TileKit.gap(4f),
      TileKit.text(
        value = headline,
        sizeSp = if (recording) 28f else 22f,
        color = TileKit.TEXT_PRIMARY,
        weight = LayoutElementBuilders.FONT_WEIGHT_BOLD,
      ),
      TileKit.gap(4f),
      TileKit.text(
        value = captionFor(recording, held),
        sizeSp = 11f,
        color = TileKit.TEXT_MUTED,
        maxLines = 2,
      ),
      TileKit.gap(10f),
      TileKit.panel(
        content = TileKit.text(
          value = if (recording) "STOP" else "START",
          sizeSp = 14f,
          color = TileKit.ON_ACCENT,
          weight = LayoutElementBuilders.FONT_WEIGHT_BOLD,
        ),
        background = if (recording) TileKit.DANGER else TileKit.ACCENT,
        cornerDp = 20f,
        paddingDp = 9f,
        clickable = if (recording) TileKit.stopCapture(this) else TileKit.startCapture(this),
      ),
    )

    val tile = TileBuilders.Tile.Builder()
      .setResourcesVersion(RESOURCES_VERSION)
      // A running clock has to be redrawn; an idle tile has nothing to say
      // until something else wakes it, and asking for updates it does not need
      // is battery spent on a still image.
      .setFreshnessIntervalMillis(if (recording) 60_000L else 0L)
      .setTileTimeline(
        TimelineBuilders.Timeline.fromLayoutElement(
          TileKit.page(
            content = body,
            description = if (recording) "NeoRecall is recording" else "Start NeoRecall",
          ),
        ),
      )
      .build()
    return immediateFuture(tile)
  }

  override fun onTileResourcesRequest(
    requestParams: RequestBuilders.ResourcesRequest,
  ): ListenableFuture<ResourceBuilders.Resources> = immediateFuture(
    ResourceBuilders.Resources.Builder().setVersion(RESOURCES_VERSION).build(),
  )

  private fun captionFor(recording: Boolean, held: Int): String = when {
    recording && held > 0 ->
      "Held on watch: " + WatchFormat.count(held, "clip", "clips")
    recording -> "Audio stays here until the phone confirms it"
    held > 0 -> WatchFormat.count(held, "clip", "clips") + " waiting for the phone"
    else -> {
      val digest = WatchDigestStore.digest(this)
      if (digest.usable && digest.today.memories > 0) {
        WatchFormat.count(digest.today.memories, "memory", "memories") + " kept today"
      } else {
        "Ready to remember"
      }
    }
  }

  companion object {
    /** Bumped only when a drawable or font this tile ships would change. */
    const val RESOURCES_VERSION = "1"
  }
}
