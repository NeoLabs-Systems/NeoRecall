package systems.neolabs.neorecall.widgets

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.RemoteViewsService
import android.widget.TextView
import systems.neolabs.neorecall.R

/**
 * One configuration screen for every NeoRecall widget.
 *
 * The preview is the real RemoteViews the launcher will render, re-applied
 * after every choice, so nobody has to place a widget to find out what a
 * setting does. Choices are written as they are made and the widget is redrawn
 * on the way out, which also makes this screen work as "edit" for a widget that
 * is already on the home screen.
 */
class WidgetConfigureActivity : Activity() {
  private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
  private var kind: WidgetKind? = null
  private var placing = false
  private lateinit var preview: FrameLayout

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    appWidgetId = intent?.extras?.getInt(
      AppWidgetManager.EXTRA_APPWIDGET_ID,
      AppWidgetManager.INVALID_APPWIDGET_ID,
    ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

    // Cancelled unless the user says otherwise: a configuration screen that is
    // dismissed must not leave a half-configured widget behind.
    setResult(RESULT_CANCELED, result())
    if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
      finish()
      return
    }
    val resolved = WidgetKind.forWidget(this, appWidgetId)
    if (resolved == null) {
      // A launcher that has not finished binding the widget cannot tell us what
      // it is. Keeping it with its defaults is strictly better than cancelling:
      // the widget works, and the gear on it reaches this screen again.
      setResult(RESULT_OK, result())
      finish()
      return
    }
    kind = resolved
    // A widget being placed has no options bundle yet; one already on the home
    // screen does. That is the difference between "Add widget" and "Save".
    placing = AppWidgetManager.getInstance(this)
      .getAppWidgetOptions(appWidgetId)
      ?.containsKey(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) != true

    setContentView(R.layout.neorecall_widget_configure)
    preview = findViewById(R.id.configure_preview)
    findViewById<TextView>(R.id.configure_title).text = resolved.title
    findViewById<TextView>(R.id.configure_subtitle).text = resolved.subtitle
    findViewById<TextView>(R.id.configure_confirm).apply {
      text = getString(
        if (placing) R.string.widget_configure_add else R.string.widget_configure_save,
      )
      setOnClickListener { confirm() }
    }
    findViewById<TextView>(R.id.configure_cancel).setOnClickListener { finish() }

    buildOptions(resolved)
    refreshPreview()
  }

  private fun buildOptions(kind: WidgetKind) {
    val container = findViewById<LinearLayout>(R.id.configure_options)
    val inflater = LayoutInflater.from(this)
    kind.options.forEach { option ->
      val group = inflater.inflate(R.layout.neorecall_widget_configure_group, container, false)
      group.findViewById<TextView>(R.id.group_title).text = option.title
      val choices = group.findViewById<LinearLayout>(R.id.group_options)
      val rows = ArrayList<Pair<WidgetChoice, View>>(option.choices.size)
      option.choices.forEach { choice ->
        val row = inflater.inflate(R.layout.neorecall_widget_configure_option, choices, false)
        row.findViewById<TextView>(R.id.option_label).text = choice.label
        row.findViewById<TextView>(R.id.option_description).apply {
          text = choice.description.orEmpty()
          visibility = if (choice.description == null) View.GONE else View.VISIBLE
        }
        row.setOnClickListener {
          WidgetStore.putOption(this, appWidgetId, option.key, choice.value)
          rows.forEach { (candidate, view) -> mark(view, candidate.value == choice.value) }
          refreshPreview()
        }
        choices.addView(row)
        rows.add(choice to row)
      }
      val selected = kind.option(this, appWidgetId, option.key)
      rows.forEach { (choice, view) -> mark(view, choice.value == selected) }
      container.addView(group)
    }
  }

  private fun mark(row: View, selected: Boolean) {
    row.findViewById<ImageView>(R.id.option_check).visibility =
      if (selected) View.VISIBLE else View.INVISIBLE
    row.isSelected = selected
    row.alpha = if (selected) 1f else 0.72f
  }

  /**
   * Applies the widget's own RemoteViews into the preview frame. This is the
   * same object the launcher inflates, so anything that would look wrong there
   * looks wrong here first.
   */
  private fun refreshPreview() {
    val kind = kind ?: return
    preview.removeAllViews()
    val rendered = try {
      kind.renderer.render(this, AppWidgetManager.getInstance(this), appWidgetId)
        .apply(applicationContext, preview)
    } catch (_: Exception) {
      // A preview is a courtesy. Losing it must never block configuration.
      return
    }
    val scrolling = kind == WidgetKind.HIGHLIGHTS || kind == WidgetKind.MEMORIES
    if (scrolling) fillPreviewRows(kind, rendered)
    preview.addView(
      rendered,
      FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        resources.getDimensionPixelSize(
          if (scrolling) R.dimen.widget_preview_tall else R.dimen.widget_preview_short,
        ),
      ),
    )
  }

  /**
   * A scrolling widget's rows come from an adapter the launcher owns, which
   * this process cannot drive. The preview therefore binds the same row factory
   * to a local adapter, so it shows real commitments and real memories rather
   * than an empty frame.
   */
  private fun fillPreviewRows(kind: WidgetKind, rendered: View) {
    val list = rendered.findViewById<ListView>(R.id.widget_list) ?: return
    val factory: RemoteViewsService.RemoteViewsFactory = when (kind) {
      WidgetKind.HIGHLIGHTS -> HighlightsRowFactory(applicationContext, appWidgetId)
      WidgetKind.MEMORIES -> MemoriesRowFactory(applicationContext, appWidgetId)
      else -> return
    }
    factory.onDataSetChanged()
    if (factory.count == 0) return
    rendered.findViewById<View>(R.id.widget_empty)?.visibility = View.GONE
    list.divider = null
    list.adapter = object : BaseAdapter() {
      override fun getCount() = factory.count
      override fun getItem(position: Int): Any = position
      override fun getItemId(position: Int) = factory.getItemId(position)
      override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
        factory.getViewAt(position).apply(applicationContext, parent)
    }
  }

  private fun confirm() {
    setResult(RESULT_OK, result())
    kind?.let { WidgetUpdater.refresh(this, it) }
    finish()
  }

  private fun result() = Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
}
