// Frame and latency measurements: CPU time per frame, intervals between presented frames during animation,
// key event → redraw → flush → frame presented.
import Foundation
import QuartzCore
import TaudotShared

@MainActor public final class FrameStats {
  public private(set) var cpuMs: [Double] = []
  /// Time (ms) to encode, submit and present a frame on the main thread (with presentsWithTransaction it waits
  /// until the GPU has scheduled the work).
  public private(set) var submitMs: [Double] = []
  /// Intervals (ms) between presented frames inside one continuous animation (scrolling or cursor).
  public private(set) var presentIntervalsMs: [Double] = []
  /// Display link intervals while animating (ms), and how many ticks arrived after their target time.
  public private(set) var tickIntervalsMs: [Double] = []
  public private(set) var lateTicks = 0
  public struct KeyLatency: Sendable { public var redraw: Double; public var flush: Double; public var commit: Double; public var present: Double }
  public private(set) var keys: [KeyLatency] = []

  var pendingKey: CFTimeInterval?
  /// The Latency probe number of the pending key.
  var pendingKeyID: Int32 = 0
  var keyRedraw: CFTimeInterval?
  var keyFlush: CFTimeInterval?
  var lastTick: CFTimeInterval = 0
  var lastTarget: CFTimeInterval = 0
  var inRun = false
  var lastPresent: CFTimeInterval = 0
  var mark = 0
  public private(set) var presentedCount = 0, notPresented = 0
  var marks: [Int: (key: CFTimeInterval?, redraw: CFTimeInterval?, flush: CFTimeInterval?, run: Bool, commit: CFTimeInterval)] = [:]
  var markKeys: [Int: Int32] = [:]

  public init() {}

  public func reset() {
    presentedCount = 0; notPresented = 0
    cpuMs = []; submitMs = []; presentIntervalsMs = []; tickIntervalsMs = []; lateTicks = 0; keys = []
  }

  /// A key event happened at `time` (NSEvent timestamp, same clock as CACurrentMediaTime).
  public func keyDown(_ time: CFTimeInterval) { pendingKey = time; keyRedraw = nil; keyFlush = nil; pendingKeyID = Latency.shared.keyDown(at: time) }
  func handed() { Latency.shared.record(.handed, key: pendingKeyID) }
  func redrawArrived() { if keyRedraw == nil { keyRedraw = CACurrentMediaTime() } }
  func flushed() { keyFlush = CACurrentMediaTime(); Latency.shared.record(.model, key: pendingKeyID, at: keyFlush!) }

  func tick(now: CFTimeInterval, target: CFTimeInterval, scrolling: Bool) {
    if inRun && scrolling {
      tickIntervalsMs.append((now - lastTick) * 1000)
      if lastTarget > 0 && now > lastTarget + 0.002 { lateTicks += 1 }
    }
    inRun = scrolling
    lastTick = now
    lastTarget = target
  }

  func idle() { inRun = false; lastPresent = 0 }

  func submitted(_ s: Double) { submitMs.append(s * 1000) }

  func frameStarted(cpu: Double) -> Int {
    cpuMs.append(cpu * 1000)
    mark += 1
    let now = CACurrentMediaTime()
    var m: (CFTimeInterval?, CFTimeInterval?, CFTimeInterval?, Bool, CFTimeInterval) = (nil, nil, nil, inRun, now)
    if let k = pendingKey, let f = keyFlush {
      m = (k, keyRedraw, f, inRun, now); pendingKey = nil; keyFlush = nil; keyRedraw = nil
      markKeys[mark] = pendingKeyID
      Latency.shared.record(.committed, key: pendingKeyID, at: now)
    }
    marks[mark] = m
    return mark
  }

  func presented(_ id: Int, at t: CFTimeInterval) {
    guard let m = marks.removeValue(forKey: id) else { return }
    let keyID = markKeys.removeValue(forKey: id)
    if t <= 0 { notPresented += 1; return }
    if let keyID { Latency.shared.record(.presented, key: keyID, at: t) }
    if m.run, lastPresent > 0 { Latency.shared.record(.scrollFrame, value: Int64((t - lastPresent) * 1e6), at: t) }
    presentedCount += 1
    if let k = m.key, let f = m.flush {
      keys.append(KeyLatency(redraw: ((m.redraw ?? f) - k) * 1000, flush: (f - k) * 1000, commit: (m.commit - k) * 1000, present: (t - k) * 1000))
    }
    if m.run && lastPresent > 0 { presentIntervalsMs.append((t - lastPresent) * 1000) }
    lastPresent = m.run ? t : 0
  }

  public static func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
  }

  public func summary() -> String {
    func f(_ xs: [Double]) -> String {
      xs.isEmpty ? "n=0" : String(format: "n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f", xs.count, Self.pct(xs, 0.5), Self.pct(xs, 0.95), Self.pct(xs, 0.99), xs.max()!)
    }
    let refresh = Self.pct(tickIntervalsMs, 0.5)
    let dropped = presentIntervalsMs.filter { $0 > refresh * 1.5 }.count
    return """
    frames presented \(presentedCount), not presented \(notPresented)
    cpu ms/frame: \(f(cpuMs))
    submit+present ms/frame: \(f(submitMs))
    tick interval ms (animating): \(f(tickIntervalsMs)), late ticks \(lateTicks)
    present interval ms (animating): \(f(presentIntervalsMs)), over 1.5 frames: \(dropped)
    key→redraw ms: \(f(keys.map(\.redraw)))
    key→flush ms: \(f(keys.map(\.flush)))
    key→frame encoded ms: \(f(keys.map(\.commit)))
    key→present ms: \(f(keys.map(\.present)))
    """
  }
}
