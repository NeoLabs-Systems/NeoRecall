package systems.neolabs.neorecall.wear.ui.common

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The small vocabulary every NeoRecall watch screen is built from.
 *
 * Kept together so the two screens, and anything added later, cannot drift into
 * three different ideas of what a section heading or a muted line looks like.
 */

/** A quiet, letter-spaced label that separates one band of content from the next. */
@Composable
fun SectionHeader(
  text: String,
  modifier: Modifier = Modifier,
  trailing: String? = null,
  color: Color = NeoRecallPalette.textMuted,
) {
  Row(
    modifier = modifier
      .fillMaxWidth()
      .padding(start = 6.dp, end = 6.dp, top = 10.dp, bottom = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Text(
      text = text.uppercase(),
      color = color,
      fontSize = 11.sp,
      fontWeight = FontWeight.SemiBold,
      letterSpacing = 1.2.sp,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
      modifier = Modifier.weight(1f, fill = false),
    )
    if (trailing != null) {
      Spacer(Modifier.width(6.dp))
      Text(
        text = trailing,
        color = NeoRecallPalette.textMuted,
        fontSize = 11.sp,
        maxLines = 1,
      )
    }
  }
}

/** The card the digest screen is almost entirely made of. */
@Composable
fun WatchCard(
  modifier: Modifier = Modifier,
  background: Color = NeoRecallPalette.surface,
  borderColor: Color? = null,
  contentPadding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
  content: ColumnContent,
) {
  val shape = RoundedCornerShape(18.dp)
  Column(
    modifier = modifier
      .fillMaxWidth()
      .clip(shape)
      .background(background)
      .then(if (borderColor != null) Modifier.border(1.dp, borderColor, shape) else Modifier)
      .padding(contentPadding),
    content = content,
  )
}

/** Alias that keeps [WatchCard]'s signature readable at the call site. */
typealias ColumnContent = @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit

/** A single accent-tinted status token: state in one word plus a colour. */
@Composable
fun Pill(
  text: String,
  color: Color,
  modifier: Modifier = Modifier,
) {
  Text(
    text = text.uppercase(),
    color = color,
    fontSize = 11.sp,
    fontWeight = FontWeight.Bold,
    letterSpacing = 0.8.sp,
    maxLines = 1,
    modifier = modifier
      .clip(RoundedCornerShape(8.dp))
      .background(color.copy(alpha = 0.16f))
      .padding(horizontal = 7.dp, vertical = 3.dp),
  )
}

/**
 * A number with its unit under it — the digest's only headline treatment.
 *
 * [valueSize] exists because one of the three is a duration: "2h 14m" is six
 * characters where its neighbours are one, and at the shared size it ran off the
 * end of its column and was silently clipped.
 */
@Composable
fun Metric(
  value: String,
  label: String,
  color: Color,
  modifier: Modifier = Modifier,
  valueSize: TextUnit = 20.sp,
) {
  Column(
    modifier = modifier,
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.Center,
  ) {
    Text(
      text = value,
      color = color,
      fontSize = valueSize,
      fontWeight = FontWeight.Bold,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
    Text(
      text = label.uppercase(),
      color = NeoRecallPalette.textMuted,
      fontSize = 11.sp,
      letterSpacing = 0.7.sp,
      maxLines = 1,
      textAlign = TextAlign.Center,
    )
  }
}

/**
 * A ring hugging the edge of the display, in the colour of whatever is going on.
 *
 * The only status signal on this watch that does not have to be read. A wearer
 * glancing down sees a red rim and knows the microphone is open without focusing
 * on anything, which is what the caption under the button used to be asked to do
 * and could not. Follows the display's own shape so it sits on the bezel rather
 * than floating inside it.
 */
@Composable
fun ScreenEdgeRing(color: Color, modifier: Modifier = Modifier) {
  val round = LocalConfiguration.current.isScreenRound
  Canvas(modifier.fillMaxSize()) {
    val stroke = 3.dp.toPx()
    val inset = 2.dp.toPx() + stroke / 2f
    if (round) {
      drawCircle(
        color = color,
        radius = size.minDimension / 2f - inset,
        style = Stroke(width = stroke),
      )
    } else {
      drawRoundRect(
        color = color,
        topLeft = Offset(inset, inset),
        size = Size(size.width - inset * 2f, size.height - inset * 2f),
        cornerRadius = CornerRadius(24.dp.toPx(), 24.dp.toPx()),
        style = Stroke(width = stroke),
      )
    }
  }
}

/** A small round dot used to mark liveness without spending a whole line on it. */
@Composable
fun Dot(color: Color, size: Int = 6, modifier: Modifier = Modifier) {
  Box(
    modifier = modifier
      .size(size.dp)
      .clip(CircleShape)
      .background(color),
  )
}

/**
 * What a screen shows when it has nothing yet.
 *
 * Says what is missing and what would fill it, because a watch screen with only
 * a title on it reads as a failure rather than as an empty day.
 */
@Composable
fun EmptyState(
  title: String,
  detail: String,
  modifier: Modifier = Modifier,
) {
  Column(
    modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
    horizontalAlignment = Alignment.CenterHorizontally,
  ) {
    Text(
      text = title,
      color = NeoRecallPalette.textPrimary,
      style = MaterialTheme.typography.titleSmall,
      textAlign = TextAlign.Center,
    )
    Spacer(Modifier.height(4.dp))
    Text(
      text = detail,
      color = NeoRecallPalette.textMuted,
      fontSize = 12.sp,
      textAlign = TextAlign.Center,
    )
  }
}
