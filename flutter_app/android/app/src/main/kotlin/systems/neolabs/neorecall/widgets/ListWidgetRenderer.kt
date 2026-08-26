package systems.neolabs.neorecall.widgets

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews
import systems.neolabs.neorecall.R
import systems.neolabs.neorecall.widgets.WidgetRender.background
import systems.neolabs.neorecall.widgets.WidgetRender.show
import systems.neolabs.neorecall.widgets.WidgetRender.surface
import systems.neolabs.neorecall.widgets.WidgetRender.textOrHide
import systems.neolabs.neorecall.widgets.WidgetRender.tint

/**
 * The shared frame behind the two scrolling widgets.
 *
 * Both draw the same header — what is being shown, how many there are, and how
 * fresh it is — and both hand their rows to a [RemoteViewsFactoryBase]. Only
 * the header words, the icon, and the row layout differ.
 */
internal abstract class ListWidgetRenderer(
  private val kind: WidgetKind,
  private val serviceClass: Class<*>,
  private val headerIcon: Int,
  private val emptyIcon: Int,
) : WidgetRenderer {
  override val collectionViewId: Int? get() = R.id.widget_list

  protected abstract fun heading(context: Context, filter: String): String

  protected abstract fun emptyText(context: Context, filter: String): String

  protected abstract fun count(snapshot: WidgetSnapshot, context: Context, filter: String): Int

  protected abstract fun meta(snapshot: WidgetSnapshot, context: Context, filter: String): String?

  protected abstract fun page(): String

  override fun render(
    context: Context,
    manager: AppWidgetManager,
    appWidgetId: Int,
  ): RemoteViews {
    val theme = kind.theme(context, appWidgetId)
    val filter = kind.option(context, appWidgetId, WidgetOptionKeys.FILTER)
    val snapshot = WidgetStore.snapshot(context)
    val views = RemoteViews(context.packageName, R.layout.neorecall_list_widget)
    views.surface(theme)

    views.setImageViewResource(R.id.widget_header_icon, headerIcon)
    views.tint(R.id.widget_header_icon, theme.accent)
    views.setTextViewText(R.id.widget_title, heading(context, filter))
    views.setTextColor(R.id.widget_title, theme.textPrimary)
    views.setImageViewResource(R.id.widget_header_rule, theme.divider)

    val total = if (snapshot.usable) count(snapshot, context, filter) else 0
    views.setTextViewText(R.id.widget_count, total.toString())
    views.setTextColor(R.id.widget_count, theme.accent)
    views.background(R.id.widget_count, theme.chipAccent)
    views.show(R.id.widget_count, snapshot.usable)

    views.textOrHide(R.id.widget_meta, if (snapshot.usable) meta(snapshot, context, filter) else null)
    views.setTextColor(R.id.widget_meta, theme.textMuted)

    // A unique data URI per widget id: without it the launcher hands every
    // widget of this kind the same factory, and two differently configured
    // lists would show identical rows.
    val adapter = Intent(context, serviceClass).apply {
      putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
      data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
    }
    views.setRemoteAdapter(R.id.widget_list, adapter)
    views.setPendingIntentTemplate(
      R.id.widget_list,
      WidgetIntents.rowTemplate(context, appWidgetId),
    )
    views.setEmptyView(R.id.widget_list, R.id.widget_empty)

    val empty = when {
      !snapshot.present -> context.getString(R.string.widget_waiting_detail)
      !snapshot.signedIn -> context.getString(R.string.widget_signed_out_detail)
      else -> emptyText(context, filter)
    }
    views.setTextViewText(R.id.widget_empty_text, empty)
    views.setTextColor(R.id.widget_empty_text, theme.textMuted)
    views.setImageViewResource(R.id.widget_empty_icon, emptyIcon)
    views.tint(R.id.widget_empty_icon, theme.textMuted)

    views.setOnClickPendingIntent(
      R.id.widget_header,
      WidgetIntents.open(context, appWidgetId, page()),
    )
    views.setOnClickPendingIntent(
      R.id.widget_configure,
      WidgetIntents.configure(context, appWidgetId),
    )
    return views
  }
}
