package systems.neolabs.neorecall.wear.state

import systems.neolabs.neorecall.wear.digest.WatchDigest

/** Whether the phone that owns transcription is currently within reach. */
enum class PhoneLink {
  /** Not asked yet — never rendered as a problem. */
  UNKNOWN,

  /** A node advertising the NeoRecall phone app is connected. */
  CONNECTED,

  /** A watch-side node exists but nothing is reachable right now. */
  DISCONNECTED,

  /** Paired, reachable, but the phone app is not installed on it. */
  COMPANION_MISSING,
}

/**
 * Everything the watch UI draws from, in one immutable value.
 *
 * A single value means the record button, the sync line and the digest can
 * never show a half-updated mix of two refreshes, which on a screen this small
 * reads as a glitch rather than as progress.
 */
data class WatchUiState(
  val loaded: Boolean = false,
  val recording: Boolean = false,
  val recordingStartedAtMs: Long? = null,
  val micPermitted: Boolean = false,
  /** Chunks held on the watch that no terminal receipt has released yet. */
  val heldChunks: Int = 0,
  val phone: PhoneLink = PhoneLink.UNKNOWN,
  val digest: WatchDigest = WatchDigest.empty,
) {
  val hasHeldAudio: Boolean get() = heldChunks > 0
}
