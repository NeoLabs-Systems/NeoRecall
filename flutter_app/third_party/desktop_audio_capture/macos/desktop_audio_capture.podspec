#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint desktop_audio_capture.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'desktop_audio_capture'
  s.version          = '0.0.1'
  s.summary          = 'Desktop microphone and system-audio capture for NeoRecall.'
  s.description      = <<-DESC
Native macOS capture used by NeoRecall for visible microphone and ScreenCaptureKit system-audio recording.
                       DESC
  s.homepage         = 'https://github.com/NeoLabs-Systems/NeoRecall'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NeoLabs Systems' => 'https://github.com/NeoLabs-Systems' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  s.resource_bundles = {'desktop_audio_capture_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
