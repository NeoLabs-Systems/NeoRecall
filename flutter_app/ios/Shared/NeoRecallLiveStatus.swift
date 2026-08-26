import Foundation

#if canImport(AppIntents)
import AppIntents
#endif

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct NeoRecallLiveStatusAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    let phase: String
    let title: String
    let detail: String
    let recordingStartedAt: Date?
    let progress: Double?
    let pendingBytes: Int64
    let pendingAudioSeconds: Int
    let etaSeconds: Int?
    let issue: String?
  }

  let surfaceID: String
}
#endif

#if canImport(AppIntents)
@available(iOS 17.0, *)
struct StopNeoRecallIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Stop recording"
  static var description = IntentDescription(
    "Stops NeoRecall recording and its persistent background runtime."
  )

  func perform() async throws -> some IntentResult {
    UserDefaults.standard.set(true, forKey: "neorecall.live.stop.pending")
    NotificationCenter.default.post(name: .neoRecallLiveStopRequested, object: nil)
    return .result()
  }
}

extension Notification.Name {
  static let neoRecallLiveStopRequested = Notification.Name(
    "systems.neolabs.neorecall.liveStopRequested"
  )
}
#endif
