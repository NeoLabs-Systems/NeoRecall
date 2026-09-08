package systems.neolabs.neorecall.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.wear.compose.material3.AppScaffold
import systems.neolabs.neorecall.wear.state.WatchUiState
import systems.neolabs.neorecall.wear.ui.digest.DigestScreen
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallWearTheme

/**
 * The whole watch app, above the Android entry point.
 *
 * One screen, and it reads rather than acts: the day the phone has written up,
 * with a line at the top saying what capture is doing right now. Starting and
 * stopping belongs to the Record tile, which reaches the microphone in one
 * gesture from the watch face — an app screen can only ever be a slower way to
 * press the same button, and having both invited a tap on the wrong one.
 *
 * Composed with no dependency on the Activity so the screen can be previewed and
 * reasoned about from a plain state value.
 */
@Composable
fun NeoRecallWatchApp(
  state: WatchUiState,
  modifier: Modifier = Modifier,
) {
  NeoRecallWearTheme {
    AppScaffold(modifier = modifier) {
      DigestScreen(state = state)
    }
  }
}
