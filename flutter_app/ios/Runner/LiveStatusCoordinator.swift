import Foundation
import UserNotifications

#if canImport(ActivityKit)
import ActivityKit
#endif

/// The only iOS renderer for NeoRecall's shared Dart live-status payload.
/// ActivityKit owns the glanceable ongoing surface; UserNotifications is used
/// only for the storage-full transition that genuinely needs attention.
final class LiveStatusCoordinator {
  static let shared = LiveStatusCoordinator()

  private let storageNotificationID = "neorecall.storage-full"
  private let storageAlertKey = "neorecall.storage-full.active"

  private init() {}

  func update(_ payload: [String: Any]) {
    let phase = payload["phase"] as? String ?? "idle"
    reconcileStorageAlert(
      active: phase == "storageFull",
      title: payload["title"] as? String,
      detail: payload["detail"] as? String
    )

    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      let state = NeoRecallLiveStatusAttributes.ContentState(
        phase: phase,
        title: payload["title"] as? String ?? "NeoRecall",
        detail: payload["detail"] as? String ?? "",
        recordingStartedAt: Self.date(payload["recordingStartedAtMs"]),
        progress: (payload["progress"] as? NSNumber)?.doubleValue,
        pendingBytes: (payload["pendingBytes"] as? NSNumber)?.int64Value ?? 0,
        pendingAudioSeconds: (payload["pendingAudioSeconds"] as? NSNumber)?.intValue ?? 0,
        etaSeconds: (payload["etaSeconds"] as? NSNumber)?.intValue,
        issue: payload["issue"] as? String
      )
      Task { @MainActor in
        if phase == "idle" {
          await self.endActivities(finalState: state)
        } else {
          await self.upsertActivity(state: state)
        }
      }
    }
    #endif
  }

  func clear() {
    reconcileStorageAlert(active: false, title: nil, detail: nil)
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      Task { @MainActor in
        for activity in Activity<NeoRecallLiveStatusAttributes>.activities {
          await activity.end(using: nil, dismissalPolicy: .immediate)
        }
      }
    }
    #endif
  }

  private func reconcileStorageAlert(active: Bool, title: String?, detail: String?) {
    let defaults = UserDefaults.standard
    let center = UNUserNotificationCenter.current()
    guard active else {
      defaults.set(false, forKey: storageAlertKey)
      center.removePendingNotificationRequests(withIdentifiers: [storageNotificationID])
      center.removeDeliveredNotifications(withIdentifiers: [storageNotificationID])
      return
    }
    guard !defaults.bool(forKey: storageAlertKey) else { return }
    defaults.set(true, forKey: storageAlertKey)
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title ?? "NeoRecall needs storage"
      content.body = detail ?? "Free device storage to resume recording."
      content.sound = .default
      if #available(iOS 15.0, *) {
        content.interruptionLevel = .timeSensitive
      }
      center.add(
        UNNotificationRequest(
          identifier: self.storageNotificationID,
          content: content,
          trigger: nil
        )
      )
    }
  }

  private static func date(_ milliseconds: Any?) -> Date? {
    guard let value = milliseconds as? NSNumber else { return nil }
    return Date(timeIntervalSince1970: value.doubleValue / 1_000)
  }

  #if canImport(ActivityKit)
  @available(iOS 16.1, *)
  @MainActor
  private func upsertActivity(state: NeoRecallLiveStatusAttributes.ContentState) async {
    let activities = Activity<NeoRecallLiveStatusAttributes>.activities
    if let current = activities.first {
      await current.update(using: state)
      for duplicate in activities.dropFirst() {
        await duplicate.end(using: nil, dismissalPolicy: .immediate)
      }
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      _ = try Activity.request(
        attributes: NeoRecallLiveStatusAttributes(surfaceID: "capture"),
        contentState: state,
        pushType: nil
      )
    } catch {
      // Capture and durable upload remain independent of this optional surface.
    }
  }

  @available(iOS 16.1, *)
  @MainActor
  private func endActivities(finalState: NeoRecallLiveStatusAttributes.ContentState) async {
    for activity in Activity<NeoRecallLiveStatusAttributes>.activities {
      await activity.end(using: finalState, dismissalPolicy: .immediate)
    }
  }
  #endif
}
