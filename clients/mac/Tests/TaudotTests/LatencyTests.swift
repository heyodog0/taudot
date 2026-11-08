import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@Test func latencyRingKeepsTheNewest() {
  let l = Latency(capacity: 8)
  for i in 0..<20 { l.record(.section, key: 0, value: Int64(i), at: Double(i)) }
  let es = l.entries
  #expect(es.count == 8)
  #expect(es.map(\.value) == Array(12..<20).map(Int64.init))
  #expect(es.first!.t == 12)
}

@Test func latencyTSVNamesSectionsAndKeys() {
  let l = Latency(capacity: 16)
  let k = l.keyDown(at: 1.5)
  #expect(k == 1)
  l.record(.presented, key: k, at: 1.52)
  _ = l.section("busy", min: 0) { usleep(1000) }
  l.launch("main")
  let lines = l.tsv().split(separator: "\n").map(String.init)
  #expect(lines[0].hasPrefix("# t"))
  #expect(lines[1] == "1.500000\tkeyDown\t1\t0\t")
  #expect(lines[2] == "1.520000\tpresented\t1\t0\t")
  #expect(lines[3].contains("\tsection\t0\t") && lines[3].hasSuffix("\tbusy"))
  #expect(lines[4].hasSuffix("\tlaunch\t1\t0\tmain"))
}

@Test func latencyOffRecordsNothing() {
  let l = Latency(capacity: 8, enabled: false)
  l.record(.keyDown)
  #expect(l.keyDown() == 0)
  #expect(l.entries.isEmpty)
}

/// The cost of a probe: well under a microsecond (a keystroke records ~6).
@Test func latencyRecordIsCheap() {
  let l = Latency(capacity: 1 << 16)
  let n = 40_000
  // the best of 5 batches: a loaded parallel run preempts some batches, which says nothing about the cost
  var per = Double.infinity
  for _ in 0..<5 {
    let t0 = Latency.now
    for i in 0..<n { l.record(.scrollFrame, value: Int64(i)) }
    per = min(per, (Latency.now - t0) / Double(n))
  }
  #expect(per < 1e-6, "record took \(per * 1e9) ns")
}

/// A key typed into the native editor goes through every stage, in order, under its own number.
@MainActor @Test func nativeKeyChainIsProbed() async throws {
  let lat = Latency.shared
  lat.install()
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds)
  w.contentView!.addSubview(v)
  v.show(NativeDoc(docID: "d", path: "main.tex", text: "hello\nworld\n", seq: 1, conn: nil), buffer: 1)
  w.makeFirstResponder(v.textView)
  lat.clear()
  let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Latency.now, windowNumber: w.windowNumber,
                                        context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
  v.textView.keyDown(with: e)
  let key = lat.lastKey
  // let the run loop end its turn (commit) and the display link tick (presented)
  for _ in 0..<50 where !lat.entries.contains(where: { $0.probe == .presented && $0.key == key }) {
    try await Task.sleep(for: .milliseconds(10))
  }
  // the first of each stage (tests running alongside edit text views too, under the same last key)
  var seen = Set<Probe>()
  let mine = lat.entries.filter { $0.key == key && [.keyDown, .handed, .model, .committed, .presented].contains($0.probe) && seen.insert($0.probe).inserted }
  #expect(mine.map(\.probe) == [.keyDown, .model, .handed, .committed, .presented])
  #expect(zip(mine, mine.dropFirst()).allSatisfy { $0.t <= $1.t })
  #expect(v.textView.string.hasPrefix("x"))
}
