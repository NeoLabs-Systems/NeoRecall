package systems.neolabs.neorecall.wear.ui.digest

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material3.Text
import kotlinx.coroutines.delay
import systems.neolabs.neorecall.wear.state.PhoneLink
import systems.neolabs.neorecall.wear.state.WatchUiState
import systems.neolabs.neorecall.wear.ui.common.Dot
import systems.neolabs.neorecall.wear.ui.common.WatchFormat
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallPalette

/**
 * One line at the top of the day, and only when there is something to say.
 *
 * The screen no longer starts or stops anything, so this is what is left of the
 * question a raised wrist actually asks: is it listening, and is anything stuck.
 * Silent on an ordinary day, because a permanent "all fine" badge is a line of
 * the display spent saying nothing.
 */
@Composable
fun CaptureStatus(state: WatchUiState, modifier: Modifier = Modifier) {
  val recording = state.recording
  val elapsed by rememberElapsed(state.recordingStartedAtMs, active = recording)
  val label = when {
    recording && state.recordingStartedAtMs != null -> WatchFormat.elapsed(elapsed)
    recording -> "Recording"
    state.heldChunks > 0 ->
      WatchFormat.count(state.heldChunks, "clip", "clips") + " waiting for the phone"
    state.phone == PhoneLink.COMPANION_MISSING -> "NeoRecall is not on the phone"
    state.phone == PhoneLink.DISCONNECTED -> "Phone out of range"
    state.phoneRecording -> "Recording on phone"
    state.loaded && !state.micPermitted -> "Microphone not allowed yet"
    else -> null
  } ?: return
  val tone = captureTone(state) ?: NeoRecallPalette.textMuted

  Row(
    modifier = modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 2.dp),
    horizontalArrangement = Arrangement.Center,
    verticalAlignment = Alignment.CenterVertically,
  ) {
    Dot(tone, size = 6)
    Spacer(Modifier.width(6.dp))
    Text(
      text = label,
      color = if (recording) NeoRecallPalette.textPrimary else tone,
      fontSize = if (recording) 18.sp else 12.sp,
      fontWeight = if (recording) FontWeight.Medium else FontWeight.Normal,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
    )
  }
}

/**
 * The colour capture is in, or none at all.
 *
 * [PhoneLink.UNKNOWN] deliberately reads as nothing: the link is unknown for the
 * first moment of every launch, and a watch that flashes a warning on the way to
 * saying everything is fine is worse than one that says nothing.
 */
fun captureTone(state: WatchUiState): Color? = when {
  state.recording -> NeoRecallPalette.danger
  state.phone == PhoneLink.COMPANION_MISSING -> NeoRecallPalette.danger
  state.hasHeldAudio || state.phone == PhoneLink.DISCONNECTED -> NeoRecallPalette.accent
  state.phoneRecording -> NeoRecallPalette.info
  else -> null
}

/**
 * A once-a-second clock that exists only while capture is running.
 *
 * Recomputed from the wall clock rather than counted up, so a screen that was
 * off for ten minutes comes back showing the right time instead of ten minutes
 * of missed ticks. Idle, it ticks not at all: nothing on this screen ages by the
 * second once the microphone is closed.
 */
@Composable
private fun rememberElapsed(startedAtMs: Long?, active: Boolean): State<Long> =
  produceState(initialValue = elapsedSince(startedAtMs), startedAtMs, active) {
    if (!active) {
      value = 0L
      return@produceState
    }
    while (true) {
      value = elapsedSince(startedAtMs)
      delay(1_000)
    }
  }

private fun elapsedSince(startedAtMs: Long?): Long =
  if (startedAtMs == null || startedAtMs <= 0L) 0L
  else (System.currentTimeMillis() - startedAtMs).coerceAtLeast(0L)
