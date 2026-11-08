// act PID STEP...: input posted to that process only (CGEvent.postToPid), never to the app in front.
//   k:CODE[:MODS]   a key (virtual key code), MODS from c (⌘) a (⌥) s (⇧) t (⌃)
//   t:TEXT          typed at a human pace
//   d:X,Y           a double-click at global screen points, posted to the process
//   M:X,Y           the pointer glides there (only while frontmost)
//   S:X,Y,N         glide there and scroll N steps (positive: down), only while frontmost
//   C:X,Y           a real single click, only while this process is frontmost
//   D:X,Y           the same as a real mouse (HID), only while this process is the frontmost app; skipped otherwise
//   w:MS            wait
//   swiftc -O -o /tmp/te/act site/demo/act.swift
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let src = CGEventSource(stateID: .hidSystemState)
// ACTLOG=FILE: every pointer event this posts, as "EPOCH X Y move|down|up" in screen points, so camera.py can draw the
// pointer (large, with click ripples) over a recording made without it.
let ptrLog: FileHandle? = ProcessInfo.processInfo.environment["ACTLOG"].flatMap { p in
  if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
  let h = FileHandle(forWritingAtPath: p); h?.seekToEndOfFile(); return h }
func log(_ p: CGPoint, _ what: String) {
  ptrLog?.write(String(format: "%.4f %.1f %.1f %@\n", Date().timeIntervalSince1970, p.x, p.y, what).data(using: .utf8)!)
}
func flags(_ s: Substring) -> CGEventFlags {
  var f: CGEventFlags = []
  if s.contains("c") { f.insert(.maskCommand) }; if s.contains("a") { f.insert(.maskAlternate) }
  if s.contains("s") { f.insert(.maskShift) }; if s.contains("t") { f.insert(.maskControl) }
  return f
}
func key(_ code: CGKeyCode, _ f: CGEventFlags) {
  for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!; e.flags = f; e.postToPid(pid); usleep(12_000) }
}
func type(_ s: String) {
  for c in s {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
      var u = Array(String(c).utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); e.postToPid(pid); usleep(10_000)
    }
    usleep(useconds_t(45_000 + Int.random(in: 0...55_000) + (c == " " ? 40_000 : 0)))
  }
}
func doubleClick(_ p: CGPoint) {
  CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.postToPid(pid)
  usleep(80_000)
  for n in 1...2 {
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
      let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
      e.setIntegerValueField(.mouseEventClickState, value: Int64(n)); e.postToPid(pid); usleep(30_000)
    }
    usleep(60_000)
  }
}
/// The pointer glides to p (~450 ms, eased), so a recording shows where it goes.
func glide(_ p: CGPoint) {
  let a = CGEvent(source: nil)!.location
  let n = 27
  for i in 1...n {
    let t = Double(i) / Double(n), e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    let q = CGPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)!.post(tap: .cghidEventTap); log(q, "move")
    usleep(16_000)
  }
}
func hidScroll(_ p: CGPoint, _ lines: Int32) {
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("not front: scroll skipped"); return }
  glide(p)
  for _ in 0..<abs(lines) {
    CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: lines < 0 ? 24 : -24, wheel2: 0, wheel3: 0)!.post(tap: .cghidEventTap)
    usleep(16_000)
  }
}
func hidClick(_ p: CGPoint) {
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("not front: click skipped"); return }
  glide(p)
  usleep(150_000)
  for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap); log(p, t == .leftMouseDown ? "down" : "up"); usleep(40_000)
  }
}
func hidDoubleClick(_ p: CGPoint) {
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { print("not front: click skipped"); return }
  glide(p)
  usleep(150_000)
  for n in 1...2 {
    for t in [CGEventType.leftMouseDown, .leftMouseUp] {
      let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
      e.setIntegerValueField(.mouseEventClickState, value: Int64(n)); e.post(tap: .cghidEventTap); log(p, t == .leftMouseDown ? "down" : "up"); usleep(30_000)
    }
    usleep(60_000)
  }
}
print("front", NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, "app", pid)
log(CGEvent(source: nil)!.location, "move")
for step in CommandLine.arguments.dropFirst(2) {
  let parts = step.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
  switch parts[0] {
  case "k": key(CGKeyCode(parts[1])!, parts.count > 2 ? flags(parts[2]) : [])
  case "t": type(String(step.dropFirst(2)))
  case "d": let xy = parts[1].split(separator: ",").map { Double($0)! }; doubleClick(CGPoint(x: xy[0], y: xy[1]))
  case "M": let xy = parts[1].split(separator: ",").map { Double($0)! }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { glide(CGPoint(x: xy[0], y: xy[1])) }
  case "S": let v = parts[1].split(separator: ",").map { Double($0)! }; hidScroll(CGPoint(x: v[0], y: v[1]), Int32(v[2]))
  case "C": let xy = parts[1].split(separator: ",").map { Double($0)! }; hidClick(CGPoint(x: xy[0], y: xy[1]))
  case "D": let xy = parts[1].split(separator: ",").map { Double($0)! }; hidDoubleClick(CGPoint(x: xy[0], y: xy[1]))
  case "w": usleep(useconds_t(Int(parts[1])! * 1000))
  default: print("unknown step", step)
  }
}
