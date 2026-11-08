// backdrop WINDOW_NUMBER X Y W H: a plain window in Taudot's ground colour, kept directly behind that window
// (screen points, top-left origin), so its translucent sidebar always has the same thing behind it while recording.
// Runs until killed. Never takes focus.
import AppKit
let a = CommandLine.arguments
let wid = Int(a[1])!, r = a[2...5].map { CGFloat(Double($0)!) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let screenH = NSScreen.screens[0].frame.height
let pad: CGFloat = 60
let frame = NSRect(x: r[0] - pad, y: screenH - r[1] - r[3] - pad, width: r[2] + 2 * pad, height: r[3] + 2 * pad)
let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
w.backgroundColor = NSColor(srgbRed: 0x06 / 255.0, green: 0x1a / 255.0, blue: 0x1d / 255.0, alpha: 1)
w.ignoresMouseEvents = true
w.hasShadow = false
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in w.order(.below, relativeTo: wid) }
w.order(.below, relativeTo: wid)
print("backdrop up"); fflush(stdout)
app.run()
