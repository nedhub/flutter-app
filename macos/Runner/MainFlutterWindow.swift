import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.minSize = NSSize(width: 300, height: 320)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: flutterViewController)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask = [self.styleMask, NSWindow.StyleMask.fullSizeContentView]

    super.awakeFromNib()
  }
}
