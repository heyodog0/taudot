// review_capture: record one window with ScreenCaptureKit and, in every captured frame, find the measurement
// markers: pure green squares (cards, TAUDOT_MARGIN_MARKERS=1) left of SPLIT, magenta and cyan cells (text lines,
// marked through Neovim) right of it. One line per frame on stdout:
//   <t> G <y,y,...> M <y,...> C <y,...>     (tops of each marker blob, in points from the window's top)
//   swiftc -O -o review_capture review_capture.swift && ./review_capture WINDOW_ID SECONDS SPLIT_PT
// A negative SPLIT_PT (the floating card): green anywhere, the line markers right of |SPLIT_PT|.
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 4, let wid = UInt32(args[1]), let seconds = Double(args[2]), let split = Double(args[3]) else {
  FileHandle.standardError.write("usage: review_capture WINDOW_ID SECONDS SPLIT_PT\n".data(using: .utf8)!)
  exit(2)
}

final class Out: NSObject, SCStreamOutput, @unchecked Sendable {
  let split: Double
  var frames = 0
  init(split: Double) { self.split = split }

  func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
    // Only complete frames (idle repeats carry no new content but are still frames on screen: keep them too).
    if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
       let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete && st != .idle { return }
    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
    CVPixelBufferLockBaseAddress(px, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px)
    let base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
    let scale = 2.0
    let anywhere = split < 0
    let sx = min(w, Int(abs(split) * scale))
    var g: [Int] = [], m: [Int] = [], c: [Int] = []
    var inG = false, inM = false, inC = false
    for y in 0..<h {
      let row = base + y * bpr
      var hasG = false, hasM = false, hasC = false
      var x = 0
      while x < w {
        let b = Int(row[x * 4]), gg = Int(row[x * 4 + 1]), r = Int(row[x * 4 + 2])
        if x < sx || anywhere {
          if gg > 200 && r < 70 && b < 70 { hasG = true }
        }
        if x >= sx {
          if r > 200 && b > 200 && gg < 70 { hasM = true }
          if gg > 200 && b > 200 && r < 70 { hasC = true }
        }
        x += (x < sx || anywhere) ? 2 : 3
      }
      if hasG && !inG { g.append(y) }
      if hasM && !inM { m.append(y) }
      if hasC && !inC { c.append(y) }
      inG = hasG; inM = hasM; inC = hasC
    }
    func pts(_ a: [Int]) -> String { a.map { String(format: "%.1f", Double($0) / scale) }.joined(separator: ",") }
    print(String(format: "%.4f", t), "G", pts(g), "M", pts(m), "C", pts(c))
    frames += 1
  }
}

_ = NSApplication.shared  // a window-server connection, which ScreenCaptureKit expects
let out = Out(split: split)
Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let win = content.windows.first(where: { $0.windowID == wid }) else {
      FileHandle.standardError.write("no window \(wid)\n".data(using: .utf8)!)
      exit(1)
    }
    let cfg = SCStreamConfiguration()
    cfg.width = Int(win.frame.width * 2)
    cfg.height = Int(win.frame.height * 2)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.colorSpaceName = CGColorSpace.sRGB
    cfg.showsCursor = false
    cfg.queueDepth = 8
    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
    try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(seconds))
    try await stream.stopCapture()
    FileHandle.standardError.write("frames \(out.frames)\n".data(using: .utf8)!)
    exit(0)
  } catch {
    FileHandle.standardError.write("capture: \(error)\n".data(using: .utf8)!)
    exit(1)
  }
}
RunLoop.main.run()
