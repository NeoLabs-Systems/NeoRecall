package systems.neolabs.neorecall.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import systems.neolabs.neorecall.MainActivity

/**
 * Every tap a widget can offer.
 *
 * All of them are Activity PendingIntents, fired by the launcher itself, which
 * is the one activity start Android never argues with. Taps that must not show
 * a UI — stopping capture, ticking a commitment — land on [WidgetTapActivity],
 * which records the intent and finishes without ever drawing.
 */
internal object WidgetIntents {
  const val PAGE_RECORD = "record"
  const val PAGE_TIMELINE = "timeline"
  const val PAGE_MEMORIES = "memories"
  const val PAGE_HIGHLIGHTS = "highlights"

  const val TAP_OPEN = "open"
  const val TAP_STOP = "stop"
  const val TAP_COMPLETE = "complete"

  const val EXTRA_TAP = "systems.neolabs.neorecall.widget.TAP"
  const val EXTRA_PAGE = "systems.neolabs.neorecall.widget.PAGE"
  const val EXTRA_TARGET_ID = "systems.neolabs.neorecall.widget.TARGET_ID"

  // Request-code slots. One widget offers several taps at once, and two
  // PendingIntents that differ only in their extras are otherwise the same
  // object as far as the system is concerned.
  private const val SLOT_OPEN = 0
  private const val SLOT_ACTION = 1
  private const val SLOT_CONFIGURE = 2
  private const val SLOT_TEMPLATE = 3
  private const val SLOT_STAT = 4
  private const val SLOTS = 8

  private fun requestCode(appWidgetId: Int, slot: Int) = appWidgetId * SLOTS + slot

  /** Opens NeoRecall on [page], optionally on one memory or commitment. */
  fun open(
    context: Context,
    appWidgetId: Int,
    page: String,
    targetId: String? = null,
    statSlot: Int = 0,
  ): PendingIntent = PendingIntent.getActivity(
    context,
    requestCode(appWidgetId, if (statSlot > 0) SLOT_STAT + statSlot else SLOT_OPEN),
    MainActivity.widgetIntent(context, page, targetId),
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
  )

  /** Opens NeoRecall and starts phone capture, as the recorder widget always has. */
  fun startRecording(context: Context, appWidgetId: Int): PendingIntent =
    PendingIntent.getActivity(
      context,
      requestCode(appWidgetId, SLOT_ACTION),
      Intent(context, MainActivity::class.java).apply {
        action = MainActivity.ACTION_START_PHONE_RECORDING
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or
          Intent.FLAG_ACTIVITY_CLEAR_TOP or
          Intent.FLAG_ACTIVITY_SINGLE_TOP
      },
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

  /** Stops capture in place. Opening the UI to end a recording would be absurd. */
  fun stopRecording(context: Context, appWidgetId: Int): PendingIntent =
    PendingIntent.getActivity(
      context,
      requestCode(appWidgetId, SLOT_ACTION),
      tapIntent(context).putExtra(EXTRA_TAP, TAP_STOP),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

  /** Re-opens this widget's own settings. */
  fun configure(context: Context, appWidgetId: Int): PendingIntent = PendingIntent.getActivity(
    context,
    requestCode(appWidgetId, SLOT_CONFIGURE),
    Intent(context, WidgetConfigureActivity::class.java).apply {
      action = AppWidgetManager.ACTION_APPWIDGET_CONFIGURE
      putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
      // Reached from the home screen, so it is its own task rather than a card
      // stacked inside whatever the launcher had open.
      flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
    },
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
  )

  /**
   * The template every row of a collection widget fills in.
   *
   * Collection templates have to be mutable: filling one in is precisely the
   * modification an immutable PendingIntent forbids. It carries no extras of
   * its own, because a key already set on the template wins over the fill-in.
   */
  fun rowTemplate(context: Context, appWidgetId: Int): PendingIntent =
    PendingIntent.getActivity(
      context,
      requestCode(appWidgetId, SLOT_TEMPLATE),
      tapIntent(context),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

  fun openFill(page: String, targetId: String?): Intent = Intent()
    .putExtra(EXTRA_TAP, TAP_OPEN)
    .putExtra(EXTRA_PAGE, page)
    .apply { if (targetId != null) putExtra(EXTRA_TARGET_ID, targetId) }

  fun completeFill(targetId: String): Intent = Intent()
    .putExtra(EXTRA_TAP, TAP_COMPLETE)
    .putExtra(EXTRA_TARGET_ID, targetId)

  private fun tapIntent(context: Context) =
    Intent(context, WidgetTapActivity::class.java).apply {
      flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION
    }
}
