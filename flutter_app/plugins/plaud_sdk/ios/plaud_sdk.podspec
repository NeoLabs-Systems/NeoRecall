Pod::Spec.new do |s|
  s.name             = 'plaud_sdk'
  s.version          = '0.1.0'
  s.summary          = 'Flutter bridge for the Plaud iOS device SDK.'
  s.description      = 'BLE scan/connect, on-device recording list, and audio export for Plaud recorders.'
  s.homepage         = 'https://plaud.ai'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Plaud' => 'dev@plaud.ai' }
  s.source           = { :path => '.' }
  # Plaud's frameworks are built for iOS 15+ (arm64 device only — no simulator slice).
  s.platform         = :ios, '15.1'
  s.swift_version    = '5.9'
  s.static_framework = true

  s.dependency 'Flutter'

  # Only compile the plugin's own Swift here; the SDK binaries are vendored below.
  s.source_files = 'Classes/**/*'

  # The Plaud SDK, shipped as precompiled binary frameworks. CocoaPods embeds and
  # code-signs these automatically (the PlaudDeviceBasicSDK.bundle is nested inside
  # its .framework, so it comes along for free — no separate resource_bundles needed).
  s.vendored_frameworks = [
    'Frameworks/PlaudBleSDK.xcframework',
    'Frameworks/PlaudWiFiSDK.xcframework',
    'Frameworks/PlaudDeviceBasicSDK.xcframework'
  ]

  # PlaudDeviceBasicSDK is a static framework, so it isn't embedded into the app —
  # copy its localization bundle (used by PlaudLocalizationManager) explicitly,
  # matching the SDK README's "copy PlaudDeviceBasicSDK.bundle as a resource".
  s.resource = 'Frameworks/PlaudDeviceBasicSDK.xcframework/ios-arm64/PlaudDeviceBasicSDK.framework/PlaudDeviceBasicSDK.bundle'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }
end
