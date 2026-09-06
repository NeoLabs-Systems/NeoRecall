package systems.neolabs.neorecall.wear.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
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
      fontSize = 10.sp,
      fontWeight = FontWeight.SemiBold,
      letterSpacing = 1.4.sp,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
      modifier = Modifier.weight(1f, fill = false),
    )
    if (trailing != null) {
      Spacer(Modifier.width(6.dp))
      Text(
        text = trailing,
        color = NeoRecallPalette.textMuted,
        fontSize = 10.sp,
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
    fontSize = 9.sp,
    fontWeight = FontWeight.Bold,
    letterSpacing = 0.9.sp,
    maxLines = 1,
    modifier = modifier
      .clip(RoundedCornerShape(8.dp))
      .background(color.copy(alpha = 0.16f))
      .padding(horizontal = 7.dp, vertical = 3.dp),
  )
}

/** A number with its unit under it — the digest's only headline treatment. */
@Composable
fun Metric(
  value: String,
  label: String,
  color: Color,
  modifier: Modifier = Modifier,
) {
  Column(
    modifier = modifier,
    horizontalAlignment = Alignment.CenterHorizontally,
    verticalArrangement = Arrangement.Center,
  ) {
    Text(
      text = value,
      color = color,
      fontSize = 20.sp,
      fontWeight = FontWeight.Bold,
      maxLines = 1,
    )
    Text(
      text = label.uppercase(),
      color = NeoRecallPalette.textMuted,
      fontSize = 9.sp,
      letterSpacing = 0.8.sp,
      maxLines = 1,
      textAlign = TextAlign.Center,
    )
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
      fontSize = 11.sp,
      textAlign = TextAlign.Center,
    )
  }
}
