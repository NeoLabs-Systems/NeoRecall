package systems.neolabs.neorecall.wear.ui.digest

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
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
import androidx.wear.compose.material3.Text
import systems.neolabs.neorecall.wear.digest.WatchDigest
import systems.neolabs.neorecall.wear.ui.common.Dot
import systems.neolabs.neorecall.wear.ui.common.Metric
import systems.neolabs.neorecall.wear.ui.common.Pill
import systems.neolabs.neorecall.wear.ui.common.WatchCard
import systems.neolabs.neorecall.wear.ui.common.WatchFormat
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The bands the digest screen is assembled from.
 *
 * Each one draws a single idea and nothing else, so the screen's order can be
 * rearranged — or a band dropped when its data is missing — without any of them
 * having to know what sits above or below it.
 */

/** Title of the whole screen, with how recently the phone last spoke. */
@Composable
fun DigestTitle(digest: WatchDigest, nowMs: Long) {
  Column(
    horizontalAlignment = Alignment.CenterHorizontally,
    modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp),
  ) {
    Text(
      text = "Today",
      color = NeoRecallPalette.textPrimary,
      fontSize = 18.sp,
      fontWeight = FontWeight.SemiBold,
    )
    val received = digest.receivedAtMs
    if (received > 0L) {
      val stale = !WatchFormat.isSameDay(digest.generatedAtMs.takeIf { it > 0 } ?: received, nowMs)
      Text(
        text = if (stale) {
          "From ${WatchFormat.relativeTime(received, nowMs)} ago · not today"
        } else {
          "Synced ${WatchFormat.relativeTime(received, nowMs)}"
        },
        color = if (stale) NeoRecallPalette.accent else NeoRecallPalette.textMuted,
        fontSize = 11.sp,
        textAlign = TextAlign.Center,
      )
    }
  }
}

/** Three numbers that say what the day amounted to. */
@Composable
fun TodayMetrics(digest: WatchDigest) {
  val today = digest.today
  val talk = WatchFormat.duration(today.talkSeconds)
  WatchCard {
    Row(
      modifier = Modifier.fillMaxWidth(),
      verticalAlignment = Alignment.CenterVertically,
    ) {
      // The duration needs a wider column and a smaller figure than the two
      // counts beside it; the weights are what stop it from being clipped.
      Metric(
        value = talk,
        label = "talked",
        color = NeoRecallPalette.accent,
        modifier = Modifier.weight(1.4f),
        valueSize = 16.sp,
      )
      Metric(today.memories.toString(), "kept", NeoRecallPalette.green, Modifier.weight(1f))
      Metric(
        value = today.openTasks.toString(),
        label = if (today.overdue > 0) "late ${today.overdue}" else "open",
        color = if (today.overdue > 0) NeoRecallPalette.danger else NeoRecallPalette.info,
        modifier = Modifier.weight(1f),
      )
    }
  }
}

/** The server's own narrative line for the day, when it wrote one. */
@Composable
fun DayInReview(text: String) {
  WatchCard(background = NeoRecallPalette.surfaceLow) {
    Text(
      text = text,
      color = NeoRecallPalette.textSecondary,
      fontSize = 13.sp,
      lineHeight = 18.sp,
    )
  }
}

/** The newest conversation's own account of itself. */
@Composable
fun MomentHeader(moment: WatchDigest.Moment, nowMs: Long) {
  WatchCard(
    background = NeoRecallPalette.surfaceHigh,
    borderColor = if (moment.live) NeoRecallPalette.danger.copy(alpha = 0.35f) else null,
  ) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      if (moment.live) {
        Dot(NeoRecallPalette.danger)
        Spacer(Modifier.width(5.dp))
      }
      Text(
        text = moment.title ?: if (moment.live) "Happening now" else "Latest conversation",
        color = NeoRecallPalette.textPrimary,
        fontSize = 15.sp,
        fontWeight = FontWeight.SemiBold,
        lineHeight = 19.sp,
        maxLines = 3,
        overflow = TextOverflow.Ellipsis,
      )
    }
    Spacer(Modifier.height(4.dp))
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
      Text(
        text = momentTiming(moment, nowMs),
        color = NeoRecallPalette.textMuted,
        fontSize = 11.sp,
        maxLines = 1,
      )
      if (moment.live) {
        Pill("live", NeoRecallPalette.danger)
      } else if (moment.awaitingWriteUp) {
        Pill("writing up", NeoRecallPalette.info)
      }
    }
    val summary = moment.summary
    if (summary != null) {
      Spacer(Modifier.height(7.dp))
      Text(
        text = summary,
        color = NeoRecallPalette.textSecondary,
        fontSize = 13.sp,
        lineHeight = 18.sp,
      )
    }
    if (moment.topics.isNotEmpty()) {
      Spacer(Modifier.height(7.dp))
      Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        moment.topics.take(3).forEach { topic ->
          Pill(topic, NeoRecallPalette.info, Modifier.weight(1f, fill = false))
        }
      }
    }
  }
}

/**
 * The conversation as one ruled column.
 *
 * Every line used to be its own rounded card. Four of them down a screen this
 * narrow read as four separate things rather than as one conversation, and the
 * chrome around each cost more width than the words it framed. A single rule
 * down the left says the same thing and gives the text its column back.
 */
@Composable
fun TranscriptBlock(lines: List<WatchDigest.Line>) {
  Row(
    modifier = Modifier
      .fillMaxWidth()
      .padding(start = 8.dp, end = 4.dp)
      .height(IntrinsicSize.Min),
  ) {
    Box(
      Modifier
        .width(2.dp)
        .fillMaxHeight()
        .clip(RoundedCornerShape(1.dp))
        .background(NeoRecallPalette.outline),
    )
    Column(Modifier.padding(start = 10.dp)) {
      lines.forEach { line -> TranscriptLine(line, NeoRecallPalette.accent) }
    }
  }
}

/**
 * One line of transcript.
 *
 * The speaker's name carries the colour and the timestamp sits with it, so the
 * words themselves stay one uninterrupted column — which is the only way a
 * conversation stays readable at this width.
 */
@Composable
fun TranscriptLine(line: WatchDigest.Line, accent: Color) {
  Column(
    modifier = Modifier
      .fillMaxWidth()
      .padding(vertical = 5.dp),
  ) {
    val speaker = line.speaker
    val clock = WatchFormat.clock(line.atMs)
    if (speaker != null || clock.isNotEmpty()) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        if (speaker != null) {
          Text(
            text = speaker,
            color = accent,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
          )
        }
        if (clock.isNotEmpty()) {
          Spacer(Modifier.width(6.dp))
          Text(text = clock, color = NeoRecallPalette.textMuted, fontSize = 11.sp, maxLines = 1)
        }
      }
      Spacer(Modifier.height(1.dp))
    }
    Text(
      text = line.text,
      color = NeoRecallPalette.textSecondary,
      fontSize = 13.sp,
      lineHeight = 18.sp,
    )
  }
}

/** A memory the phone has already written up. */
@Composable
fun MemoryRow(memory: WatchDigest.Memory, nowMs: Long) {
  WatchCard {
    Row(verticalAlignment = Alignment.Top) {
      Text(text = memory.emoji, fontSize = 15.sp)
      Spacer(Modifier.width(7.dp))
      Column(Modifier.weight(1f)) {
        Text(
          text = memory.title,
          color = NeoRecallPalette.textPrimary,
          fontSize = 13.sp,
          fontWeight = FontWeight.Medium,
          lineHeight = 17.sp,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
        if (memory.summary.isNotBlank()) {
          Spacer(Modifier.height(2.dp))
          Text(
            text = memory.summary,
            color = NeoRecallPalette.textMuted,
            fontSize = 11.sp,
            lineHeight = 15.sp,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
          )
        }
        Spacer(Modifier.height(4.dp))
        Text(
          text = buildString {
            append(memory.typeLabel)
            val at = WatchFormat.relativeTime(memory.atMs, nowMs)
            if (at.isNotEmpty()) append(" · ").append(at)
            if (memory.highlightCount > 0) {
              append(" · ").append(WatchFormat.count(memory.highlightCount, "note", "notes"))
            }
          },
          color = NeoRecallPalette.textMuted,
          fontSize = 11.sp,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
  }
}

/** An open commitment, ordered by the screen above it, urgency shown as a pill. */
@Composable
fun HighlightRow(highlight: WatchDigest.Highlight, nowMs: Long) {
  val due = WatchFormat.dueLabel(highlight.dueMs, highlight.overdue, nowMs)
  val tone = when {
    highlight.overdue -> NeoRecallPalette.danger
    highlight.dueToday -> NeoRecallPalette.accent
    else -> NeoRecallPalette.green
  }
  WatchCard(borderColor = if (highlight.overdue) tone.copy(alpha = 0.3f) else null) {
    Row(verticalAlignment = Alignment.Top) {
      Text(text = highlight.emoji, fontSize = 15.sp)
      Spacer(Modifier.width(7.dp))
      Column(Modifier.weight(1f)) {
        Text(
          text = highlight.text,
          color = NeoRecallPalette.textPrimary,
          fontSize = 13.sp,
          lineHeight = 18.sp,
          maxLines = 3,
          overflow = TextOverflow.Ellipsis,
        )
        val origin = highlight.memoryTitle
        if (due != null || origin != null) {
          Spacer(Modifier.height(5.dp))
          Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
          ) {
            if (due != null) Pill(due, tone)
            if (origin != null) {
              Text(
                text = origin,
                color = NeoRecallPalette.textMuted,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
              )
            }
          }
        }
      }
    }
  }
}

/** Closes the page, so a long scroll ends deliberately rather than running out. */
@Composable
fun DigestFooter(text: String) {
  Box(
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
    contentAlignment = Alignment.Center,
  ) {
    Text(
      text = text,
      color = NeoRecallPalette.textMuted,
      fontSize = 11.sp,
      textAlign = TextAlign.Center,
    )
  }
}

private fun momentTiming(moment: WatchDigest.Moment, nowMs: Long): String {
  val started = WatchFormat.clock(moment.startedAtMs)
  val ended = WatchFormat.clock(moment.endedAtMs)
  val relative = WatchFormat.relativeTime(moment.startedAtMs, nowMs)
  return when {
    moment.live && started.isNotEmpty() -> "Since $started"
    started.isNotEmpty() && ended.isNotEmpty() && started != ended -> "$started – $ended"
    started.isNotEmpty() -> started
    else -> relative
  }
}
