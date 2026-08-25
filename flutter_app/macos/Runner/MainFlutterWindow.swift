import Cocoa
import FlutterMacOS

// NSPanel is required for a compact recorder to remain above fullscreen apps
// and move between Spaces. The window level still switches back to `.normal`
// when the full library is open.
class MainFlutterWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
