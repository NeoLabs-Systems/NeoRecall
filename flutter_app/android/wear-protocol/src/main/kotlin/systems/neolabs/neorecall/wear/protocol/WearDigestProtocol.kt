package systems.neolabs.neorecall.wear.protocol

/**
 * The phone-to-watch half of the pairing: what the watch is allowed to show
 * about a day that was recorded, summarised and remembered on the phone.
 *
 * Deliberately separate from [WearTransferProtocol]. Audit trail and digest
 * evolve on different clocks — a display field may be added without touching
 * the contract that governs when recorded audio may be released — and the
 * reliability invariant lives entirely in the transfer protocol.
 */
object WearDigestProtocol {
  const val VERSION = 1

  /**
   * One item, overwritten in place. The watch never needs a history of
   * digests, and a per-update path would leave the Data Layer accumulating
   * items the watch has already superseded.
   */
  const val DIGEST_PATH = "/neorecall/watch/digest"

  const val KEY_VERSION = "version"
  const val KEY_PAYLOAD = "payload"
  const val KEY_PUBLISHED_AT_MS = "publishedAtMs"

  /**
   * Data Layer items are capped near 100 KB, and an oversized put fails the
   * whole transfer rather than truncating. The publisher trims to this budget
   * before it sends, so the ceiling is a display concern and never an error.
   */
  const val MAX_PAYLOAD_BYTES = 60_000

  /** Advertised by the watch APK, so the phone can tell whether it is installed. */
  const val CAPABILITY_WATCH_APP = "neorecall_watch_app"

  /** Advertised by the phone APK, so the watch can explain a missing companion. */
  const val CAPABILITY_PHONE_APP = "neorecall_phone_app"

  /** How much of a conversation the watch will ever be sent. */
  const val MAX_TRANSCRIPT_LINES = 40
  const val MAX_LINE_CHARACTERS = 280
  const val MAX_MEMORIES = 8
  const val MAX_HIGHLIGHTS = 8
}
