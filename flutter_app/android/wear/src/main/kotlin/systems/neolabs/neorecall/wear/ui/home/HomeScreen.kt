package systems.neolabs.neorecall.wear.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.ScrollInfoProvider
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.delay
import systems.neolabs.neorecall.wear.state.PhoneLink
import systems.neolabs.neorecall.wear.state.WatchUiState
import systems.neolabs.neorecall.wear.ui.common.Dot
import systems.neolabs.neorecall.wear.ui.common.ScreenEdgeRing
import systems.neolabs.neorecall.wear.ui.common.WatchFormat
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * The screen a raised wrist lands on.
 *
 * Four things, and only one of them is ever new: a ring at the edge of the
 * display in the colour of whatever is going on, a status token that exists only
 * while something is wrong, the control, one line under it, and the way into the
 * day hugging the bottom.
 *
 * What was cut is the point. A wordmark, a second stop button, a sentence about
 * how audio is held and a pair of count pills all used to sit here, and between
 * them they pushed the only two things a glance actually wants — am I recording,
 * and for how long — into the middle of a list. Everything that survived answers
 * a question the wearer is asking at the moment they look down.
 */
@Composable
fun HomeScreen(
  state: WatchUiState,
  onToggleRecording: () -> Unit,
  onOpenDigest: () -> Unit,
  modifier: Modifier = Modifier,
) {
  // Not a ScalingLazyColumn: this screen is a fixed composition, and a lazy list
  // would spend its scaling and scroll handling on content that never scrolls —
  // which is what used to swallow taps meant for the control. The scroll state is
  // here only so a large display, or a very long status line, can still reach
  // everything.
  val scrollState = rememberScrollState()
  val edgeTone = edgeTone(state)
  ScreenScaffold(
    modifier = modifier,
    scrollInfoProvider = ScrollInfoProvider(scrollState),
    edgeButton = {
      EdgeButton(onClick = onOpenDigest, buttonSize = EdgeButtonSize.Small) {
        Text(text = todayLabel(state), maxLines = 1, overflow = TextOverflow.Ellipsis)
      }
    },
  ) { contentPadding ->
    Box(Modifier.fillMaxSize()) {
      if (edgeTone != null) ScreenEdgeRing(edgeTone)
      Column(
        // Padding before the scroll, never inside it: the scaffold's inset is
        // fixed chrome, and folding it into the scrolling content makes a screen
        // that fits exactly still drift under a finger.
        modifier = Modifier
          .fillMaxSize()
          .padding(contentPadding)
          .verticalScroll(scrollState),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
      ) {
        StatusToken(state)
        Spacer(Modifier.height(6.dp))
        RecordControl(recording = state.recording, onClick = onToggleRecording)
        Spacer(Modifier.height(6.dp))
        CaptureLine(state)
      }
    }
  }
}

/**
 * The colour of the ring around the display, or none at all.
 *
 * [PhoneLink.UNKNOWN] deliberately draws nothing: the link is unknown for the
 * first moment of every launch, and a watch that flashes a warning on the way to
 * saying everything is fine is worse than one that says nothing.
 */
private fun edgeTone(state: WatchUiState): Color? = when {
  state.recording -> NeoRecallPalette.danger
  state.phone == PhoneLink.COMPANION_MISSING -> NeoRecallPalette.danger
  state.hasHeldAudio || state.phone == PhoneLink.DISCONNECTED -> NeoRecallPalette.accent
  state.phoneRecording -> NeoRecallPalette.info
  else -> null
}

/**
 * One short token above the control, and only when there is something to say.
 *
 * Its height is reserved whether or not it draws, so a clip arriving mid-glance
 * cannot shift the control out from under a thumb already on its way down.
 */
@Composable
private fun StatusToken(state: WatchUiState) {
  val held = state.heldChunks
  val label: String?
  val tone: Color
  when {
    held > 0 -> {
      label = "$held HELD"
      tone = NeoRecallPalette.accent
    }
    state.phone == PhoneLink.COMPANION_MISSING -> {
      label = "NO APP"
      tone = NeoRecallPalette.danger
    }
    state.phone == PhoneLink.DISCONNECTED -> {
      label = "NO PHONE"
      tone = NeoRecallPalette.accent
    }
    else -> {
      label = null
      tone = NeoRecallPalette.textMuted
    }
  }
  Box(Modifier.height(16.dp), contentAlignment = Alignment.Center) {
    if (label != null) {
      Row(verticalAlignment = Alignment.CenterVertically) {
        Dot(tone, size = 5)
        Spacer(Modifier.width(5.dp))
        Text(
          text = label,
          color = tone,
          fontSize = 11.sp,
          fontWeight = FontWeight.SemiBold,
          letterSpacing = 1.4.sp,
          maxLines = 1,
        )
      }
    }
  }
}

/**
 * The one line under the control.
 *
 * While recording it is the elapsed clock and nothing else, because that is the
 * only number checked mid-conversation. Otherwise it carries whichever single
 * fact is most worth a wearer's attention, in the order those facts matter.
 */
@Composable
private fun CaptureLine(state: WatchUiState) {
  Box(
    modifier = Modifier
      .fillMaxWidth()
      .height(30.dp)
      .padding(horizontal = 18.dp),
    contentAlignment = Alignment.Center,
  ) {
    if (state.recording) {
      val elapsed by rememberElapsed(state.recordingStartedAtMs)
      Text(
        text = if (state.recordingStartedAtMs == null) "Recording" else WatchFormat.elapsed(elapsed),
        color = NeoRecallPalette.textPrimary,
        fontSize = 20.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
      )
    } else if (state.loaded) {
      Text(
        text = idleLine(state),
        color = NeoRecallPalette.textSecondary,
        fontSize = 13.sp,
        textAlign = TextAlign.Center,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
      )
    }
  }
}

/** The single fact the idle screen is worth spending its one line on. */
private fun idleLine(state: WatchUiState): String = when {
  !state.micPermitted -> "Tap to allow the microphone"
  state.phone == PhoneLink.COMPANION_MISSING -> "NeoRecall not on phone"
  state.phone == PhoneLink.DISCONNECTED -> "Phone out of range"
  state.phoneRecording -> "Recording on phone"
  state.digest.usable && state.digest.today.talkSeconds > 0 ->
    "${WatchFormat.duration(state.digest.today.talkSeconds)} today"
  else -> "Ready to remember"
}

/** The edge button's label: the day, and its one number when there is one. */
private fun todayLabel(state: WatchUiState): String {
  val kept = state.digest.today.memories
  return if (state.digest.usable && kept > 0) "Today · $kept" else "Today"
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
