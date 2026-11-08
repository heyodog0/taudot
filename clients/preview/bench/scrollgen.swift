// scrollgen: posts scroll events like a trackpad (continuous, pixel deltas, with gesture and momentum phases) or a
// mouse wheel (line deltas) at a screen point, at a fixed rate. Needs Accessibility for the process posting them.
//   scrollgen X Y SECONDS DY_PER_EVENT HZ [trackpad|wheel]      (points; DY < 0 scrolls content up/back)
//   scrollgen --check      prints whether posting is allowed
import ApplicationServices
import CoreGraphics
import Foundation

let a = CommandLine.arguments
if a.count > 1 && a[1] == "--check" {
  print("accessibility trusted:", AXIsProcessTrusted())
  exit(0)
}
guard a.count >= 6, let x = Double(a[1]), let y = Double(a[2]), let secs = Double(a[3]), let dy = Double(a[4]),
  let hz = Double(a[5])
else { print("usage: scrollgen X Y SECONDS DY HZ [trackpad|wheel]"); exit(2) }
let trackpad = a.count < 7 || a[6] == "trackpad"
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
let src = CGEventSource(stateID: .hidSystemState)
let n = Int(secs * hz)
let period = 1.0 / hz
let start = Date()
for i in 0..<n {
  let ev: CGEvent?
  if trackpad {
    ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
    ev?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    // scroll phase: began, changed, ended (kCGScrollPhase*: 1 began, 2 changed, 4 ended)
    ev?.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : (i == n - 1 ? 4 : 2))
  } else {
    ev = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
  }
  ev?.location = CGPoint(x: x, y: y)
  ev?.post(tap: .cghidEventTap)
  let next = start.addingTimeInterval(Double(i + 1) * period)
  let wait = next.timeIntervalSinceNow
  if wait > 0 { Thread.sleep(forTimeInterval: wait) }
}
