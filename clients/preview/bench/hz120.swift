// hz120: a small window that animates on every display refresh, asking for 120 fps (CADisplayLink,
// preferredFrameRateRange 120). Used to check that scrcap can see 120 Hz on this display.
//   hz120 X Y W H SECONDS      (window content rect in global points, top-left origin)
import AppKit
import QuartzCore

let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let (x, y, w, h, secs) = a.count >= 5 ? (a[0], a[1], a[2], a[3], a[4]) : (100, 100, 300, 200, 4)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
print("maximumFramesPerSecond", screen.maximumFramesPerSecond)
let rect = NSRect(x: x, y: screen.frame.height - y - h, width: w, height: h)
let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
win.level = .floating
win.backgroundColor = .black
let bar = CALayer()
bar.backgroundColor = NSColor.white.cgColor
bar.frame = CGRect(x: 0, y: 0, width: 12, height: h)
win.contentView!.wantsLayer = true
win.contentView!.layer!.addSublayer(bar)
win.orderFrontRegardless()
var ticks = 0
final class T: NSObject {
  @objc func step(_ l: CADisplayLink) {
    ticks += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bar.frame.origin.x = CGFloat((ticks * 4) % Int(w - 12))
    CATransaction.commit()
  }
}
let t = T()
let link = win.contentView!.displayLink(target: t, selector: #selector(T.step(_:)))
link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
link.add(to: .main, forMode: .common)
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
  print("ticks", ticks, "per second", Double(ticks) / secs)
  exit(0)
}
app.run()
