package systems.neolabs.neorecall.wear.ui.home

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.IconButton
import androidx.wear.compose.material3.IconButtonDefaults
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The one control the watch exists for.
 *
 * Drawn rather than assembled from a button and a drawable so that the shape can
 * carry the state itself: the glyph morphs between a disc and a rounded square,
 * and the whole control changes colour, so a tap reads as the same object
 * changing rather than as two different buttons.
 *
 * Nothing here loops. A continuous pulse costs a redraw every frame for as long
 * as the microphone is open — the wearer pays for it in battery on the one screen
 * they leave up the longest — and it says nothing the colour and the running
 * clock beside it do not already say. Liveness on this screen is the second
 * ticking over and the ring at the edge of the display; the button is still.
 *
 * The drawing sits inside a Wear [IconButton] so the control keeps the platform's
 * touch target, ripple and accessibility behaviour.
 */
@Composable
fun RecordControl(
  recording: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  enabled: Boolean = true,
  diameter: Int = 90,
) {
  // The one animation on this screen, and it only runs on a tap.
  val morph by animateFloatAsState(
    targetValue = if (recording) 1f else 0f,
    animationSpec = tween(durationMillis = 240, easing = FastOutSlowInEasing),
    label = "record-morph",
  )
  val core = if (recording) NeoRecallPalette.danger else NeoRecallPalette.accent
  val alpha = if (enabled) 1f else 0.4f

  IconButton(
    onClick = onClick,
    enabled = enabled,
    modifier = modifier
      .size(diameter.dp)
      .semantics {
        contentDescription = if (recording) "Stop recording" else "Start recording"
      },
    colors = IconButtonDefaults.iconButtonColors(
      containerColor = Color.Transparent,
      contentColor = core,
      disabledContainerColor = Color.Transparent,
      disabledContentColor = core.copy(alpha = 0.4f),
    ),
  ) {
    Canvas(Modifier.fillMaxSize()) {
      val centre = Offset(size.width / 2f, size.height / 2f)
      val outer = size.minDimension / 2f

      // Track: the button's own outline, always present so the tap target is
      // obvious before anything is happening.
      drawCircle(
        color = NeoRecallPalette.outline.copy(alpha = alpha),
        radius = outer - outer * 0.03f,
        center = centre,
        style = Stroke(width = outer * 0.055f),
      )

      // Body: a soft radial fill, dimmer at the rim, so the disc reads as lit
      // rather than as a flat sticker.
      val bodyRadius = outer * 0.80f
      drawCircle(
        brush = Brush.radialGradient(
          colors = listOf(
            core.copy(alpha = alpha * 0.34f),
            core.copy(alpha = alpha * 0.10f),
          ),
          center = centre,
          radius = bodyRadius,
        ),
        radius = bodyRadius,
        center = centre,
      )
      drawCircle(
        color = core.copy(alpha = alpha),
        radius = bodyRadius,
        center = centre,
        style = Stroke(width = outer * 0.06f),
      )

      // Glyph: disc when idle, rounded square when live.
      val glyphMax = outer * 0.44f
      val glyphSize = glyphMax * (1f - 0.28f * morph)
      val corner = glyphSize * (1f - morph) + glyphSize * 0.24f * morph
      drawRoundRect(
        color = core.copy(alpha = alpha),
        topLeft = Offset(centre.x - glyphSize, centre.y - glyphSize),
        size = Size(glyphSize * 2f, glyphSize * 2f),
        cornerRadius = CornerRadius(corner, corner),
      )
    }
  }
}
