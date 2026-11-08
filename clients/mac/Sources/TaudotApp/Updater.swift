// Updates with Sparkle (MIT, sparkle-project.org), and the Acknowledgements window. Sparkle.framework is put in
// Contents/Frameworks by bundle.sh and loaded here at run time, so the Swift package has no dependency on it: a
// `swift build` app simply has no updater. The feed (SUFeedURL) and the EdDSA public key (SUPublicEDKey) are in
// Info.plist; tools/release/make.sh signs each release with the private key, which stays in the Keychain.
//
// Tests (tools/release/update-test.sh): TAUDOT_UPDATE_TEST=1 checks the feed at launch, downloads in the background,
// installs as soon as the update is ready, and doesn't relaunch; progress lines go to stderr as "update: ...".
import AppKit
import ObjectiveC

@MainActor final class Updater: NSObject {
  static let shared = Updater()
  private var controller: NSObject?
  let test = ProcessInfo.processInfo.environment["TAUDOT_UPDATE_TEST"] != nil

  var available: Bool { controller != nil }

  /// Loads Sparkle and starts its updater (scheduled checks per the user's choice; SUEnableAutomaticChecks).
  func start() {
    guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
      let fw = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
      let bundle = Bundle(url: fw), bundle.load(),
      let cls: AnyClass = NSClassFromString("SPUStandardUpdaterController")
    else { return }
    // [[SPUStandardUpdaterController alloc] initWithStartingUpdater:YES updaterDelegate:self userDriverDelegate:nil]
    typealias Init = @convention(c) (AnyObject, Selector, Bool, AnyObject?, AnyObject?) -> AnyObject?
    let sel = NSSelectorFromString("initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
    guard let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
      let imp = class_getMethodImplementation(cls, sel)
    else { return }
    let ctl = unsafeBitCast(imp, to: Init.self)(alloc, sel, !test, self, nil) as? NSObject
    controller = ctl
    if test, let updater = ctl?.value(forKey: "updater") as? NSObject {
      log("feed \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "?"), version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")")
      var err: NSError?
      typealias Start = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
      let s = NSSelectorFromString("startUpdater:")
      if let i = class_getMethodImplementation(type(of: updater), s) {
        let ok = withUnsafeMutablePointer(to: &err) { unsafeBitCast(i, to: Start.self)(updater, s, $0) }
        if !ok { log("could not start: \(err?.localizedDescription ?? "?")") }
      }
      updater.setValue(true, forKey: "automaticallyDownloadsUpdates")
      updater.perform(NSSelectorFromString("checkForUpdatesInBackground"))
    }
  }

  @objc func checkForUpdates(_ sender: Any?) {
    controller?.perform(NSSelectorFromString("checkForUpdates:"), with: sender)
  }

  func log(_ s: String) { FileHandle.standardError.write(Data("update: \(s)\n".utf8)) }

  // SPUUpdaterDelegate (Sparkle asks with respondsToSelector:, so plain @objc methods do)
  @objc(updater:didFindValidUpdate:) func didFind(_ u: NSObject, item: NSObject) {
    log("found \(item.value(forKey: "versionString") ?? "?")")
  }
  @objc(updaterDidNotFindUpdate:) func didNotFind(_ u: NSObject) { log("no update") }
  @objc(updater:didAbortWithError:) func didAbort(_ u: NSObject, error: NSError) { log("aborted: \(error.localizedDescription)") }
  @objc(updater:didDownloadUpdate:) func didDownload(_ u: NSObject, item: NSObject) { log("downloaded") }
  @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
  func willInstallOnQuit(_ u: NSObject, item: NSObject, immediateInstallationBlock: @escaping () -> Void) -> Bool {
    guard test else { return false }
    log("installing now")
    // after this returns: Sparkle is still marking the update as waiting for the app to quit
    // Without a relaunch (test mode) Sparkle's installer waits for the app to quit instead of quitting it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      immediateInstallationBlock()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
    return true
  }
  @objc(updaterShouldRelaunchApplication:) func shouldRelaunch(_ u: NSObject) -> Bool { !test }
  @objc(updaterWillRelaunchApplication:) func willRelaunch(_ u: NSObject) { log("relaunching") }
}

/// App menu ▸ Acknowledgements (and the About window's link): every third-party piece the app carries, with its
/// licence. The text is Resources/Acknowledgements.txt, made by tools/release/notices.py.
@MainActor final class AcknowledgementsWindow {
  static let shared = AcknowledgementsWindow()
  var window: NSWindow?

  static var file: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("Acknowledgements.txt")
  }

  func show() {
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                       backing: .buffered, defer: false)
      w.title = "Acknowledgements"
      w.isReleasedWhenClosed = false
      let scroll = NSTextView.scrollableTextView()
      let tv = scroll.documentView as! NSTextView
      tv.isEditable = false
      tv.textContainerInset = NSSize(width: 14, height: 14)
      tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      tv.string = Self.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "This build has no Acknowledgements.txt (a development build: tools/release/notices.py makes it)."
      w.contentView = scroll
      w.center()
      window = w
    }
    window?.makeKeyAndOrderFront(nil)
  }
}
