// probe: launch the app (or attach to a PID), time its windows and record what one of them shows, frame by frame.
// Nothing in the app is changed: what is measured is what reaches the screen.
//
//   swiftc -O -swift-version 5 -o probe probe.swift
//   probe --out DIR --seconds S [--match TITLE] [--script FILE] [--scale N] -- APP ARGS...
//   probe --out DIR --seconds S --pid PID --match TITLE [--script FILE]
// Off-screen only: if any window of the app comes onto a display, probe stops the app and exits 3 (the rule in
// docs/developing.md). --allow-onscreen lifts that, for opt-in runs (PERF_ONSCREEN=1 in the scripts).
//
// DIR/windows.tsv   t  id  pid  alpha  onscreen  x y w h  title     (every change of any window of the app)
// DIR/frames.bin    per changed frame: f64 t, u16 w, u16 h, w*h u8 luminance (mean of scale x scale blocks)
// DIR/actions.tsv   t  what     (script steps, as they were sent)
// DIR/ax.json       the window's split views and their panes (AX frames, window points), at the end
// DIR/last.png      the last captured frame, full size
// DIR/clock.txt     t0, the host time (s) all these times count from
// All times are seconds since the launch (CACurrentMediaTime, the clock of CMSampleBuffer timestamps).
//
// Script lines: `at SECONDS ACTION`, ACTION one of
//   keys TEXT          type TEXT (each character a key down/up, 15 ms apart)
//   key [cmd+][shift+][opt+][ctrl+]NAME   one key: a letter, a digit, or return esc tab space left right up down , \ j...
//   scroll DY N        N trackpad-like scroll events of DY points at 120 Hz over the window's middle (phase began/changed/ended)
//   type MS TEXT       TEXT one character every MS ms, each logged ("char X"), for keystroke-to-glyph times
//   menu TITLE         press the menu item TITLE through Accessibility (Settings…, Show/Hide Claude, ...)
//   press LABEL        AXPress the element titled or described LABEL (a tab's radio button, a button)
//   select LABEL       select the table row with an element labelled LABEL (a file tree row), through Accessibility
//   mark NAME          only logs NAME (for the analysis)
// `wait-window TITLE` as the first line delays the clock of the script until that window is on screen.
import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)
var argv = Array(CommandLine.arguments.dropFirst())
var outDir = "", seconds = 10.0, match: String? = nil, scriptPath: String? = nil, scale = 8, attach: pid_t? = nil
var allowOnScreen = false
var appArgs: [String] = []
while !argv.isEmpty {
  let a = argv.removeFirst()
  switch a {
  case "--out": outDir = argv.removeFirst()
  case "--seconds": seconds = Double(argv.removeFirst())!
  case "--match": match = argv.removeFirst()
  case "--script": scriptPath = argv.removeFirst()
  case "--scale": scale = Int(argv.removeFirst())!
  case "--pid": attach = pid_t(argv.removeFirst())!
  case "--allow-onscreen": allowOnScreen = true
  case "--": appArgs = argv; argv = []
  default: FileHandle.standardError.write("probe: unknown \(a)\n".data(using: .utf8)!); exit(2)
  }
}
guard !outDir.isEmpty, attach != nil || !appArgs.isEmpty else {
  FileHandle.standardError.write("usage: probe --out DIR --seconds S [--match TITLE] [--script FILE] -- APP ARGS...\n".data(using: .utf8)!)
  exit(2)
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func open(_ name: String) -> FileHandle {
  let p = outDir + "/" + name
  FileManager.default.createFile(atPath: p, contents: nil)
  return FileHandle(forWritingAtPath: p)!
}
let windowsOut = open("windows.tsv"), framesOut = open("frames.bin"), actionsOut = open("actions.tsv")
let lock = NSLock()

// MARK: launch

// The first shareable-content query takes ~0.5 s: make it before the clock starts.
let warm = DispatchSemaphore(value: 0)
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { _, _ in warm.signal() }
warm.wait()
var t0 = CACurrentMediaTime()
var pid: pid_t
if let a = attach {
  pid = a
} else {
  var p: pid_t = 0
  var cargs = appArgs.map { strdup($0) } + [nil]
  t0 = CACurrentMediaTime()
  let rc = posix_spawn(&p, appArgs[0], nil, nil, &cargs, environ)
  guard rc == 0 else { FileHandle.standardError.write("probe: spawn failed \(rc)\n".data(using: .utf8)!); exit(1) }
  pid = p
}
func now() -> Double { CACurrentMediaTime() - t0 }
// DIR/clock.txt: t0 in host seconds (CACurrentMediaTime), to line these times up with the app's own probes.
try? String(format: "%.6f\n", t0).write(toFile: outDir + "/clock.txt", atomically: true, encoding: .utf8)
print(String(format: "probe: pid %d", pid))

// MARK: windows

struct Win: Equatable { var alpha: Double; var on: Bool; var b: CGRect; var title: String }
var known: [UInt32: Win] = [:]
var target: UInt32? = nil
var targetOnScreenAt: Double? = nil

func pollWindows() {
  guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return }
  let t = now()
  for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    let id = w[kCGWindowNumber as String] as! UInt32
    let bd = w[kCGWindowBounds as String] as! [String: Double]
    let rect = CGRect(x: bd["X"]!, y: bd["Y"]!, width: bd["Width"]!, height: bd["Height"]!)
    let cur = Win(alpha: w[kCGWindowAlpha as String] as? Double ?? 0, on: w[kCGWindowIsOnscreen as String] as? Bool ?? false,
                  b: rect, title: w[kCGWindowName as String] as? String ?? "")
    if known[id] != cur {
      known[id] = cur
      windowsOut.write(String(format: "%.4f\t%u\t%d\t%.2f\t%d\t%.0f %.0f %.0f %.0f\t%@\n", t, id, pid, cur.alpha, cur.on ? 1 : 0,
                              rect.minX, rect.minY, rect.width, rect.height, cur.title).data(using: .utf8)!)
    }
    if target == nil, rect.width >= 400, rect.height >= 300, match == nil || cur.title == match {
      target = id
    }
    // Off-screen runs only (docs/developing.md): a window of the app on any display stops the run at once.
    if !allowOnScreen, cur.on, rect.width > 0, displaysUnion().intersects(rect) {
      kill(pid, SIGTERM)
      FileHandle.standardError.write("probe: a window of the app came on screen (\(rect)); stopped it. Use an app with TAUDOT_OFFSCREEN, or --allow-onscreen.\n".data(using: .utf8)!)
      exit(3)
    }
    if id == target, targetOnScreenAt == nil, cur.on, cur.alpha > 0 {
      targetOnScreenAt = t
      print(String(format: "probe: window %u on screen at %.3f (%@)", id, t, cur.title))
    }
  }
}

func windowOnScreen(_ title: String) -> Bool {
  known.values.contains { $0.title == title && $0.on && $0.alpha > 0 }
}

// MARK: capture

final class Out: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  var frames = 0
  var lastBody = Data()
  var statuses: [Int: Int] = [:]
  var last: CVPixelBuffer?
  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
    if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
       let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { lock.lock(); statuses[raw, default: 0] += 1; lock.unlock(); return }
    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds - t0
    CVPixelBufferLockBaseAddress(px, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    let W = CVPixelBufferGetWidth(px), H = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
    let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
    let w = W / scale, h = H / scale
    var data = Data(count: 12 + w * h)
    data.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) in
      var tt = t
      memcpy(d.baseAddress!, &tt, 8)
      var ww = UInt16(w), hh = UInt16(h)
      memcpy(d.baseAddress! + 8, &ww, 2)
      memcpy(d.baseAddress! + 10, &hh, 2)
      let o = d.baseAddress!.assumingMemoryBound(to: UInt8.self) + 12
      // The mean of each scale x scale block (BGRA): a caret or a period still moves its block.
      var acc = [Int](repeating: 0, count: w)
      for y in 0..<h {
        for i in 0..<w { acc[i] = 0 }
        for yy in 0..<scale {
          let r = base + (y * scale + yy) * row
          for x in 0..<w {
            var s = 0
            for xx in 0..<scale {
              let p = r + (x * scale + xx) * 4
              let r2: Int = Int(p[2]) * 54, g: Int = Int(p[1]) * 183
              s += r2 + g + Int(p[0]) * 19
            }
            acc[x] += s
          }
        }
        for x in 0..<w { o[y * w + x] = UInt8(acc[x] / (scale * scale * 256)) }
      }
    }
    // Only frames that differ from the one before (the stream repeats unchanged frames ~100 times a second).
    let body = data.subdata(in: 12..<data.count)
    lock.lock()
    if body != lastBody { framesOut.write(data); frames += 1; lastBody = body }
    lock.unlock()
    last = px
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    FileHandle.standardError.write("probe: stream stopped: \(error)\n".data(using: .utf8)!)
  }
}
let out = Out()
var stream: SCStream?

func startCapture(_ id: UInt32) async {
  // The window may not be in the shareable list yet on the first tries.
  for _ in 0..<200 {
    if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
       let w = c.windows.first(where: { $0.windowID == id }) {
      // Looked up while the window is still hidden (the lookup takes ~100 ms); the stream starts once it is ordered in
      // (one started on a window that isn't yet delivers nothing, ever).
      while !(DispatchQueue.main.sync { known[id]?.on ?? false }) && now() < seconds { try? await Task.sleep(for: .milliseconds(1)) }
      let f = SCContentFilter(desktopIndependentWindow: w)
      let cfg = SCStreamConfiguration()
      let s = NSScreen.main?.backingScaleFactor ?? 2
      cfg.width = Int(w.frame.width * s)
      cfg.height = Int(w.frame.height * s)
      cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
      cfg.queueDepth = 8
      cfg.showsCursor = false
      cfg.pixelFormat = kCVPixelFormatType_32BGRA
      let st = SCStream(filter: f, configuration: cfg, delegate: out)
      try! st.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
      do { try await st.startCapture() } catch { print("probe: capture failed: \(error)"); return }
      stream = st
      print(String(format: "probe: capturing window %u from %.3f", id, now()))
      return
    }
    try? await Task.sleep(for: .milliseconds(5))
  }
  print("probe: window \(id) never became shareable")
}

// MARK: input

let keyCodes: [String: CGKeyCode] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
  "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
  "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
  ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "esc": 53,
  "left": 123, "right": 124, "down": 125, "up": 126,
]

func post(_ code: CGKeyCode, flags: CGEventFlags, text: String? = nil) {
  for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
    e.flags = flags
    if let text { let u = Array(text.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u) }
    e.postToPid(pid)
  }
}

func act(_ line: String) async {
  let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
  guard let verb = parts.first else { return }
  let rest = parts.count > 1 ? parts[1] : ""
  actionsOut.write(String(format: "%.4f\t%@\n", now(), line).data(using: .utf8)!)
  switch verb {
  case "keys":
    for ch in rest {
      let s = String(ch)
      let code = keyCodes[s.lowercased()] ?? (s == " " ? 49 : 0)
      post(code, flags: ch.isUppercase ? .maskShift : [], text: s)
      try? await Task.sleep(for: .milliseconds(15))
    }
  case "key":
    var flags: CGEventFlags = []
    var name = rest
    while let r = name.range(of: "+"), r.lowerBound != name.startIndex {
      let m = String(name[..<r.lowerBound]); name = String(name[r.upperBound...])
      switch m { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift)
      case "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break }
    }
    post(keyCodes[name] ?? 0, flags: flags, text: name.count == 1 ? name : nil)
  case "scroll":
    let a = rest.split(separator: " ").compactMap { Double($0) }
    guard a.count == 2, let id = target, let w = known[id] else { return }
    let mid = CGPoint(x: w.b.midX, y: w.b.midY)
    for i in 0..<Int(a[1]) {
      guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(a[0]), wheel2: 0, wheel3: 0) else { continue }
      e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      e.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : (i == Int(a[1]) - 1 ? 4 : 2))
      e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: a[0])
      e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: a[0])
      e.location = mid
      e.postToPid(pid)
      try? await Task.sleep(for: .microseconds(8333))
    }
  case "type":
    // type MS TEXT: one character every MS milliseconds, each logged as its own action ("char X").
    let f = rest.split(separator: " ", maxSplits: 1).map(String.init)
    guard f.count == 2, let ms = Int(f[0]) else { return }
    for ch in f[1] {
      let s = String(ch)
      actionsOut.write(String(format: "%.4f\tchar %@\n", now(), s).data(using: .utf8)!)
      post(keyCodes[s.lowercased()] ?? (s == " " ? 49 : 0), flags: ch.isUppercase ? .maskShift : [], text: s)
      try? await Task.sleep(for: .milliseconds(ms))
    }
  case "select":
    // select LABEL: select the table row holding an element labelled LABEL (the file tree's rows), through AX.
    if !selectRow(rest) { actionsOut.write(String(format: "%.4f\trow not found: %@\n", now(), rest).data(using: .utf8)!) }
  case "press":
    // press LABEL: AXPress the first element titled or described LABEL (a radio button, a button), in any window.
    if !pressLabel(rest) { actionsOut.write(String(format: "%.4f\tnot found: %@\n", now(), rest).data(using: .utf8)!) }
  case "menu":
    // menu TITLE: press the app's menu item with that title (through Accessibility, as a click on the menu would).
    if !pressMenu(rest) { actionsOut.write(String(format: "%.4f\tmenu not found: %@\n", now(), rest).data(using: .utf8)!) }
  default: break
  }
}

func selectRow(_ label: String) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
  }
  func find(_ e: AXUIElement, _ row: AXUIElement?, _ depth: Int) -> AXUIElement? {
    let role = attr(e, kAXRoleAttribute) as? String
    let r = role == "AXRow" ? e : row
    for k in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, "AXLabel"] {
      if let s = attr(e, k) as? String, s == label, let r { return r }
    }
    if depth > 14 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, r, depth + 1) { return f } }
    return nil
  }
  for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    if let row = find(w, nil, 0) {
      // The table takes the focus too, so a Return that follows opens the row.
      if let table = attr(row, kAXParentAttribute) { AXUIElementSetAttributeValue(table as! AXUIElement, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
      return AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
    }
  }
  return false
}

func pressMenu(_ title: String) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
  }
  func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXMenuItem", (attr(e, kAXTitleAttribute) as? String) == title { return e }
    if depth > 6 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let r = find(c, depth + 1) { return r } }
    return nil
  }
  guard let bar = attr(app, kAXMenuBarAttribute), let item = find(bar as! AXUIElement, 0) else { return false }
  return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

// MARK: AX

func axFrames() -> [[String: Any]] {
  let app = AXUIElementCreateApplication(pid)
  var res: [[String: Any]] = []
  func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
  }
  func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
  }
  func walk(_ e: AXUIElement, depth: Int) {
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    if ["AXSplitGroup", "AXSplitter", "AXWindow"].contains(role), let f = frame(e) {
      res.append(["role": role, "depth": depth, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height,
                  "title": attr(e, kAXTitleAttribute) as? String ?? ""])
    }
    if depth > 8 { return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1) }
  }
  for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, depth: 0) }
  return res
}

// MARK: run

let script: [(Double, String)] = {
  guard let p = scriptPath, let s = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
  return s.split(separator: "\n").compactMap { l in
    let f = l.split(separator: " ", maxSplits: 2).map(String.init)
    guard f.count == 3, f[0] == "at", let t = Double(f[1]) else { return nil }
    return (t, f[2])
  }
}()
let waitFor: String? = {
  guard let p = scriptPath, let s = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
  let first = s.split(separator: "\n").first.map(String.init) ?? ""
  return first.hasPrefix("wait-window ") ? String(first.dropFirst(12)) : nil
}()

Task { @MainActor in
  let poller = Thread {
    while true { DispatchQueue.main.sync { pollWindows() }; usleep(2000) }
  }
  poller.start()
  while target == nil && now() < seconds { try? await Task.sleep(for: .milliseconds(2)) }
  if let id = target { await startCapture(id) } else { print("probe: no window") }
  Task { @MainActor in
    var start = now()
    if let w = waitFor {
      while !windowOnScreen(w) && now() < seconds { try? await Task.sleep(for: .milliseconds(5)) }
      start = now()
      actionsOut.write(String(format: "%.4f\twindow %@\n", start, w).data(using: .utf8)!)
    }
    for (t, a) in script {
      let d = start + t - now()
      if d > 0 { try? await Task.sleep(for: .milliseconds(Int(d * 1000))) }
      await act(a)
    }
  }
  while now() < seconds { try? await Task.sleep(for: .milliseconds(20)) }
  if let s = stream { try? await s.stopCapture() }
  let ax = axFrames()
  if let d = try? JSONSerialization.data(withJSONObject: ax, options: [.prettyPrinted]) {
    FileManager.default.createFile(atPath: outDir + "/ax.json", contents: d)
  }
  // The app's process tree, for the steady-state sampler and the teardown.
  let ps = Process()
  ps.executableURL = URL(fileURLWithPath: "/bin/ps")
  ps.arguments = ["-ax", "-o", "pid=,ppid=,comm="]
  let pipe = Pipe(); ps.standardOutput = pipe
  try? ps.run()
  let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  var tree: Set<Int32> = [pid], lines: [(Int32, Int32, String)] = []
  for l in text.split(separator: "\n") {
    let f = l.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    if f.count == 3, let a = Int32(f[0]), let b = Int32(f[1]) { lines.append((a, b, String(f[2]))) }
  }
  var grew = true
  while grew { grew = false; for (a, b, _) in lines where tree.contains(b) && !tree.contains(a) { tree.insert(a); grew = true } }
  let procs = lines.filter { tree.contains($0.0) }.map { "\($0.0)\t\($0.1)\t\($0.2)" }.joined(separator: "\n")
  FileManager.default.createFile(atPath: outDir + "/procs.tsv", contents: (procs + "\n").data(using: .utf8))
  if let px = out.last {
    let ci = CIImage(cvPixelBuffer: px)
    let rep = NSBitmapImageRep(ciImage: ci)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir + "/last.png"))
  }
  print("probe: \(out.frames) frames, other statuses \(out.statuses)")
  exit(0)
}
RunLoop.main.run()

/// Every display's bounds, in CGWindowList's coordinates (top-left origin).
func displaysUnion() -> CGRect {
  var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
  CGGetActiveDisplayList(16, &ids, &n)
  return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
}

func pressLabel(_ label: String) -> Bool {
  let app = AXUIElementCreateApplication(pid)
  func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
  }
  func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
    if (attr(e, kAXTitleAttribute) as? String) == label || (attr(e, kAXDescriptionAttribute) as? String) == label { return e }
    if depth > 14 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, depth + 1) { return f } }
    return nil
  }
  for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
    if let e = find(w, 0) { return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success }
  }
  return false
}
