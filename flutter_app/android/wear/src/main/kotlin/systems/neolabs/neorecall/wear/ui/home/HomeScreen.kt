package systems.neolabs.neorecall.wear.ui.home

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.ScalingLazyListState
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.CompactButton
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.delay
import systems.neolabs.neorecall.wear.R
import systems.neolabs.neorecall.wear.digest.WatchDigest
import systems.neolabs.neorecall.wear.state.PhoneLink
import systems.neolabs.neorecall.wear.state.WatchUiState
import systems.neolabs.neorecall.wear.ui.common.Dot
import systems.neolabs.neorecall.wear.ui.common.Pill
import systems.neolabs.neorecall.wear.ui.common.WatchCard
import systems.neolabs.neorecall.wear.ui.common.WatchFormat
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The screen a raised wrist lands on.
 *
 * Ordered by how urgently it is needed: the control, then what capture is
 * doing, then what is still owed to the phone, then the way into the day. Every
 * line below the button is skippable, which is what keeps a glance to a glance.
 */
@Composable
fun HomeScreen(
  state: WatchUiState,
  onToggleRecording: () -> Unit,
  onOpenDigest: () -> Unit,
  modifier: Modifier = Modifier,
) {
  val listState: ScalingLazyListState = rememberScalingLazyListState()
  ScreenScaffold(scrollState = listState, modifier = modifier) { contentPadding ->
    ScalingLazyColumn(
      state = listState,
      contentPadding = contentPadding,
      horizontalAlignment = Alignment.CenterHorizontally,
      modifier = Modifier.fillMaxWidth(),
    ) {
      item { BrandMark() }
      item(key = "capture-${state.recording}") {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
          RecordControl(
            recording = state.recording,
            onClick = onToggleRecording,
          )
          CaptureCaption(state = state, onToggleRecording = onToggleRecording)
        }
      }
      if (state.hasHeldAudio || state.phone != PhoneLink.CONNECTED) {
        item { SyncCard(state) }
      }
      item {
        DayCard(state = state, onOpen = onOpenDigest)
      }
    }
  }
}

@Composable
private fun BrandMark() {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier.padding(bottom = 2.dp),
  ) {
    Image(
      painter = painterResource(R.drawable.neorecall_logo),
      contentDescription = null,
      modifier = Modifier.size(16.dp),
    )
    Spacer(Modifier.width(6.dp))
    Text(
      text = "NEORECALL",
      color = NeoRecallPalette.accent,
      fontSize = 10.sp,
      fontWeight = FontWeight.SemiBold,
      letterSpacing = 2.sp,
    )
  }
}

/**
 * The one line under the button.
 *
 * While recording it is the elapsed clock, because that is the only number a
 * wearer checks mid-conversation. Otherwise it is whatever the phone last said
 * capture was doing, which is more useful than a fixed slogan.
 */
@Composable
private fun CaptureCaption(
  state: WatchUiState,
  onToggleRecording: () -> Unit,
) {
  Column(
    horizontalAlignment = Alignment.CenterHorizontally,
    modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp),
  ) {
    if (state.recording) {
      val started = state.recordingStartedAtMs
      val elapsed by rememberElapsed(started)
      Row(verticalAlignment = Alignment.CenterVertically) {
        Dot(NeoRecallPalette.danger)
        Spacer(Modifier.width(6.dp))
        Text(
          text = if (started == null) "Recording" else WatchFormat.elapsed(elapsed),
          color = NeoRecallPalette.textPrimary,
          fontSize = 17.sp,
          fontWeight = FontWeight.Medium,
        )
      }
      Text(
        text = "Kept on the watch until the phone confirms it",
        color = NeoRecallPalette.textMuted,
        fontSize = 10.sp,
        textAlign = TextAlign.Center,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
      )
      CompactButton(onClick = onToggleRecording) {
        Text("Stop")
      }
    } else if (!state.micPermitted) {
      CompactButton(onClick = onToggleRecording) {
        Text("Allow microphone")
      }
    } else {
      Text(
        text = "Ready to remember",
        color = NeoRecallPalette.textPrimary,
        fontSize = 14.sp,
        textAlign = TextAlign.Center,
      )
      val detail = state.digest.capture.detail.takeIf {
        state.digest.usable && it.isNotBlank() && !state.digest.capture.recording
      }
      if (detail != null) {
        Text(
          text = detail,
          color = NeoRecallPalette.textMuted,
          fontSize = 10.sp,
          textAlign = TextAlign.Center,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
  }
}

/**
 * What the watch is still holding, and why it might be holding it.
 *
 * Audio recorded here is not released until the phone proves it was transcribed
 * and the server copy deleted, so a count sitting here is correct behaviour
 * rather than a fault — the wording has to say so, or a disconnected afternoon
 * looks like data loss.
 */
@Composable
private fun SyncCard(state: WatchUiState) {
  val (label, tone) = when (state.phone) {
    PhoneLink.CONNECTED, PhoneLink.UNKNOWN ->
      "Sending to phone" to NeoRecallPalette.info
    PhoneLink.DISCONNECTED ->
      "Phone out of range" to NeoRecallPalette.accent
    PhoneLink.COMPANION_MISSING ->
      "NeoRecall not on phone" to NeoRecallPalette.danger
  }
  WatchCard(borderColor = tone.copy(alpha = 0.28f)) {
    Row(verticalAlignment = Alignment.CenterVertically) {
      Dot(tone)
      Spacer(Modifier.width(6.dp))
      Text(
        text = label,
        color = NeoRecallPalette.textPrimary,
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
      )
    }
    if (state.hasHeldAudio) {
      Spacer(Modifier.height(3.dp))
      Text(
        text = WatchFormat.count(state.heldChunks, "clip", "clips") +
          " held safely until the phone confirms them",
        color = NeoRecallPalette.textMuted,
        fontSize = 10.sp,
      )
    } else if (state.phone == PhoneLink.COMPANION_MISSING) {
      Spacer(Modifier.height(3.dp))
      Text(
        text = "Install NeoRecall on the paired phone to start transcribing.",
        color = NeoRecallPalette.textMuted,
        fontSize = 10.sp,
      )
    }
  }
}

/** The doorway to the digest, carrying enough of it to be worth opening. */
@Composable
private fun DayCard(state: WatchUiState, onOpen: () -> Unit) {
  val digest = state.digest
  val today = digest.today
  Column(
    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
    horizontalAlignment = Alignment.CenterHorizontally,
  ) {
    if (digest.usable) {
      Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.padding(bottom = 6.dp),
      ) {
        Pill("${today.memories} kept", NeoRecallPalette.accent)
        if (today.overdue > 0) {
          Pill("${today.overdue} late", NeoRecallPalette.danger)
        } else {
          Pill("${today.openTasks} open", NeoRecallPalette.green)
        }
      }
    }
    FilledTonalButton(
      onClick = onOpen,
      modifier = Modifier.fillMaxWidth(),
      label = {
        Text(
          text = if (digest.hasContent) "Today" else "Nothing yet",
          maxLines = 1,
        )
      },
      secondaryLabel = {
        Text(
          text = digest.momentPreview(),
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
        )
      },
    )
  }
}

/** One line naming what opening the digest would show. */
private fun WatchDigest.momentPreview(): String = when {
  !usable -> "Waiting for the phone"
  moment?.title != null -> moment.title
  moment != null -> "Latest conversation"
  memories.isNotEmpty() -> memories.first().title
  else -> "Transcript and memories"
}

/**
 * A once-a-second clock that exists only while it is on screen.
 *
 * Recomputed from the wall clock rather than counted up, so a screen that was
 * off for ten minutes comes back showing the right time instead of ten minutes
 * of missed ticks.
 */
@Composable
private fun rememberElapsed(startedAtMs: Long?): State<Long> =
  produceState(initialValue = elapsedSince(startedAtMs), startedAtMs) {
    while (true) {
      value = elapsedSince(startedAtMs)
      delay(1_000)
    }
  }

private fun elapsedSince(startedAtMs: Long?): Long =
  if (startedAtMs == null || startedAtMs <= 0L) 0L
  else (System.currentTimeMillis() - startedAtMs).coerceAtLeast(0L)
