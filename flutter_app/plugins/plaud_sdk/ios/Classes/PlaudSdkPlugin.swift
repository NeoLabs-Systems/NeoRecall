import Flutter
import UIKit
import PlaudDeviceBasicSDK
import PlaudBleSDK

/// Flutter plugin bridging Plaud's native iOS SDK. Port of the React Native
/// demo's `PlaudSdkModule.swift` (Expo) onto a MethodChannel + EventChannel.
///
/// All SDK interaction and delegate handling lives in `PlaudSdkController`
/// (an NSObject, since `PlaudDeviceAgentProtocol` is @objc); delegate
/// callbacks are forwarded to Dart as maps on the event channel, tagged with
/// an `event` key.
public class PlaudSdkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var controller: PlaudSdkController!

  public static func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: "plaud_sdk/methods", binaryMessenger: registrar.messenger())
    let eventChannel = FlutterEventChannel(
      name: "plaud_sdk/events", binaryMessenger: registrar.messenger())

    let instance = PlaudSdkPlugin()
    instance.controller = PlaudSdkController { [weak instance] event, body in
      // Hop to the main queue before crossing into Dart — SDK delegate
      // callbacks can arrive on arbitrary threads.
      DispatchQueue.main.async {
        var payload: [String: Any] = ["event": event]
        for (key, value) in body { payload[key] = value ?? NSNull() }
        instance?.eventSink?(payload)
      }
    }
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Method dispatch

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "initSDK":
      controller.initSDK(args, result: result)
    case "startScan":
      controller.startScan(result: result)
    case "stopScan":
      controller.stopScan(result: result)
    case "connectBleDevice":
      controller.connectBleDevice(args, result: result)
    case "disconnect":
      controller.disconnect(result: result)
    case "depair":
      controller.depair(args, result: result)
    case "isConnected":
      controller.isConnected(result: result)
    case "getFileList":
      controller.getFileList(args, result: result)
    case "exportAudio":
      controller.exportAudio(args, result: result)
    case "deleteFile":
      controller.deleteFile(args, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Owns every interaction with `PlaudDeviceAgent`, holds the scan cache and
/// in-flight export bridges, and is the SDK's `PlaudDeviceAgentProtocol`
/// delegate. Delegate callbacks are forwarded to Dart via `emit`.
private final class PlaudSdkController: NSObject, PlaudDeviceAgentProtocol {
  private let emit: (String, [String: Any?]) -> Void

  /// `connectBleDevice` needs the actual `BleDevice` the SDK handed us during
  /// a scan — Dart only carries identifiers, so we retain scanned objects and
  /// look them up. Keyed by `uuid` (the CoreBluetooth peripheral id).
  /// Touched only on the main queue.
  private var scannedDevices: [String: BleDevice] = [:]

  /// Retains in-flight export bridges so neither they nor their result
  /// callback are deallocated before the SDK finishes. Main queue only.
  private var exportCallbacks: Set<ExportCallbackBridge> = []

  /// App-level user identifier from `initSDK`, reused as the default connect
  /// `deviceToken` (it's what binds the device to the user during handshake).
  private var userId: String?

  private var scanReadyAttempts = 0
  private var isScanning = false

  init(emit: @escaping (String, [String: Any?]) -> Void) {
    self.emit = emit
    super.init()
  }

  private static func rejectArgs(_ result: @escaping FlutterResult, _ message: String) {
    result(FlutterError(code: "ERR_PLAUD_ARGS", message: message, details: nil))
  }

  // MARK: - Connection lifecycle

  func initSDK(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let token = args["userAccessToken"] as? String, !token.isEmpty else {
      return Self.rejectArgs(result, "userAccessToken is required")
    }
    guard let domain = args["customDomain"] as? String, !domain.isEmpty else {
      return Self.rejectArgs(result, "customDomain is required (domain only, no https://)")
    }
    let userId = args["userId"] as? String
    DispatchQueue.main.async {
      self.userId = userId
      let agent = PlaudDeviceAgent.shared
      agent.delegate = self
      agent.initSDK(userAccessToken: token, customDomain: domain)
      result(nil)
    }
  }

  func startScan(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      // CoreBluetooth silently drops scanForPeripherals until the central
      // manager reaches .poweredOn (async after initSDK, gated on the
      // first-launch permission prompt), so gate the real scan on the
      // power-on state.
      self.isScanning = true
      self.scanReadyAttempts = 0
      self.attemptScanWhenReady()
      result(nil)
    }
  }

  /// Fires the SDK scan once Bluetooth is powered on, polling ~18s. Main queue only.
  private func attemptScanWhenReady() {
    guard isScanning else { return }
    if BleAgent.shared.isPoweredOn {
      PlaudDeviceAgent.shared.startScan()
      return
    }
    scanReadyAttempts += 1
    if scanReadyAttempts > 60 {
      emit("scanTimeout", ["reason": "bluetoothNotPoweredOn"])
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.attemptScanWhenReady()
    }
  }

  func stopScan(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      self.isScanning = false
      PlaudDeviceAgent.shared.stopScan()
      result(nil)
    }
  }

  func connectBleDevice(_ args: [String: Any], result: @escaping FlutterResult) {
    // Always connect with a device token (the app-level userId) so the
    // handshake binds the device to the user. Prefer an explicit token.
    let token = (args["deviceToken"] as? String) ?? self.userId
    let uuid = args["uuid"] as? String
    let serialNumber = args["serialNumber"] as? String
    DispatchQueue.main.async {
      self.isScanning = false
      guard let device = self.lookupDevice(uuid: uuid, serialNumber: serialNumber) else {
        result(FlutterError(
          code: "ERR_PLAUD_UNKNOWN_DEVICE",
          message: "Unknown device — scan first, then connect by uuid or serialNumber",
          details: nil))
        return
      }
      if let token = token, !token.isEmpty {
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: device, deviceToken: token)
      } else {
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: device)
      }
      result(nil)
    }
  }

  func disconnect(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      PlaudDeviceAgent.shared.disconnect()
      result(nil)
    }
  }

  func depair(_ args: [String: Any], result: @escaping FlutterResult) {
    let clear = args["clear"] as? Bool ?? true
    DispatchQueue.main.async {
      PlaudDeviceAgent.shared.depair(clear: clear)
      result(nil)
    }
  }

  func isConnected(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      result(["connected": PlaudDeviceAgent.shared.isConnected()])
    }
  }

  // MARK: - Files

  func getFileList(_ args: [String: Any], result: @escaping FlutterResult) {
    let startSessionId = args["startSessionId"] as? Int ?? 0
    DispatchQueue.main.async {
      PlaudDeviceAgent.shared.getFileList(startSessionId: startSessionId)
      result(nil)
    }
  }

  /// Decode a recording to Documents/PlaudExports. Resolves
  /// `{ sessionId, outputPath }` on completion; emits `exportProgress` along
  /// the way. `format` defaults to mp3.
  func exportAudio(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let sessionId = args["sessionId"] as? Int, sessionId >= 0 else {
      return Self.rejectArgs(result, "sessionId is required")
    }
    let format = Self.exportFormat(from: args["format"] as? String)
    let channels = args["channels"] as? Int ?? 1
    DispatchQueue.main.async {
      let dir = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlaudExports", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

      let bridge = ExportCallbackBridge(sessionId: sessionId, result: result, controller: self)
      self.exportCallbacks.insert(bridge)
      PlaudDeviceAgent.shared.exportAudio(
        sessionId: sessionId,
        outputDir: dir.path,
        format: format,
        channels: channels,
        callback: bridge
      )
    }
  }

  func deleteFile(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let sessionId = args["sessionId"] as? Int, sessionId >= 0 else {
      return Self.rejectArgs(result, "sessionId is required")
    }
    DispatchQueue.main.async {
      PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
      result(nil)
    }
  }

  // MARK: - PlaudDeviceAgentProtocol

  func blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int,
                   findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int) {
    emit("penState", [
      "state": state, "privacy": privacy, "keyState": keyState, "uDisk": uDisk,
      "findMyToken": findMyToken, "hasSndpKey": hasSndpKey, "deviceAccessToken": deviceAccessToken
    ])
  }

  func bleScanResult(bleDevices: [BleDevice]) {
    DispatchQueue.main.async {
      for d in bleDevices { self.scannedDevices[d.uuid] = d }
    }
    let devices = bleDevices.map { d -> [String: Any] in
      [
        "name": d.name,
        "uuid": d.uuid,
        "serialNumber": d.serialNumber,
        "rssi": d.rssi,
        "supportWiFi": d.supportWiFi
      ]
    }
    emit("scanResult", ["devices": devices])
  }

  func bleScanOverTime() {
    emit("scanTimeout", [:])
  }

  func bleConnectState(state: Int) {
    // 1 = connected, 0 = disconnected, {2, -1, -2} = connection/handshake failure.
    let failed = (state == 2 || state == -1 || state == -2)
    emit("connectState", ["connected": state == 1, "failed": failed, "state": state])
  }

  func bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
    emit("bind", ["sn": sn, "status": status, "protVersion": protVersion])
  }

  // MARK: - Recording (device-initiated: physical button / VAD)

  func bleRecordStart(sessionId: Int, start: Int, status: Int, scene: Int,
                      startTime: Int, reason: Int) {
    emit("recordStart", [
      "sessionId": sessionId, "start": start, "status": status,
      "scene": scene, "startTime": startTime, "reason": reason
    ])
  }

  func bleRecordStop(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
    emit("recordStop", [
      "sessionId": sessionId, "reason": reason, "fileExist": fileExist, "fileSize": fileSize
    ])
  }

  func bleRecordPause(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
    emit("recordPause", [
      "sessionId": sessionId, "reason": reason, "fileExist": fileExist, "fileSize": fileSize
    ])
  }

  func bleRecordResume(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int) {
    emit("recordResume", [
      "sessionId": sessionId, "start": start, "status": status,
      "scene": scene, "startTime": startTime
    ])
  }

  func bleDepair(_ status: Int) {
    emit("depair", ["status": status])
  }

  func bleDeleteFile(sessionId: Int, status: Int) {
    emit("deleteFile", ["sessionId": sessionId, "status": status])
  }

  func bleChargingState(isCharging: Bool, level: Int) {
    emit("chargingState", ["isCharging": isCharging, "level": level])
  }

  func bleFileList(bleFiles: [BleFile]) {
    let files = bleFiles.map { f -> [String: Any] in
      [
        "sn": f.sn,
        "sessionId": f.sessionId,
        "size": f.size,
        "scenes": f.scenes,
        "channels": f.channels,
        "isOgg": f.isOgg,
        "isMusic": f.isMusic,
        "duration": f.duration()
      ]
    }
    emit("fileList", ["files": files])
  }

  // MARK: - Helpers

  private func lookupDevice(uuid: String?, serialNumber: String?) -> BleDevice? {
    if let uuid = uuid, let d = scannedDevices[uuid] { return d }
    if let serial = serialNumber {
      return scannedDevices.values.first { $0.serialNumber == serial }
    }
    return nil
  }

  private static func exportFormat(from raw: String?) -> AudioExportFormat {
    switch (raw ?? "mp3").lowercased() {
    case "pcm": return .pcm
    case "wav": return .wav
    case "opus": return .opus
    default: return .mp3
    }
  }

  fileprivate func emitEvent(_ event: String, _ body: [String: Any?]) {
    emit(event, body)
  }

  fileprivate func finishExport(_ bridge: ExportCallbackBridge) {
    DispatchQueue.main.async { [weak self] in
      self?.exportCallbacks.remove(bridge)
    }
  }
}

/// Adapts the SDK's per-call `AudioExportCallback` to the plugin: progress
/// becomes an `exportProgress` event, completion/error resolves/rejects the
/// originating method-channel call.
private final class ExportCallbackBridge: NSObject, AudioExportCallback {
  private let sessionId: Int
  private let result: FlutterResult
  private weak var controller: PlaudSdkController?

  init(sessionId: Int, result: @escaping FlutterResult, controller: PlaudSdkController) {
    self.sessionId = sessionId
    self.result = result
    self.controller = controller
  }

  func onProgress(_ progress: Int, message: String) {
    controller?.emitEvent("exportProgress", [
      "sessionId": sessionId, "progress": progress, "message": message
    ])
  }

  func onComplete(outputPath: String) {
    result(["sessionId": sessionId, "outputPath": outputPath])
    if let controller = controller { controller.finishExport(self) }
  }

  func onError(_ error: String) {
    result(FlutterError(code: "ERR_PLAUD_EXPORT", message: error, details: nil))
    if let controller = controller { controller.finishExport(self) }
  }
}
