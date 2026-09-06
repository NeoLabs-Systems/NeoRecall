package systems.neolabs.neorecall.wear.ui.home

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.InfiniteRepeatableSpec
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The one control the watch exists for.
 *
 * Drawn rather than assembled from a button and a drawable so that the shape
 * can carry the state itself: a disc that breathes and grows a halo while the
 * microphone is open, and a still ring with a soft glow when it is not. On a
 * watch the difference has to be readable from the corner of an eye, without
 * reading the label under it.
 */
@Composable
fun RecordControl(
  recording: Boolean,
  enabled: Boolean,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  diameter: Int = 84,
) {
  val transition = rememberInfiniteTransition(label = "record-pulse")
  val pulse by transition.animateFloat(
    initialValue = 0f,
    targetValue = 1f,
    animationSpec = InfiniteRepeatableSpec(
      animation = tween(durationMillis = 1_800, easing = FastOutSlowInEasing),
      repeatMode = RepeatMode.Restart,
    ),
    label = "record-pulse-value",
  )
  // The glyph morphs between a disc and a rounded square rather than swapping,
  // so a tap reads as the same object changing state.
  val morph by animateFloatAsState(
    targetValue = if (recording) 1f else 0f,
    animationSpec = tween(durationMillis = 260, easing = FastOutSlowInEasing),
    label = "record-morph",
  )
  val core = if (recording) NeoRecallPalette.danger else NeoRecallPalette.accent
  val alpha = if (enabled) 1f else 0.4f

  Box(
    modifier = modifier
      .size(diameter.dp)
      .clickable(
        enabled = enabled,
        interactionSource = remember { MutableInteractionSource() },
        indication = null,
        onClick = onClick,
      )
      .semantics {
        role = Role.Button
        contentDescription = if (recording) "Stop recording" else "Start recording"
      },
    contentAlignment = Alignment.Center,
  ) {
    Canvas(Modifier.size(diameter.dp)) {
      val centre = Offset(size.width / 2f, size.height / 2f)
      val outer = size.minDimension / 2f

      // Halo: one ring expanding outward on a loop while recording.
      if (recording) {
        val haloRadius = outer * (0.62f + 0.38f * pulse)
        drawCircle(
          color = core.copy(alpha = alpha * 0.45f * (1f - pulse)),
          radius = haloRadius,
          center = centre,
          style = Stroke(width = outer * 0.09f),
        )
      }

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
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(corner, corner),
      )
    }
  }
}
