package systems.neolabs.neorecall.wear.tiles

import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.google.common.util.concurrent.ListenableFuture
import systems.neolabs.neorecall.wear.digest.WatchDigest
import systems.neolabs.neorecall.wear.digest.WatchDigestStore
import systems.neolabs.neorecall.wear.ui.common.WatchFormat

/**
 * The day, at the distance a tile is read from.
 *
 * Three numbers and one sentence. Anything more would be the digest screen,
 * which is one tap away through the whole tile — a tile that tries to be the
 * page ends up being neither.
 */
class TodayTileService : TileService() {
  override fun onTileRequest(
    requestParams: RequestBuilders.TileRequest,
  ): ListenableFuture<TileBuilders.Tile> {
    val digest = WatchDigestStore.digest(this)
    val now = System.currentTimeMillis()

    val body = if (!digest.usable) {
      TileKit.column(
        TileKit.label("NeoRecall", TileKit.ACCENT),
        TileKit.gap(6f),
        TileKit.text("Nothing yet", 18f, TileKit.TEXT_PRIMARY, LayoutElementBuilders.FONT_WEIGHT_BOLD),
        TileKit.gap(4f),
        TileKit.text(
          value = "Open NeoRecall on the paired phone once, and your day appears here.",
          sizeSp = 11f,
          color = TileKit.TEXT_MUTED,
          maxLines = 3,
        ),
      )
    } else {
      TileKit.column(
        TileKit.label("Today", TileKit.ACCENT),
        TileKit.gap(6f),
        TileKit.panel(
          content = TileKit.row(
            TileKit.metric(
              WatchFormat.duration(digest.today.talkSeconds),
              "talked",
              TileKit.ACCENT,
            ),
            TileKit.hgap(12f),
            TileKit.metric(digest.today.memories.toString(), "kept", TileKit.GREEN),
            TileKit.hgap(12f),
            TileKit.metric(
              digest.today.openTasks.toString(),
              if (digest.today.overdue > 0) "late" else "open",
              if (digest.today.overdue > 0) TileKit.DANGER else TileKit.INFO,
            ),
          ),
          background = TileKit.SURFACE,
          cornerDp = 20f,
        ),
        TileKit.gap(6f),
        TileKit.panel(
          content = TileKit.startColumn(
            TileKit.text(headline(digest), 12f, TileKit.TEXT_PRIMARY, LayoutElementBuilders.FONT_WEIGHT_MEDIUM, maxLines = 2),
            TileKit.gap(2f),
            TileKit.text(detail(digest, now), 10f, TileKit.TEXT_MUTED, maxLines = 3),
          ),
          background = TileKit.SURFACE_HIGH,
          cornerDp = 18f,
        ),
      )
    }

    val tile = TileBuilders.Tile.Builder()
      .setResourcesVersion(RESOURCES_VERSION)
      // The digest arrives by push. A refresh interval here would only redraw
      // the same numbers between publishes.
      .setFreshnessIntervalMillis(0L)
      .setTileTimeline(
        TimelineBuilders.Timeline.fromLayoutElement(
          TileKit.page(
            content = body,
            clickable = TileKit.openApp(this, "today"),
            description = "NeoRecall today",
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

  /** The most recent thing worth naming, whatever kind of thing that is. */
  private fun headline(digest: WatchDigest): String {
    val moment = digest.moment
    if (moment?.live == true) return moment.title ?: "Happening now"
    val overdue = digest.highlights.firstOrNull { it.overdue }
    if (overdue != null) return overdue.text
    moment?.title?.let { return it }
    digest.memories.firstOrNull()?.let { return it.title }
    return digest.dayInReview ?: "A quiet day so far"
  }

  private fun detail(digest: WatchDigest, nowMs: Long): String {
    val moment = digest.moment
    if (moment?.live == true) return "Recording now"
    val overdue = digest.highlights.firstOrNull { it.overdue }
    if (overdue != null) return "Overdue" + (overdue.memoryTitle?.let { " · $it" } ?: "")
    if (moment != null) {
      return moment.summary
        ?: ("Latest conversation · " + WatchFormat.relativeTime(moment.startedAtMs, nowMs))
    }
    digest.memories.firstOrNull()?.let { memory ->
      return memory.summary.ifBlank {
        memory.typeLabel + " · " + WatchFormat.relativeTime(memory.atMs, nowMs)
      }
    }
    return "Synced " + WatchFormat.relativeTime(digest.receivedAtMs, nowMs)
  }

  companion object {
    const val RESOURCES_VERSION = "1"
  }
}
