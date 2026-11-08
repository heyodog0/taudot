// taudot-pinch: trackpad pinch and smart zoom for the taudot PDF preview in Rex.
//
// A terminal can't tell a program about a pinch, and Rex uses it to zoom panes. This helper watches trackpad magnify
// events with an event tap. When one starts over a taudot preview pane, it swallows the gesture and sends it to the
// preview over its socket (~/.taudot/rex/preview-*.sock) with its phases; anywhere else the gesture passes through
// untouched, so Rex's pane zoom keeps working elsewhere.
//
// Where is the preview pane on screen? The preview reports the pointer position inside its pane (from mouse motion
// reports) as the pointer moves over it; at that moment the helper reads the pointer's global position, so the
// difference is the pane's origin. Needs the Accessibility permission (README).

import ApplicationServices
import Cocoa

let rexBundle = "com.superlogical.rex"
let sockDir = ProcessInfo.processInfo.environment["TAUDOT_PINCH_DIR"]
  ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".taudot/rex").path
let logPath = sockDir + "/pinch.log"

func log(_ s: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
  if let h = FileHandle(forWritingAtPath: logPath) {
    h.seekToEndOfFile()
    h.write(line.data(using: .utf8)!)
    h.closeFile()
  } else {
    FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
  }
}

/// Pointer position in global screen points, origin top-left (Quartz).
func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func backingScale(at p: CGPoint) -> CGFloat {
  let primaryH = NSScreen.screens.first?.frame.height ?? 0
  let cocoa = NSPoint(x: p.x, y: primaryH - p.y)
  return NSScreen.screens.first(where: { NSMouseInRect(cocoa, $0.frame, false) })?.backingScaleFactor ?? 2
}

final class Preview {
  let path: String
  let fd: Int32
  let handle: FileHandle
  var buf = Data()
  var rect: CGRect? // the pane in global points
  var rectAt = Date.distantPast

  init?(path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    if bytes.count >= MemoryLayout.size(ofValue: addr.sun_path) { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if ok != 0 { close(fd); return nil }
    self.path = path
    self.fd = fd
    self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  func send(_ obj: [String: Any]) {
    guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    d.append(0x0a)
    d.withUnsafeBytes { _ = write(fd, $0.baseAddress, d.count) }
  }
}

final class Helper {
  var previews: [String: Preview] = [:]
  var tap: CFMachPort?
  var target: Preview? // the preview the current pinch goes to
  var pinches = 0, swallowed = 0

  func scan() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: sockDir)) ?? []
    for n in names where n.hasPrefix("preview-") && n.hasSuffix(".sock") {
      let path = sockDir + "/" + n
      if previews[path] != nil { continue }
      guard let p = Preview(path: path) else { continue }
      previews[path] = p
      log("connected \(n)")
      p.handle.readabilityHandler = { [weak self, weak p] h in
        let data = h.availableData
        DispatchQueue.main.async {
          guard let self = self, let p = p else { return }
          if data.isEmpty {
            h.readabilityHandler = nil
            self.previews[p.path] = nil
            if self.target === p { self.target = nil }
            log("closed \(n)")
            return
          }
          self.receive(p, data)
        }
      }
      p.send(["hello": "pinch"])
    }
  }

  func receive(_ p: Preview, _ data: Data) {
    p.buf.append(data)
    while let nl = p.buf.firstIndex(of: 0x0a) {
      let line = p.buf[p.buf.startIndex..<nl]
      p.buf = p.buf[(nl + 1)...]
      guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let h = obj["hover"] as? [String: Any],
        let x = h["x"] as? Double, let y = h["y"] as? Double,
        let pw = h["pw"] as? Double, let ph = h["ph"] as? Double
      else { continue }
      // the pointer is at (x, y) device pixels inside the pane right now
      let g = pointer()
      let s = backingScale(at: g)
      p.rect = CGRect(x: g.x - x / s, y: g.y - y / s, width: pw / s, height: ph / s)
      p.rectAt = Date()
    }
  }

  func previewUnderPointer() -> Preview? {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == rexBundle else { return nil }
    let g = pointer()
    return previews.values.first { p in
      guard let r = p.rect else { return false }
      return r.contains(g) && Date().timeIntervalSince(p.rectAt) < 120
    }
  }

  func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard let ns = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
    switch ns.type {
    case .magnify:
      let ph = ns.phase
      if ph.contains(.began) || (target == nil && ph.contains(.changed) && pinchStartedOverPreview()) {
        target = previewUnderPointer()
        if target != nil { pinches += 1 }
      }
      guard let t = target else { return Unmanaged.passUnretained(event) }
      let phase = ph.contains(.began) ? "began" : ph.contains(.ended) ? "ended" : ph.contains(.cancelled) ? "cancelled" : "changed"
      t.send(["pinch": ["phase": phase, "m": Double(ns.magnification)]])
      swallowed += 1
      if phase == "ended" || phase == "cancelled" {
        target = nil
        log("pinch \(pinches) done, \(swallowed) events so far")
      }
      return nil
    case .smartMagnify:
      if let p = previewUnderPointer() {
        p.send(["smartzoom": [String: Any]()])
        log("smart zoom")
        return nil
      }
      return Unmanaged.passUnretained(event)
    default:
      return Unmanaged.passUnretained(event)
    }
  }

  // A pinch whose `began` we missed (it started before we connected): only take it if it is over a preview.
  func pinchStartedOverPreview() -> Bool { previewUnderPointer() != nil }

  func startTap() -> Bool {
    // NSEvent types: gesture 29, magnify 30, swipe 31, smartMagnify 32
    let mask: CGEventMask = (1 << 29) | (1 << 30) | (1 << 32)
    let me = Unmanaged.passUnretained(self).toOpaque()
    guard let t = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
      callback: { _, type, event, refcon in
        Unmanaged<Helper>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
      }, userInfo: me)
    else { return false }
    tap = t
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    return true
  }
}

// one at a time
let mine = Bundle.main.bundleIdentifier ?? "app.taudot.pinch"
if NSRunningApplication.runningApplications(withBundleIdentifier: mine).count > 1 { exit(0) }

try? FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
// TAUDOT_PINCH_NOPROMPT=1: don't ask for the permission (tests)
let prompt = ProcessInfo.processInfo.environment["TAUDOT_PINCH_NOPROMPT"] == nil
let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
log("started, accessibility \(trusted ? "granted" : "not granted yet")")

var tapStarted = helper.startTap()
if !tapStarted { log("event tap not allowed yet: grant Accessibility to TaudotPinch.app") }
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
  helper.scan()
  if !tapStarted {
    tapStarted = helper.startTap()
    if tapStarted { log("event tap on") }
  }
}
helper.scan()
app.run()
