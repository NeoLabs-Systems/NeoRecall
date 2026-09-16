package systems.neolabs.neorecall.wear.surfaces

import android.content.ComponentName
import android.content.Context
import androidx.wear.tiles.TileService
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import systems.neolabs.neorecall.wear.complications.CaptureComplicationService
import systems.neolabs.neorecall.wear.complications.TodayComplicationService
import systems.neolabs.neorecall.wear.state.WatchStateRepository
import systems.neolabs.neorecall.wear.tiles.CaptureTileService
import systems.neolabs.neorecall.wear.tiles.TodayTileService

/**
 * Every place NeoRecall appears on this watch, redrawn together.
 *
 * The app screen, two tiles and two complications each read the same two
 * stores, and each is woken independently by the system. Whenever the truth
 * behind them changes there is exactly one thing to call, so a new surface can
 * never be the one that quietly keeps showing yesterday.
 */
object WatchSurfaces {
  fun refreshAll(context: Context) {
    val application = context.applicationContext
    // Failures here are cosmetic by definition — a watch face with no NeoRecall
    // complication on it will refuse the request — and must never propagate
    // into the caller, which is usually the recording path.
    runCatching {
      TileService.getUpdater(application).requestUpdate(CaptureTileService::class.java)
      TileService.getUpdater(application).requestUpdate(TodayTileService::class.java)
    }
    runCatching {
      requestComplicationUpdate(application, CaptureComplicationService::class.java)
      requestComplicationUpdate(application, TodayComplicationService::class.java)
    }
    WatchStateRepository.get(application).refresh()
  }

  private fun requestComplicationUpdate(context: Context, service: Class<*>) {
    ComplicationDataSourceUpdateRequester
      .create(context, ComponentName(context, service))
      .requestUpdateAll()
  }
}
