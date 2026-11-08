// Latency probes, cheap enough to leave on: each probe is a timestamp in a fixed in-memory ring (no allocation, one
// unfair lock) and an os_signpost event (free unless Instruments is recording). The ring is written out on demand:
// `kill -USR1 <pid>` (or `Latency.dump`) writes it as TSV to $TAUDOT_LATENCY_OUT, else
// $TMPDIR/taudot-latency-<pid>.tsv. TAUDOT_LATENCY=0 turns the probes off.
//
// Times are host time in seconds (CACurrentMediaTime's clock, the same as NSEvent.timestamp, CGEvent timestamps and
// ScreenCaptureKit's frame times), so an outside capture lines up with them without any offset.
//
// The chain a keystroke follows (`key` is a number per keyDown; later stages carry the key they are for):
//   keyDown → handed (NSTextView edited / Neovim input sent) → model (doc text or Neovim grid updated) →
//   committed (the Core Animation transaction holding the change was committed) → presented (on glass: the Metal
//   drawable's present time, or for AppKit views the display refresh the commit went out with) .
// and the PDF's: typesetSent → typesetRun → pdfReady → pageShown.
import AppKit
import QuartzCore
import os

public enum Probe: UInt8, CaseIterable, Sendable {
  case keyDown = 1, handed, model, committed, presented
  case typesetSent, typesetRun, pdfReady, pageShown
  /// A frame while scrolling or zooming; `value` is the interval since the previous one, µs.
  case scrollFrame, zoomFrame
  /// A launch milestone (`value` indexes `Latency.labels`).
  case launch
  /// A main run-loop turn that took longer than `Latency.longTurn`; `value` is its length, µs.
  case longTurn
  /// A named section that took over 1 ms (`value` µs, `key` indexes `Latency.labels`).
  case section
  /// A run-loop turn's start, recorded only when the turn turns out long (so the analysis sees where it began).
  case turnStart

  public var name: String {
    switch self {
    case .keyDown: "keyDown"
    case .handed: "handed"
    case .model: "model"
    case .committed: "committed"
    case .presented: "presented"
    case .typesetSent: "typesetSent"
    case .typesetRun: "typesetRun"
    case .pdfReady: "pdfReady"
    case .pageShown: "pageShown"
    case .scrollFrame: "scrollFrame"
    case .zoomFrame: "zoomFrame"
    case .launch: "launch"
    case .longTurn: "longTurn"
    case .section: "section"
    case .turnStart: "turnStart"
    }
  }
}

public final class Latency: @unchecked Sendable {
  public struct Entry: Sendable, Equatable {
    public var t: Double
    public var probe: Probe
    public var key: Int32
    public var value: Int64
  }

  public static let shared = Latency(capacity: 1 << 16, enabled: ProcessInfo.processInfo.environment["TAUDOT_LATENCY"] != "0")

  public let enabled: Bool
  private var ring: [Entry]
  private var next = 0
  private var count = 0
  private var lock = os_unfair_lock()
  private var labelIndex: [String: Int32] = [:]
  public private(set) var labels: [String] = []
  /// The last keyDown's number: what later stages of the editor chain belong to.
  public private(set) var lastKey: Int32 = 0
  /// When it came (host seconds; 0: none yet). Recorded even with the probes off: idle work waits on it.
  public private(set) var lastKeyAt: Double = 0
  private let signposter = OSSignposter(subsystem: "app.taudot", category: "latency")
  /// Main-thread turns longer than this are recorded (`longTurn`), seconds.
  public var longTurn: Double = 0.012

  public init(capacity: Int, enabled: Bool = true) {
    self.enabled = enabled
    ring = Array(repeating: Entry(t: 0, probe: .keyDown, key: 0, value: 0), count: capacity)
  }

  @inline(__always) public static var now: Double { CACurrentMediaTime() }

  public func record(_ p: Probe, key: Int32 = 0, value: Int64 = 0, at t: Double = Latency.now) {
    guard enabled else { return }
    os_unfair_lock_lock(&lock)
    ring[next] = Entry(t: t, probe: p, key: key, value: value)
    next = (next + 1) & (ring.count - 1)
    count = min(count + 1, ring.count)
    os_unfair_lock_unlock(&lock)
    if signposter.isEnabled { signpost(p, key: key, value: value) }
  }

  private func signpost(_ p: Probe, key: Int32, value: Int64) {
    let k = Int(key), v = Int(value)
    switch p {
    case .keyDown: signposter.emitEvent("keyDown", "key \(k)")
    case .handed: signposter.emitEvent("handed", "key \(k)")
    case .model: signposter.emitEvent("model", "key \(k)")
    case .committed: signposter.emitEvent("committed", "key \(k)")
    case .presented: signposter.emitEvent("presented", "key \(k)")
    case .typesetSent: signposter.emitEvent("typesetSent", "key \(k)")
    case .typesetRun: signposter.emitEvent("typesetRun", "key \(k) seq \(v)")
    case .pdfReady: signposter.emitEvent("pdfReady", "key \(k) seq \(v)")
    case .pageShown: signposter.emitEvent("pageShown", "key \(k) page \(v)")
    case .scrollFrame: signposter.emitEvent("scrollFrame", "\(v) us")
    case .zoomFrame: signposter.emitEvent("zoomFrame", "\(v) us")
    case .launch: signposter.emitEvent("launch", "\(k)")
    case .longTurn: signposter.emitEvent("longTurn", "\(v) us")
    case .section: signposter.emitEvent("section", "\(k) \(v) us")
    case .turnStart: signposter.emitEvent("turnStart")
    }
  }

  /// A new keystroke: its number, which the later stages pass back.
  @discardableResult public func keyDown(at t: Double = Latency.now) -> Int32 {
    lastKeyAt = t
    guard enabled else { return 0 }
    os_unfair_lock_lock(&lock)
    lastKey &+= 1
    let k = lastKey
    os_unfair_lock_unlock(&lock)
    record(.keyDown, key: k, at: t)
    return k
  }

  public func label(_ s: String) -> Int32 {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    if let i = labelIndex[s] { return i }
    let i = Int32(labels.count)
    labels.append(s)
    labelIndex[s] = i
    return i
  }

  public func launch(_ what: String) { record(.launch, key: label(what)) }

  /// Time a piece of work; recorded when it took over `min` seconds.
  @inline(__always) public func section<T>(_ name: String, min: Double = 0.001, _ body: () throws -> T) rethrows -> T {
    guard enabled else { return try body() }
    let t0 = Latency.now
    let r = try body()
    let dt = Latency.now - t0
    if dt >= min { record(.section, key: label(name), value: Int64(dt * 1e6), at: t0) }
    return r
  }

  public var entries: [Entry] {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    let n = ring.count
    return (0..<count).map { ring[(next - count + $0 + n) & (n - 1)] }
  }

  public func clear() {
    os_unfair_lock_lock(&lock)
    count = 0
    os_unfair_lock_unlock(&lock)
  }

  /// `t  probe  key  value  label` per line, oldest first; `label` names a section or launch milestone.
  public func tsv() -> String {
    let es = entries
    let names = labels
    var s = "# t\tprobe\tkey\tvalue\tlabel\n"
    s.reserveCapacity(es.count * 40)
    for e in es {
      let l = (e.probe == .section || e.probe == .launch) && Int(e.key) < names.count ? names[Int(e.key)] : ""
      s += String(format: "%.6f\t%@\t%d\t%lld\t%@\n", e.t, e.probe.name, e.key, e.value, l)
    }
    return s
  }

  public static var defaultPath: String {
    ProcessInfo.processInfo.environment["TAUDOT_LATENCY_OUT"]
      ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("taudot-latency-\(getpid()).tsv")
  }

  public func dump(to path: String = Latency.defaultPath) {
    try? tsv().write(toFile: path, atomically: true, encoding: .utf8)
  }

  // MARK: main thread

  private var installed = false
  private var turnStart = 0.0
  private var signalSource: DispatchSourceSignal?
  private var awaitingCommit: [Int32] = []
  private var awaitingPresent: [(key: Int32, commit: Double)] = []
  private var link: CADisplayLink?
  private var linkTarget: LinkTarget?

  /// Run-loop observers on the main thread (long turns, commits) and the SIGUSR1 dump. Call once, at launch.
  @MainActor public func install() {
    guard enabled, !installed else { return }
    installed = true
    signal(SIGUSR1, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    src.setEventHandler { [weak self] in self?.dump() }
    src.resume()
    signalSource = src
    let rl = CFRunLoopGetMain()
    // a turn starts when the run loop wakes
    let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, -1_000_000) { [weak self] _, _ in
      self?.turnStart = Latency.now
    }
    // and ends after everything else that runs before it sleeps: AppKit's display pass and Core Animation's commit
    // (order 2_000_000) come first, so a change made in this turn is committed by now
    let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 3_000_000) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.turnEnded() }
    }
    CFRunLoopAddObserver(rl, wake, .commonModes)
    CFRunLoopAddObserver(rl, sleep, .commonModes)
  }

  /// The current turn's change for `key` is on its way to the screen: record when it is committed and presented
  /// (AppKit-drawn views; Metal views record `presented` themselves).
  @MainActor public func awaitFrame(key: Int32) {
    guard enabled, installed else { return }
    if !awaitingCommit.contains(key) { awaitingCommit.append(key) }
  }

  @MainActor private func turnEnded() {
    let now = Latency.now
    if turnStart > 0 && now - turnStart > longTurn {
      record(.turnStart, at: turnStart)
      record(.longTurn, value: Int64((now - turnStart) * 1e6), at: now)
    }
    turnStart = 0
    guard !awaitingCommit.isEmpty else { return }
    for k in awaitingCommit {
      record(.committed, key: k, at: now)
      awaitingPresent.append((k, now))
    }
    awaitingCommit = []
    startLink()
  }

  /// The window server composites what was committed by the next refresh: the first display-link tick after a commit
  /// has a target timestamp that is that refresh. (Checked against an outside capture: docs/perf.md.)
  @MainActor private func startLink() {
    if link == nil {
      guard let screen = NSScreen.main else { return }
      let t = LinkTarget { [weak self] l in MainActor.assumeIsolated { self?.tick(l) } }
      let l = screen.displayLink(target: t, selector: #selector(LinkTarget.tick(_:)))
      l.add(to: .main, forMode: .common)
      link = l
      linkTarget = t
    }
    link?.isPaused = false
  }

  @MainActor private func tick(_ l: CADisplayLink) {
    // ticks fire at the start of a refresh interval; a commit before this tick shows at its target
    let ready = awaitingPresent.filter { $0.commit <= l.timestamp + 0.0005 }
    for r in ready { record(.presented, key: r.key, value: Int64((l.targetTimestamp - l.timestamp) * 1e6), at: l.targetTimestamp) }
    awaitingPresent.removeAll { $0.commit <= l.timestamp + 0.0005 }
    if awaitingPresent.isEmpty && awaitingCommit.isEmpty { l.isPaused = true }
  }
}

final class LinkTarget: NSObject {
  let f: (CADisplayLink) -> Void
  init(_ f: @escaping (CADisplayLink) -> Void) { self.f = f }
  @objc func tick(_ l: CADisplayLink) { f(l) }
}

