package systems.neolabs.neorecall.wear.tiles

import android.content.Context
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.DimensionBuilders.wrap
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.LayoutElementBuilders.Box
import androidx.wear.protolayout.LayoutElementBuilders.Column
import androidx.wear.protolayout.LayoutElementBuilders.FontStyle
import androidx.wear.protolayout.LayoutElementBuilders.LayoutElement
import androidx.wear.protolayout.LayoutElementBuilders.Row
import androidx.wear.protolayout.LayoutElementBuilders.Spacer
import androidx.wear.protolayout.LayoutElementBuilders.Text
import androidx.wear.protolayout.ModifiersBuilders.Background
import androidx.wear.protolayout.ModifiersBuilders.Clickable
import androidx.wear.protolayout.ModifiersBuilders.Corner
import androidx.wear.protolayout.ModifiersBuilders.Modifiers
import androidx.wear.protolayout.ModifiersBuilders.Padding
import androidx.wear.protolayout.ModifiersBuilders.Semantics

/**
 * The brand, expressed in the only vocabulary a tile has.
 *
 * Tiles are drawn by the system launcher from a layout description, with no
 * theme, no resources of ours and no code running at draw time, so every colour
 * and every measurement has to be stated literally. Stating them once here is
 * what keeps the two tiles looking like one product — and like the app.
 */
internal object TileKit {
  const val PAGE = 0xFF000000.toInt()
  const val SURFACE = 0xFF121914.toInt()
  const val SURFACE_HIGH = 0xFF1B2420.toInt()
  const val ACCENT = 0xFFE1B052.toInt()
  const val ON_ACCENT = 0xFF0E1511.toInt()
  const val GREEN = 0xFF84BA87.toInt()
  const val DANGER = 0xFFDE8A78.toInt()
  const val INFO = 0xFF6FB0A4.toInt()
  const val TEXT_PRIMARY = 0xFFECEFE5.toInt()
  const val TEXT_SECONDARY = 0xFFAEB7A6.toInt()
  const val TEXT_MUTED = 0xFF7E8877.toInt()

  fun text(
    value: String,
    sizeSp: Float,
    color: Int,
    weight: Int = LayoutElementBuilders.FONT_WEIGHT_NORMAL,
    maxLines: Int = 1,
    italic: Boolean = false,
  ): Text = Text.Builder()
    .setText(value)
    .setMaxLines(maxLines)
    .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE_END)
    .setFontStyle(
      FontStyle.Builder()
        .setSize(sp(sizeSp))
        .setColor(argb(color))
        .setWeight(weight)
        .setItalic(italic)
        .build(),
    )
    .build()

  fun label(value: String, color: Int = TEXT_MUTED): Text =
    text(value.uppercase(), 11f, color, LayoutElementBuilders.FONT_WEIGHT_MEDIUM)

  fun gap(size: Float): Spacer = Spacer.Builder().setHeight(dp(size)).build()

  fun hgap(size: Float): Spacer = Spacer.Builder().setWidth(dp(size)).build()

  /** A rounded panel: the tiles' only container, so they cannot drift apart. */
  fun panel(
    content: LayoutElement,
    background: Int = SURFACE,
    cornerDp: Float = 22f,
    paddingDp: Float = 10f,
    clickable: Clickable? = null,
    width: androidx.wear.protolayout.DimensionBuilders.ContainerDimension = expand(),
  ): Box = Box.Builder()
    .setWidth(width)
    .setHeight(wrap())
    .setModifiers(
      Modifiers.Builder()
        .setBackground(
          Background.Builder()
            .setColor(argb(background))
            .setCorner(Corner.Builder().setRadius(dp(cornerDp)).build())
            .build(),
        )
        .setPadding(Padding.Builder().setAll(dp(paddingDp)).build())
        .apply { if (clickable != null) setClickable(clickable) }
        .build(),
    )
    .addContent(content)
    .build()

  fun column(vararg content: LayoutElement): Column {
    val builder = Column.Builder()
      .setWidth(expand())
      .setHeight(wrap())
      .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
    content.forEach(builder::addContent)
    return builder.build()
  }

  fun startColumn(vararg content: LayoutElement): Column {
    val builder = Column.Builder()
      .setWidth(expand())
      .setHeight(wrap())
      .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_START)
    content.forEach(builder::addContent)
    return builder.build()
  }

  fun row(vararg content: LayoutElement): Row {
    val builder = Row.Builder()
      .setWidth(wrap())
      .setHeight(wrap())
      .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
    content.forEach(builder::addContent)
    return builder.build()
  }

  /** A number over its unit — the same treatment the digest screen uses. */
  fun metric(value: String, unit: String, color: Int): Column = Column.Builder()
    .setWidth(wrap())
    .setHeight(wrap())
    .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
    .addContent(text(value, 20f, color, LayoutElementBuilders.FONT_WEIGHT_BOLD))
    .addContent(text(unit.uppercase(), 10f, TEXT_MUTED))
    .build()

  /** The whole tile, on the app's own black, with room for the round bezel. */
  fun page(content: LayoutElement, clickable: Clickable? = null, description: String): Box =
    Box.Builder()
      .setWidth(expand())
      .setHeight(expand())
      .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
      .setModifiers(
        Modifiers.Builder()
          .setBackground(Background.Builder().setColor(argb(PAGE)).build())
          .setPadding(
            Padding.Builder()
              .setStart(dp(6f))
              .setEnd(dp(6f))
              .setTop(dp(4f))
              .setBottom(dp(4f))
              .build(),
          )
          .setSemantics(Semantics.Builder().setContentDescription(description).build())
          .apply { if (clickable != null) setClickable(clickable) }
          .build(),
      )
      .addContent(content)
      .build()

  /** Opens the watch app, which is what every non-action tap should do. */
  fun openApp(context: Context, id: String): Clickable = Clickable.Builder()
    .setId(id)
    .setOnClick(
      ActionBuilders.LaunchAction.Builder()
        .setAndroidActivity(
          ActionBuilders.AndroidActivity.Builder()
            .setPackageName(context.packageName)
            .setClassName("systems.neolabs.neorecall.wear.WatchMainActivity")
            .build(),
        )
        .build(),
    )
    .build()

  /**
   * Ends capture in place. Opening a screen to stop a recording would be absurd,
   * and stopping a foreground service carries none of the restrictions that
   * starting a microphone one does.
   */
  fun stopCapture(context: Context): Clickable = Clickable.Builder()
    .setId("stop")
    .setOnClick(
      ActionBuilders.LaunchAction.Builder()
        .setAndroidActivity(
          ActionBuilders.AndroidActivity.Builder()
            .setPackageName(context.packageName)
            .setClassName("systems.neolabs.neorecall.wear.tiles.TileActionActivity")
            .build(),
        )
        .build(),
    )
    .build()

  /**
   * Opens the app on its way to the microphone.
   *
   * Android refuses a microphone foreground service to a process with no
   * attached UI, so a tile that started one silently would be a button that
   * sometimes does nothing. This is the same trade the phone's record widget
   * makes, for the same reason.
   */
  fun startCapture(context: Context): Clickable = Clickable.Builder()
    .setId("start")
    .setOnClick(
      ActionBuilders.LaunchAction.Builder()
        .setAndroidActivity(
          ActionBuilders.AndroidActivity.Builder()
            .setPackageName(context.packageName)
            .setClassName("systems.neolabs.neorecall.wear.WatchMainActivity")
            .addKeyToExtraMapping(
              "systems.neolabs.neorecall.wear.START_ON_OPEN",
              ActionBuilders.booleanExtra(true),
            )
            .build(),
        )
        .build(),
    )
    .build()
}
