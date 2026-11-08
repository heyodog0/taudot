// scrcap: records a screen rectangle with ScreenCaptureKit and writes the frames that actually changed to stdout.
//
//   scrcap X Y W H SECONDS [FPS]        (global screen points, top-left origin)
//
// Each frame: a 16-byte header (u64 display time in ns, u32 width, u32 height, little-endian) and then width*height
// bytes of luma (the Y plane, one byte per pixel, native pixels). Only frames ScreenCaptureKit marks `complete`
// (the content changed) are written, with the time the compositor displayed them, so the stream is what reached the
// screen. Counts go to stderr at the end.

import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

let a = CommandLine.arguments
guard a.count >= 6, let x = Double(a[1]), let y = Double(a[2]), let w = Double(a[3]), let h = Double(a[4]),
  let secs = Double(a[5])
else {
  FileHandle.standardError.write("usage: scrcap X Y W H SECONDS [FPS]\n".data(using: .utf8)!)
  exit(2)
}
let fps = a.count > 6 ? Int32(a[6]) ?? 120 : 120

var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
let out = FileHandle.standardOutput
var complete = 0, idle = 0, other = 0

final class Sink: NSObject, SCStreamOutput {
  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
      let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = atts.first, let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
    else { return }
    if status == .idle { idle += 1; return }
    guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { other += 1; return }
    complete += 1
    let mach = (info[.displayTime] as? UInt64) ?? mach_absolute_time()
    let ns = mach * UInt64(tb.numer) / UInt64(tb.denom)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
    var d = Data(capacity: 16 + pw * ph)
    var hdr = (ns.littleEndian, UInt32(pw).littleEndian, UInt32(ph).littleEndian)
    withUnsafeBytes(of: &hdr.0) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: &hdr.1) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: &hdr.2) { d.append(contentsOf: $0) }
    for row in 0..<ph { d.append(base.advanced(by: row * bpr).assumingMemoryBound(to: UInt8.self), count: pw) }
    out.write(d)
  }
}

let sink = Sink()
Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let pt = CGPoint(x: x, y: y)
    guard let display = content.displays.first(where: { $0.frame.contains(pt) }) ?? content.displays.first else {
      FileHandle.standardError.write("no display\n".data(using: .utf8)!)
      exit(1)
    }
    let scale = Double(display.width) > 0 ? Double(CGDisplayPixelsWide(display.displayID)) / Double(display.width) : 2
    let backing = NSScreenScale(display.displayID)
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = CGRect(x: x - display.frame.minX, y: y - display.frame.minY, width: w, height: h)
    cfg.width = Int(w * backing)
    cfg.height = Int(h * backing)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
    cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    cfg.showsCursor = false
    cfg.queueDepth = 8
    _ = scale
    // SCRCAP_WINDOW=<window id>: capture that window alone (its own update rate), rect relative to it
    var filter = SCContentFilter(display: display, excludingWindows: [])
    if let wid = ProcessInfo.processInfo.environment["SCRCAP_WINDOW"].flatMap(UInt32.init),
      let win = content.windows.first(where: { $0.windowID == wid })
    {
      filter = SCContentFilter(desktopIndependentWindow: win)
      cfg.sourceRect = CGRect(x: x - win.frame.minX, y: y - win.frame.minY, width: w, height: h)
    }
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "scrcap"))
    try await stream.startCapture()
    FileHandle.standardError.write("started \(Int(w * backing))x\(Int(h * backing)) at up to \(fps) fps\n".data(using: .utf8)!)
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    try await stream.stopCapture()
    FileHandle.standardError.write("complete \(complete) idle \(idle) other \(other)\n".data(using: .utf8)!)
    exit(0)
  } catch {
    FileHandle.standardError.write("scrcap: \(error)\n".data(using: .utf8)!)
    exit(1)
  }
}

/// Backing scale of a display (pixels per point), from its mode.
func NSScreenScale(_ id: CGDirectDisplayID) -> Double {
  guard let mode = CGDisplayCopyDisplayMode(id) else { return 2 }
  return Double(mode.pixelWidth) / Double(mode.width)
}

dispatchMain()
