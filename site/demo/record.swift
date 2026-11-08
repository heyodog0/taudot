// record: one window to a .mov with ScreenCaptureKit, for the site's clips. The window's own pixels (desktop
// independent: other windows over it don't show), Retina size, 60 fps, no cursor, no audio. Prints "recording" when
// the first frame is written, then stops after SECONDS.
//   swiftc -O -o /tmp/td/record site/demo/record.swift && /tmp/td/record WINDOW_ID SECONDS OUT.mov
import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let a = CommandLine.arguments
guard a.count == 4, let wid = UInt32(a[1]), let secs = Double(a[2]) else {
  FileHandle.standardError.write("usage: record WINDOW_ID SECONDS OUT.mov\n".data(using: .utf8)!)
  exit(2)
}
let out = URL(fileURLWithPath: a[3])
try? FileManager.default.removeItem(at: out)

final class Delegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
  func recordingOutputDidStartRecording(_ r: SCRecordingOutput) { print(String(format: "recording %.4f", Date().timeIntervalSince1970)); fflush(stdout) }
  func recordingOutput(_ r: SCRecordingOutput, didFailWithError e: Error) { FileHandle.standardError.write("failed: \(e)\n".data(using: .utf8)!); exit(1) }
  func stream(_ s: SCStream, didStopWithError e: Error) { FileHandle.standardError.write("stream stopped: \(e)\n".data(using: .utf8)!); exit(1) }
}

_ = NSApplication.shared  // a window-server connection, which ScreenCaptureKit expects
let d = Delegate()
Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let win = content.windows.first(where: { $0.windowID == wid }) else { FileHandle.standardError.write("no window \(wid)\n".data(using: .utf8)!); exit(1) }
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    cfg.width = Int(win.frame.width * scale)
    cfg.height = Int(win.frame.height * scale)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    cfg.showsCursor = ProcessInfo.processInfo.environment["CURSOR"] == "1"   // CURSOR=1: the pointer is recorded
    cfg.capturesAudio = false
    cfg.ignoreShadowsSingleWindow = true
    let rc = SCRecordingOutputConfiguration()
    rc.outputURL = out
    rc.outputFileType = .mov
    rc.videoCodecType = .hevc
    let rec = SCRecordingOutput(configuration: rc, delegate: d)
    let stream = SCStream(filter: filter, configuration: cfg, delegate: d)
    try stream.addRecordingOutput(rec)
    try await stream.startCapture()
    try await Task.sleep(for: .seconds(secs))
    try await stream.stopCapture()
    try await Task.sleep(for: .milliseconds(400))
    print("saved \(out.path) \(cfg.width)x\(cfg.height)")
    exit(0)
  } catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
  }
}
RunLoop.main.run()
