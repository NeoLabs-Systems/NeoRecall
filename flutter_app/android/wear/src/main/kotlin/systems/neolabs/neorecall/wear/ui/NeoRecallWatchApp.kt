package systems.neolabs.neorecall.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import systems.neolabs.neorecall.wear.state.WatchUiState
import systems.neolabs.neorecall.wear.ui.digest.DigestScreen
import systems.neolabs.neorecall.wear.ui.home.HomeScreen
import systems.neolabs.neorecall.wear.ui.theme.NeoRecallWearTheme

/** The routes the watch app has. Two, because a watch should not need a map. */
object WatchRoutes {
  const val HOME = "home"
  const val DIGEST = "digest"
}

/**
 * The whole watch app, above the Android entry point.
 *
 * Composed with no dependency on the Activity so the screens can be previewed
 * and reasoned about from a plain state value.
 */
@Composable
fun NeoRecallWatchApp(
  state: WatchUiState,
  onToggleRecording: () -> Unit,
  modifier: Modifier = Modifier,
  navController: NavHostController = rememberSwipeDismissableNavController(),
) {
  NeoRecallWearTheme {
    AppScaffold(modifier = modifier) {
      SwipeDismissableNavHost(
        navController = navController,
        startDestination = WatchRoutes.HOME,
      ) {
        composable(WatchRoutes.HOME) {
          HomeScreen(
            state = state,
            onToggleRecording = onToggleRecording,
            onOpenDigest = {
              // launchSingleTop: a double tap on the day card must not stack two
              // identical screens behind the swipe-to-dismiss gesture.
              navController.navigate(WatchRoutes.DIGEST) { launchSingleTop = true }
            },
          )
        }
        composable(WatchRoutes.DIGEST) {
          DigestScreen(digest = state.digest)
        }
      }
    }
  }
}
