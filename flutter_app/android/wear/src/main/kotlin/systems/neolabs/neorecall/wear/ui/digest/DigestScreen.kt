package systems.neolabs.neorecall.wear.ui.digest

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.ScalingLazyListState
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.delay
import systems.neolabs.neorecall.wear.digest.WatchDigest
import systems.neolabs.neorecall.wear.ui.common.EmptyState
import systems.neolabs.neorecall.wear.ui.common.SectionHeader
import systems.neolabs.neorecall.wear.ui.common.WatchCard
import systems.neolabs.neorecall.wear.ui.common.WatchFormat
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * One page holding everything the phone knows about the day.
 *
 * Deliberately a single scroll rather than a menu of screens: the reason to
 * look at a watch is that the answer arrives without navigating for it, and the
 * order — what it amounted to, what was just said, what was kept, what is owed
 * — is the order the questions are actually asked in.
 */
@Composable
fun DigestScreen(
  digest: WatchDigest,
  onBack: () -> Unit,
  modifier: Modifier = Modifier,
) {
  val listState: ScalingLazyListState = rememberScalingLazyListState()
  val now by rememberNow()
  ScreenScaffold(
    scrollState = listState,
    modifier = modifier,
    edgeButton = {
      EdgeButton(onClick = onBack) {
        Text("Back")
      }
    },
  ) { contentPadding ->
    ScalingLazyColumn(
      state = listState,
      contentPadding = contentPadding,
      horizontalAlignment = Alignment.CenterHorizontally,
      modifier = Modifier.fillMaxWidth(),
    ) {
      item { DigestTitle(digest, now) }

      if (!digest.usable) {
        item {
          EmptyState(
            title = if (digest.present) "Sign in on the phone" else "Nothing from the phone yet",
            detail = if (digest.present) {
              "Your day appears here once the phone app is signed in."
            } else {
              "Open NeoRecall on the paired phone once, and this fills itself in."
            },
          )
        }
        return@ScalingLazyColumn
      }

      item { TodayMetrics(digest) }

      val review = digest.dayInReview
      if (!review.isNullOrBlank()) {
        item { SectionHeader("Day in review") }
        item { DayInReview(review) }
      }

      val moment = digest.moment
      if (moment != null) {
        item {
          SectionHeader(
            text = if (moment.live) "Happening now" else "Latest conversation",
            color = if (moment.live) NeoRecallPalette.danger else NeoRecallPalette.textMuted,
          )
        }
        item { MomentHeader(moment, now) }

        if (moment.lines.isNotEmpty()) {
          item {
            SectionHeader(
              text = "Transcript",
              trailing = if (moment.trimmed) "last ${moment.lines.size}" else null,
            )
          }
          items(moment.lines) { line ->
            WatchCard(
              background = NeoRecallPalette.surfaceLow,
              contentPadding = PaddingValues(0.dp),
            ) {
              TranscriptLine(line, NeoRecallPalette.accent)
            }
          }
          if (moment.trimmed) {
            item {
              DigestFooter(
                "${moment.totalLines - moment.lines.size} earlier lines are on the phone",
              )
            }
          }
        }
      }

      if (digest.memories.isNotEmpty()) {
        item { SectionHeader("Kept", trailing = digest.memories.size.toString()) }
        items(digest.memories) { memory -> MemoryRow(memory, now) }
      }

      if (digest.highlights.isNotEmpty()) {
        item {
          SectionHeader(
            text = "Commitments",
            trailing = if (digest.today.overdue > 0) "${digest.today.overdue} late" else null,
            color = if (digest.today.overdue > 0) {
              NeoRecallPalette.danger
            } else {
              NeoRecallPalette.textMuted
            },
          )
        }
        items(digest.highlights) { highlight -> HighlightRow(highlight, now) }
      }

      if (!digest.hasContent) {
        item {
          EmptyState(
            title = "A quiet day so far",
            detail = "Conversations, memories and commitments land here as they are written up.",
          )
        }
      }

      item {
        DigestFooter(
          "From your phone · ${WatchFormat.relativeTime(digest.receivedAtMs, now)}",
        )
      }
    }
  }
}

/**
 * A minute-resolution clock for everything on the page that ages.
 *
 * Relative labels are only accurate to the minute, so ticking any faster would
 * redraw the whole list for nothing — on a watch that is battery, not polish.
 */
@Composable
private fun rememberNow(): State<Long> =
  produceState(initialValue = System.currentTimeMillis()) {
    while (true) {
      value = System.currentTimeMillis()
      delay(30_000)
    }
  }
