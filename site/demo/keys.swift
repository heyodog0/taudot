// keys PID: ⌥⌘↩, then the reply text one character at a time, then ↩ — posted to that process only
// (CGEvent.postToPid), never to whatever app is in front.
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let text = CommandLine.arguments[2]
let src = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
    e.flags = flags; e.postToPid(pid); usleep(12_000)
  }
}
func char(_ c: Character) {
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
    var u = Array(String(c).utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
    e.postToPid(pid); usleep(10_000)
  }
}
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
print("front", front, "app", pid)
key(36, [.maskAlternate, .maskCommand])
usleep(700_000)
for c in text {
  char(c)
  usleep(useconds_t(45_000 + Int.random(in: 0...55_000) + (c == " " ? 40_000 : 0) + (".,".contains(c) ? 140_000 : 0)))
}
usleep(400_000)
key(36)
