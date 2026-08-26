import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var backgroundStatusChannel: FlutterMethodChannel?
  private var liveStopObserver: NSObjectProtocol?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "systems.neolabs.neorecall/background_capture",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "updateLiveStatus":
          guard let payload = call.arguments as? [String: Any] else {
            result(
              FlutterError(
                code: "INVALID_LIVE_STATUS",
                message: "Status payload is missing.",
                details: nil
              )
            )
            return
          }
          LiveStatusCoordinator.shared.update(payload)
          result(true)
        case "clearLiveStatus":
          LiveStatusCoordinator.shared.clear()
          result(true)
        case "takePendingLiveStopRequest":
          let key = "neorecall.live.stop.pending"
          let pending = UserDefaults.standard.bool(forKey: key)
          if pending { UserDefaults.standard.set(false, forKey: key) }
          result(pending)
        case "acknowledgeLiveStopRequest":
          UserDefaults.standard.set(false, forKey: "neorecall.live.stop.pending")
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      backgroundStatusChannel = channel
      liveStopObserver = NotificationCenter.default.addObserver(
        forName: .neoRecallLiveStopRequested,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.backgroundStatusChannel?.invokeMethod(
          "backgroundStopRequested",
          arguments: nil
        )
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
