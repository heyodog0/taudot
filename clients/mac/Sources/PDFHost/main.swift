// PDFHost: a window with just the PDF pane on a folder, for testing and measuring.
//
//   swift run PDFHost FOLDER [--main main.tex] [--socket PATH] [--bench scroll|pinch] [--out FILE]
//
// --socket: the engine's socket for live edits (default: none, file saves only; $TAUDOT_SOCKET also works).
// --bench: once the pages are sharp, scroll through the document (or pinch in and out) under a display link and
// print frame times as JSON, then quit.
//
// Benches and shots never disturb the screen (docs/agents/README.md): no Dock icon, never activated, the window off
// every screen and behind everything (with --shot, all but a sliver: screencapture needs that). The benches that need the real
// screen (scroll, pinch and edges run under a display link; edges posts HID scroll events and moves the pointer)
// only run with TAUDOT_ONSCREEN=1. Without --bench or --shot it's an ordinary window, for looking at.
import AppKit
import QuartzCore
import TaudotPDF
import TaudotShared

// TEXSYNC_* variables (names before the rename) still work (Compat.swift).
Compat.envFallback()

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func opt(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let v = args[i + 1]
  args.removeSubrange(i...i + 1)
  return v
}
let mainOpt = opt("--main")
let socketOpt = opt("--socket") ?? ProcessInfo.processInfo.environment["TAUDOT_SOCKET"]
let bench = opt("--bench")
let outPath = opt("--out")
let editTargets = opt("--edit-at")  // comma-separated text to edit next to (bench edit)
let killTxpAfter = opt("--kill-txp-after").flatMap(Double.init)  // s: kill our own txp-headless once (restart test)
let jumpLine = opt("--line")  // bench synctex: the source line of the main file to jump to
let jumpCol = opt("--col").flatMap { Int($0) }  // bench synctex: the cursor's column (UTF-8 bytes) in that line
let edits = Int(opt("--edits") ?? "8") ?? 8
let frameOpt = opt("--frame")
let pageOpt = opt("--page").flatMap { Int($0) }  // after the first typeset, show page N (1-based) at the top  // x,y,w,h of the window
let commentsOpt = opt("--comments")  // bench notes: review comments to show (JSON array of PDFComment fields)
let styleOpt = opt("--page-style")  // white|sepia|dark (default: the app's setting); "dark@3" switches to it 3 s in
let shotOpt = opt("--shot")  // PNG of the window once the first screen is sharp (and again after a bench as FILE-after.png)
let env = ProcessInfo.processInfo.environment
let onScreen = env["TAUDOT_ONSCREEN"] != nil
let background = !onScreen && (bench != nil || shotOpt != nil || env["TAUDOT_OFFSCREEN"] != nil)
if let bench, ["scroll", "pinch", "edges"].contains(bench), !onScreen {
  FileHandle.standardError.write("bench \(bench) needs the real screen: run it with TAUDOT_ONSCREEN=1 (rarely, and note it in your log)\n".data(using: .utf8)!)
  exit(3)
}
guard let folderArg = args.first else {
  FileHandle.standardError.write("usage: PDFHost FOLDER [--main FILE] [--socket PATH] [--bench scroll|pinch]\n".data(using: .utf8)!)
  exit(2)
}
let folder = URL(fileURLWithPath: (folderArg as NSString).expandingTildeInPath).standardized
let mainFile = mainOpt ?? TaudotPDFPane.findMain(in: folder) ?? ""
if mainFile.isEmpty {
  FileHandle.standardError.write("no main .tex in \(folder.path)\n".data(using: .utf8)!)
  exit(2)
}

func log(_ s: String) {
  let ts = String(format: "%.3f", CACurrentMediaTime())
  FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
}

@MainActor final class Host: NSObject, NSApplicationDelegate {
  let pane = TaudotPDFPane()
  var window: NSWindow!
  var bencher: Bencher?

  func applicationDidFinishLaunching(_ n: Notification) {
    var rect = NSRect(x: 200, y: 100, width: 820, height: 1000)
    if let f = frameOpt?.split(separator: ",").compactMap({ Double($0) }), f.count == 4 {
      rect = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
    window = (background ? OffscreenWindow.self : NSWindow.self).init(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "PDFHost — \(folder.lastPathComponent)"
    pane.view.frame = window.contentView!.bounds
    pane.view.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(pane.view)
    if background {
      // past the right edge of every screen, behind everything; it still draws. screencapture can't shoot a window
      // that's wholly off screen, so with --shot a 120 pt sliver stays on (behind everything), as the app's
      // background runs do.
      let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
      let sc = NSScreen.screens.first(where: { $0.frame.maxX == right })?.visibleFrame ?? .zero
      window.setFrameOrigin(NSPoint(x: shotOpt != nil ? right - 120 : right + 200, y: sc.minY))
      window.orderBack(nil)
    } else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: bench != nil)
    }
    pane.onStatus = { s in log(s) }
    pane.onInverseSearchWord = { [weak self] path, line, column in
      log("inverse search: \(path):\(line) column \(column.map(String.init) ?? "-")")
      self?.pane.jump(path: path, line: line, column: column)  // round trip, to see the mark
    }
    if let st = styleOpt {
      let parts = st.split(separator: "@")
      let style = PDFPaneView.PageStyle(rawValue: String(parts[0])) ?? .white
      if parts.count > 1, let after = Double(parts[1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
          MainActor.assumeIsolated {
            log("page style: \(style.rawValue)")
            self.pane.pageStyle = style
            if let shotOpt { self.waitAndShoot(shotOpt.replacingOccurrences(of: ".png", with: "-\(style.rawValue).png")) }
          }
        }
      } else { pane.pageStyle = style }
    }
    pane.onEditShown = { ms, page in log(String(format: "edit shown: page %d, %.1f ms after the edit", page + 1, ms)) }
    pane.open(folder: folder, main: mainFile, engineSocket: socketOpt.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
    if let shotOpt { waitAndShoot(shotOpt) }
    if let pageOpt { goToPage(pageOpt - 1) }
    if let killTxpAfter {
      DispatchQueue.main.asyncAfter(deadline: .now() + killTxpAfter) {
        MainActor.assumeIsolated {
          log("killing our txp-headless")
          self.pane.txp?.killForTest()
        }
      }
    }
    if bench != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        log("bench: timed out after 120 s")
        MainActor.assumeIsolated { self.pane.close() }
        exit(1)
      }
    }
    if let bench {
      bencher = Bencher(pane: pane, kind: bench, out: outPath)
      bencher?.start()
    }
  }

  func goToPage(_ p: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      MainActor.assumeIsolated {
        guard self.pane.lastPages?.done == true, p < self.pane.pane.pageCount else { return self.goToPage(p) }
        self.pane.pane.setViewTop(page: p, y: 0)
        log("showing page \(p + 1)")
      }
    }
  }

  func waitAndShoot(_ path: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      MainActor.assumeIsolated {
        guard self.pane.lastPages?.done == true, self.pane.pane.settled else { return self.waitAndShoot(path) }
        shoot(self.window, path)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ n: Notification) { pane.close() }
}

/// Drives the pane under a display link and records frame intervals and main-thread time per frame.
func findBytes(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
  guard needle.count <= hay.count else { return nil }
  for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle { return i }
  return nil
}

/// Stays where it's put: AppKit moves a titled window back onto a screen when it's ordered in.
final class OffscreenWindow: NSWindow {
  override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
}

/// A PNG of just this window (screencapture by window id, so other windows on screen stay out of it).
@MainActor func shoot(_ w: NSWindow, _ path: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
  try? p.run()
  p.waitUntilExit()
  log("shot: \(path)")
}

@MainActor final class Bencher: NSObject {
  let pane: TaudotPDFPane
  let kind: String
  let out: String?
  var link: CADisplayLink?
  var waitTimer: Timer?
  var t0: CFTimeInterval = 0
  var last: CFTimeInterval = 0
  var intervals: [Double] = []
  var work: [Double] = []
  var phase = "wait"
  var startMag: CGFloat = 1
  var waitStart = CACurrentMediaTime()
  var settleMs: Double = 0

  init(pane: TaudotPDFPane, kind: String, out: String?) {
    self.pane = pane
    self.kind = kind
    self.out = out
  }

  func start() {
    if ProcessInfo.processInfo.environment["TAUDOT_PDF_TRACE"] != nil {
      // how long each main run loop pass takes, Core Animation's commit included (it runs before waiting)
      nonisolated(unsafe) var woke = CACurrentMediaTime()
      let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, act in
        let now = CACurrentMediaTime()
        if act == .afterWaiting { woke = now } else if (now - woke) * 1000 > 5 { log(String(format: "runloop pass %.1f ms", (now - woke) * 1000)) }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
    }
    if ProcessInfo.processInfo.environment["PDFHOST_EVENTS"] != nil {
      NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
        log("scroll ev win=\(e.window?.windowNumber ?? -1) phase=\(e.phase.rawValue) mom=\(e.momentumPhase.rawValue) dy=\(e.scrollingDeltaY) precise=\(e.hasPreciseScrollingDeltas) loc=\(e.locationInWindow)")
        return e
      }
    }
    if background && Self.featureKinds.contains(kind) {
      // off screen a display link never ticks: these benches only need to know when the pane is ready
      waitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
          guard self.phase == "wait" else { self.waitTimer?.invalidate(); return }
          self.featureWait(CACurrentMediaTime())
        }
      }
      return
    }
    let l = pane.view.displayLink(target: self, selector: #selector(tick(_:)))
    l.add(to: .main, forMode: .common)
    link = l
  }

  /// Benches that measure features, not frames: run without a display link.
  static let featureKinds: Set<String> = ["words", "select", "figures", "hitrate", "caret", "notes", "synctex"]

  /// A feature bench starts once the whole document is typeset, the first screen sharp and SyncTeX in.
  func featureWait(_ now: CFTimeInterval) {
    // the run's own SyncTeX: the page cache's (from last time) is up before it and may not match these pages
    guard pane.lastPages?.done == true, view.settled, now - waitStart > 1, pane.syncTexFromRun else { return }
    phase = "done"
    Task {
      switch kind {
      case "words": await runWords()
      case "select": await runSelect()
      case "figures": await runFigures()
      case "hitrate": await runHitRate()
      case "caret": await runCaret()
      case "notes": await runNotes()
      default: await runSyncTex()
      }
    }
  }

  var view: PDFPaneView { pane.pane }

  @objc func tick(_ l: CADisplayLink) {
    let now = CACurrentMediaTime()
    switch phase {
    case "wait":
      // the whole document typeset and the first screen sharp
      guard pane.lastPages?.done == true, view.settled, now - waitStart > 1 else { return }
      if kind == "words" {
        guard pane.syncTexFromRun else { return }
        phase = "done"
        Task { await runWords() }
        return
      }
      if kind == "select" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runSelect() }
        return
      }
      if kind == "figures" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runFigures() }
        return
      }
      if kind == "hitrate" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runHitRate() }
        return
      }
      if kind == "caret" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runCaret() }
        return
      }
      if kind == "notes" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runNotes() }
        return
      }
      if kind == "synctex" {
        guard pane.syncTex != nil else { return }
        phase = "done"
        Task { await runSyncTex() }
        return
      }
      if kind == "save" {
        phase = "edit"
        Task { await runSaves() }
        return
      }
      if kind == "edit" {
        guard pane.liveDocCount > 0 else { return }
        phase = "edit"
        Task { await runEdits() }
        return
      }
      log("bench: ready, \(view.pageCount) pages, magnification \(view.magnification), period \(l.duration * 1000) ms")
      phase = "run"
      t0 = now
      last = now
      startMag = view.magnification
    case "run":
      let dt = (now - last) * 1000
      if dt > 12 { log(String(format: "bench: long frame %.1f ms", dt)) }
      last = now
      intervals.append(dt)
      let w0 = CACurrentMediaTime()
      let t = now - t0
      let done = step(t)
      work.append((CACurrentMediaTime() - w0) * 1000)
      if done {
        phase = "settle"
        waitStart = now
        if kind == "pinch" { view.setLiveMagnify(false) }
      }
    case "settle":
      if view.settled {
        settleMs = (now - waitStart) * 1000
        finish(l)
      } else if now - waitStart > 10 { settleMs = -1; finish(l) }
    case "edit":
      if swapAt > 0 {
        // the frame after the swap's commit: the new page is in the frame shown at this tick's target time
        shown.append((l.targetTimestamp - sentAt) * 1000)
        if shown.count < swaps.count { shown.append(-1) }
        swapAt = 0
      }
    default: break
    }
  }

  /// No engine: rewrite the main file with a character inserted (then removed) next to the target, timed from the
  /// write to the changed page on screen. Puts the file back as it was at the end.
  func runSaves() async {
    let url = folder.appendingPathComponent(mainFile)
    guard let orig = try? String(contentsOf: url, encoding: .utf8) else { NSApp.terminate(nil); return }
    let target = (editTargets ?? "Paragraph 4.").split(separator: ",").map(String.init).first!
    pane.onEditShown = { [weak self] ms, page in
      guard let self else { return }
      self.swaps.append(ms); self.pagesShown.append(page + 1); self.swapAt = CACurrentMediaTime()
    }
    // the edited line in view (each engine breaks pages its own way): a jump to it once SyncTeX is in
    if let r = orig.range(of: target) {
      let line = orig[..<r.lowerBound].filter { $0 == "\n" }.count + 1
      for _ in 0..<250 where pane.syncTex == nil { try? await Task.sleep(for: .milliseconds(20)) }
      pane.jump(path: mainFile, line: line, column: nil)
      try? await Task.sleep(for: .milliseconds(800))
      pane.clearMark()
      log("bench: edits at \(mainFile):\(line), pages in view \(view.pagesInView.map { $0 + 1 })")
    }
    for k in 0..<edits {
      try? await Task.sleep(for: .milliseconds(1200))
      let before = swaps.count
      let text = k % 2 == 0 ? orig.replacingOccurrences(of: target, with: String(target.dropLast()) + "x.") : orig
      sentAt = CACurrentMediaTime()
      pane.noteEdit(at: sentAt)
      try? text.write(to: url, atomically: true, encoding: .utf8)
      for _ in 0..<200 where swaps.count == before { try? await Task.sleep(for: .milliseconds(5)) }
      for _ in 0..<20 where shown.count < swaps.count { try? await Task.sleep(for: .milliseconds(5)) }
      if swaps.count == before { log("bench: save #\(k): nothing shown in 1 s"); swaps.append(-1); shown.append(-1); pagesShown.append(0) }
      else { log(String(format: "bench: save #%d: swap %.1f ms, on screen %.1f ms, page %d", k, swaps.last!, shown.last ?? -1, pagesShown.last!)) }
    }
    try? orig.write(to: url, atomically: true, encoding: .utf8)
    let d = try! JSONSerialization.data(withJSONObject: ["kind": "save", "swap_ms": swaps, "shown_ms": shown, "pages": pagesShown], options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    NSApp.terminate(nil)
  }

  /// Forward search to a line (scroll + band), a shot while the band shows, then inverse search at the band.
  func runSyncTex() async {
    let line = Int(jumpLine ?? "361") ?? 361
    if let st = pane.syncTex { log("bench: synctex \(st.inputs.count) inputs, \(st.pages.count) pages, \(st.pages.map(\.count).reduce(0, +)) nodes, main: \(st.inputs.values.filter { $0.hasSuffix("main.tex") })") }
    guard let f = pane.syncTex?.forward(file: mainFile, line: line) else { log("bench: no forward result"); NSApp.terminate(nil); return }
    log(String(format: "bench: forward %@:%d -> page %d, y %.1f, h %.1f", mainFile, line, f.page + 1, f.y, f.h))
    pane.jump(path: mainFile, line: line, column: jumpCol)
    try? await Task.sleep(for: .milliseconds(320))
    if let r = view.revealed { log("bench: revealed page \(r.page + 1): \(r.rects.map { String(format: "(%.1f, %.1f, %.1f × %.1f)", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: " "))") }
    if let shotOpt { shoot(view.window!, shotOpt) }
    var back: [Any] = []
    for dx in [20.0, 120.0, 250.0] {
      let r = pane.inverse(page: f.page, x: f.x + dx, y: f.y + f.h * 0.6)
      log("bench: inverse at x+\(Int(dx)) -> \(r.map { "\($0.path):\($0.line)" } ?? "nil")")
      back.append(r.map { ["path": $0.path, "line": $0.line] as [String: Any] } ?? NSNull())
    }
    let d = try! JSONSerialization.data(withJSONObject: ["kind": "synctex", "line": line, "page": f.page + 1, "inverse": back], options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    NSApp.terminate(nil)
  }

  /// Commenting from the PDF: `--line N --select FROM,TO` (two words of that source line): drag from the middle of
  /// the first to the middle of the last as typeset (found by forward search), and check the draft's source range
  /// covers exactly those words. `--shot F.png`: F (the selection and its pill), F-draft (the draft card).
  func runSelect() async {
    let line = Int(jumpLine ?? "177") ?? 177
    let pair = (opt("--select") ?? "critical,development").split(separator: ",").map(String.init)
    let text = pane.sourceLine(mainFile, line) ?? ""
    let src = WordMatch.sourceWords(text)
    guard pair.count == 2, let a = src.first(where: { $0.text == pair[0].lowercased() }),
      let b = src.first(where: { $0.text == pair[1].lowercased() && $0.start >= a.start })
    else { log("bench: words not in line \(line)"); NSApp.terminate(nil); return }
    func typeset(_ w: WordMatch.SourceWord) async -> (page: Int, rect: CGRect)? {
      pane.jump(path: mainFile, line: line, column: w.start + 1)
      for _ in 0..<300 {
        try? await Task.sleep(for: .milliseconds(5))
        if pane.lastForwardWord != nil, let r = view.revealed { return (r.page, r.rects.first!) }
      }
      return nil
    }
    guard let ra = await typeset(a), let rb = await typeset(b) else { log("bench: forward search failed"); NSApp.terminate(nil); return }
    try? await Task.sleep(for: .milliseconds(1900))  // the forward marks fade
    var created: (PDFCommentDraft, String)?
    pane.onCommentCreate = { d, t in created = (d, t) }
    let t0 = CACurrentMediaTime()
    view.dragPages(from: view.pagePoint(ra.page, CGPoint(x: ra.rect.midX, y: ra.rect.midY)),
      to: view.pagePoint(rb.page, CGPoint(x: rb.rect.midX, y: rb.rect.midY)))
    for _ in 0..<300 where view.selectionDraft == nil { try? await Task.sleep(for: .milliseconds(5)) }
    let ms = (CACurrentMediaTime() - t0) * 1000
    guard let d = view.selectionDraft else { log("bench: no draft (selection not mapped)"); NSApp.terminate(nil); return }
    let ok = d.path == mainFile && d.line == line && d.endLine == line && d.column == a.start && d.endColumn == b.end
    log(String(format: "bench: selected %@…%@ in %.0f ms: %@:%d:%d–%d:%d \"%@\" (want cols %d–%d) %@", pair[0], pair[1], ms, d.path,
      d.line, d.column, d.endLine, d.endColumn, d.quote, a.start, b.end, ok ? "ok" : "MISMATCH"))
    log("bench: \(view.selectionRects.count) highlight rect(s), pill \(view.commentPillFrame.map { _ in "shown" } ?? "MISSING")")
    try? await Task.sleep(for: .milliseconds(200))
    if let shotOpt { shoot(view.window!, shotOpt) }
    view.clickCommentPill()
    try? await Task.sleep(for: .milliseconds(250))
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-draft.png")) }
    view.sendCardForTest("Too strong? Maybe “central”.")
    log("bench: Return -> onCommentCreate \(created.map { "\($0.0.line):\($0.0.column)–\($0.0.endLine):\($0.0.endColumn) \"\($0.1)\"" } ?? "NOT CALLED"), selection \(view.selectionRects.isEmpty ? "cleared" : "still there")")
    NSApp.terminate(nil)
  }

  /// Figures and cross-references: `--figures L1,L2,…` (\includegraphics lines): double-click the middle of each
  /// figure's graphic and check the click comes back to that line; `--refs L:WORD,…` (a source line and the word of a
  /// typeset reference on it, e.g. 389:Figure): click that word and check the PDF and editor go to its \label.
  /// `--shot F.png`: F-figure (the first figure's click), F-ref (the first reference followed).
  func runFigures() async {
    let lines = pane.sourceLines(mainFile)
    var ok = true
    for (n, l) in (opt("--figures") ?? "").split(separator: ",").compactMap({ Int($0) }).enumerated() {
      guard let r = pane.syncTex?.rows(file: mainFile, line: l)?.rows.max(by: { $0.rect.height < $1.rect.height }) else {
        log("bench: figure line \(l): no SyncTeX rows"); ok = false; continue
      }
      let t0 = CACurrentMediaTime()
      await pane.syncClick(page: r.page, x: r.rect.midX, y: r.rect.midY)
      let ms = (CACurrentMediaTime() - t0) * 1000
      let got = pane.lastInverse
      let good = got?.line == l
      ok = ok && good
      log(String(format: "bench: figure %d (page %d, box %.0f pt tall): double-click -> %@:%d col %@ in %.0f ms %@", l, r.page + 1,
        r.rect.height, got?.path ?? "-", got?.line ?? -1, got?.column.map(String.init) ?? "-", ms, good ? "ok" : "MISMATCH"))
      try? await Task.sleep(for: .milliseconds(250))
      if n == 0, let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-figure.png")) }
      try? await Task.sleep(for: .milliseconds(1600))
    }
    for (n, spec) in (opt("--refs") ?? "").split(separator: ",").enumerated() {
      let parts = spec.split(separator: ":")
      guard parts.count == 2, let l = Int(parts[0]) else { continue }
      let text = lines.indices.contains(l - 1) ? lines[l - 1] : ""
      let src = WordMatch.sourceWords(text)
      guard let w = src.first(where: { $0.text == parts[1].lowercased() }) else { log("bench: \(spec): word not on the line"); ok = false; continue }
      pane.jump(path: mainFile, line: l, column: w.start + 1)
      var mark: (page: Int, rects: [CGRect])?
      for _ in 0..<300 {
        try? await Task.sleep(for: .milliseconds(5))
        if pane.lastForwardWord != nil, let r = view.revealed { mark = r; break }
      }
      guard let mark, let rect = mark.rects.first else { log("bench: \(spec): not found on the page"); ok = false; continue }
      try? await Task.sleep(for: .milliseconds(1900))
      let t0 = CACurrentMediaTime()
      let before = pane.lastRef?.key
      await pane.followRef(page: mark.page, x: rect.midX, y: rect.midY)
      let ms = (CACurrentMediaTime() - t0) * 1000
      let r = pane.lastRef
      let followed = r != nil && (r!.key != before || n > 0)
      let pageNow = (view.revealed?.page).map { $0 + 1 } ?? -1
      log(String(format: "bench: ref %@ (page %d) -> %@ at %@:%d in %.0f ms; PDF marks page %d; editor sent to %@:%d %@", String(spec), mark.page + 1,
        r?.key ?? "none", r?.path ?? "-", r?.line ?? -1, ms, pageNow, pane.lastInverse?.path ?? "-", pane.lastInverse?.line ?? -1,
        followed ? "ok" : "NOT FOLLOWED"))
      ok = ok && followed
      try? await Task.sleep(for: .milliseconds(450))
      if n == 0, let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-ref.png")) }
      try? await Task.sleep(for: .milliseconds(1600))
    }
    log("bench: figures and refs \(ok ? "all ok" : "FAILED")")
    NSApp.terminate(nil)
  }

  /// Forward-search word hit rate: `--lines L1,L2,…`; for every source word of each line, jump with the cursor on it
  /// and check the boxed word is that word. Prints JSON: hits, misses (wrong word), none (line only), latency.
  func runHitRate() async {
    let lines = (opt("--lines") ?? "177").split(separator: ",").compactMap { Int($0) }
    var hit = 0, wrong = 0, none = 0
    var ms: [Double] = []
    var misses: [String] = []
    for l in lines {
      let text = pane.sourceLine(mainFile, l) ?? ""
      for w in WordMatch.sourceWords(text) {
        let t0 = CACurrentMediaTime()
        pane.jump(path: mainFile, line: l, column: w.start)
        var got: String?
        for _ in 0..<400 {
          try? await Task.sleep(for: .milliseconds(2))
          if let g = pane.lastForwardWord { got = g; break }
          if pane.forwardSearchDone { break }
        }
        ms.append((CACurrentMediaTime() - t0) * 1000)
        if let got {
          let g = WordMatch.normalize(got)
          if g == w.text || g.hasPrefix(w.text) || w.text.hasPrefix(g) && g.count >= 3 { hit += 1 } else { wrong += 1; misses.append("\(l):\(w.text)→\(g)") }
        } else {
          none += 1
          misses.append("\(l):\(w.text)→-")
        }
      }
    }
    ms.sort()
    let n = hit + wrong + none
    let d = try! JSONSerialization.data(withJSONObject: [
      "kind": "hitrate", "glyphs": TxpPaths.hasGlyphs, "words": n, "hit": hit, "wrong": wrong, "none": none,
      "hit_rate": n > 0 ? (Double(hit) / Double(n) * 1000).rounded() / 10 : 0,
      "ms_p50": ms.isEmpty ? 0 : ms[ms.count / 2].rounded(), "ms_p95": ms.isEmpty ? 0 : ms[min(ms.count - 1, ms.count * 95 / 100)].rounded(),
      "misses": Array(misses.prefix(40)),
    ], options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    NSApp.terminate(nil)
  }

  /// The cursor dot: `--lines …`; at every byte column of each line, place the dot and time it. Then type a word
  /// into the line a letter at a time (the line's text changes, nothing is typeset) and check the dot follows.
  /// `--shot F.png`: the dot on the first line's 10th word.
  func runCaret() async {
    var lines = (opt("--lines") ?? "177").split(separator: ",").compactMap { Int($0) }
    // --all: every source line with 8+ words that isn't a comment
    if lines.isEmpty || opt("--all") != nil || args.contains("--all") {
      let all = pane.sourceLines(mainFile)
      lines = all.indices.filter { i in
        let t = all[i].trimmingCharacters(in: .whitespaces)
        return !t.hasPrefix("%") && WordMatch.sourceWords(t).count >= 8
      }.map { $0 + 1 }
    }
    // the glyphs and the map come in after SyncTeX
    for _ in 0..<500 where pane.placedCursorMap == false { try? await Task.sleep(for: .milliseconds(10)) }
    var shown = 0, exact = 0, hidden = 0
    var us: [Double] = []
    var noDot: [Int] = [], noDotButTypeset: [Int] = []

    for l in lines {
      let text = pane.sourceLine(mainFile, l) ?? ""
      pane.showCaret(path: mainFile, line: l, column: 0, text: text)
      // its page's glyphs (a page not in view is read on demand)
      let pages = Set(pane.syncTex?.rows(file: mainFile, line: l)?.rows.map(\.page) ?? [])
      let w0 = CACurrentMediaTime()
      for _ in 0..<800 where !pages.isSubset(of: Set(pane.glyphPagesRead)) { try? await Task.sleep(for: .milliseconds(5)) }
      log(String(format: "bench:   line %d: glyphs of page(s) %@ in %.0f ms", l, pages.map { String($0 + 1) }.joined(separator: ","), (CACurrentMediaTime() - w0) * 1000))
      for col in 0...text.utf8.count {
        let t0 = CACurrentMediaTime()
        pane.showCaret(path: mainFile, line: l, column: col, text: text)
        us.append((CACurrentMediaTime() - t0) * 1e6)
        if let c = view.caret { shown += 1; if !c.approximate { exact += 1 } } else { hidden += 1 }
      }
      if ProcessInfo.processInfo.environment["CARET_DEBUG"] != nil { log(pane.caretDebug(line: l, column: 20).split(separator: "\n").prefix(4).joined(separator: " | ")) }
      if lines.count > 20 {
        let mid = WordMatch.sourceWords(text).dropFirst(3).first?.start ?? 0
        pane.showCaret(path: mainFile, line: l, column: mid, text: text)
        if view.caret == nil {
          noDot.append(l)
          if pane.syncTex?.rows(file: mainFile, line: l) != nil { noDotButTypeset.append(l) }
        }
        continue
      }
      log("bench:   line \(l): \(shown) shown so far, \(hidden) hidden so far; glyph pages \(pane.glyphPagesRead)")
    }
    if lines.count > 20 {
      log("bench: \(lines.count) text lines: no dot on \(noDot.count) (\(noDotButTypeset.count) of them typeset per our SyncTeX): \(noDotButTypeset.prefix(40))")
    }
    us.sort()
    log(String(format: "bench: dot at %d columns: %d shown (%d exact), %d hidden; %.0f µs p50, %.0f µs p95 a placement",
      us.count, shown, exact, hidden, us[us.count / 2], us[us.count * 95 / 100]))
    // typing: insert "zebra " a letter at a time before the 10th word of the first line
    if let l = lines.first, let text = pane.sourceLine(mainFile, l), let w = WordMatch.sourceWords(text).dropFirst(9).first {
      var bytes = Array(text.utf8)
      var xs: [Double] = []
      for (i, ch) in "zebra ".utf8.enumerated() {
        bytes.insert(ch, at: w.start + i)
        pane.showCaret(path: mainFile, line: l, column: w.start + i + 1, text: String(decoding: bytes, as: UTF8.self))
        xs.append(view.caret?.x ?? -1)
      }
      log("bench: typing 'zebra ' before \(w.text): dot x \(xs.map { String(format: "%.1f", $0) }.joined(separator: " ")) (nothing typeset)")
      pane.showCaret(path: mainFile, line: l, column: w.start + 2, text: text)
      if let shotOpt {
        if let c = view.caret { view.scrollTo(page: c.page, y: c.top) }
        // with the forward-search mark: the band takes the line, the dot the letter
        pane.jump(path: mainFile, line: l, column: w.start + 2)
        try? await Task.sleep(for: .milliseconds(700))
        shoot(view.window!, shotOpt)
        // in a command (\citep{…}): the nearest typeset letter, a ring
        if let r = text.range(of: "\\cite") {
          let col = text.utf8.distance(from: text.utf8.startIndex, to: r.upperBound) + 2
          pane.showCaret(path: mainFile, line: l, column: col, text: text)
          log("bench: cursor in \\cite… at col \(col): \(view.caret.map { $0.approximate ? "ring (approximate)" : "dot" } ?? "hidden")")
          try? await Task.sleep(for: .milliseconds(300))
          shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-ring.png"))
        }
      }
    }
    NSApp.terminate(nil)
  }

  /// Review comments as notes: `--comments FILE.json` (an array of PDFComment fields). Places them, logs where, and
  /// with `--shot F.png` shoots F (the first note's page), F-hover (its card), F-click (pulsing), F-off (toggled off).
  func runNotes() async {
    guard let path = commentsOpt, let data = FileManager.default.contents(atPath: path),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { log("bench: --comments FILE.json needed"); NSApp.terminate(nil); return }
    let list = arr.map { d in
      PDFComment(
        id: d["id"] as! String, path: d["path"] as? String ?? mainFile, line: d["line"] as! Int, column: d["column"] as? Int,
        endLine: d["endLine"] as? Int, endColumn: d["endColumn"] as? Int, quote: d["quote"] as? String ?? "",
        author: d["author"] as? String ?? "?", color: d["color"] as? String, firstMessage: d["firstMessage"] as? String ?? "",
        replies: d["replies"] as? Int ?? 0, resolved: d["resolved"] as? Bool ?? false,
        messages: (d["messages"] as? [[String: Any]] ?? []).map { m in
          PDFCommentMessage(author: m["author"] as? String ?? "?", color: m["color"] as? String, text: m["text"] as? String ?? "",
            time: (m["ago"] as? Double).map { Date().addingTimeInterval(-$0) }, mine: m["mine"] as? Bool ?? false)
        })
    }
    var clicked: String?
    pane.onCommentClick = { id in clicked = id }
    let t0 = CACurrentMediaTime()
    pane.setComments(list)
    let placedAt = CACurrentMediaTime()
    for _ in 0..<300 where !pane.placedNotes.contains(where: { !$0.words.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
    try? await Task.sleep(for: .milliseconds(300))
    log(String(format: "bench: %d comments, %d placed in %.1f ms, words in %.0f ms", list.count, pane.placedNotes.count,
      (placedAt - t0) * 1000, (CACurrentMediaTime() - t0) * 1000))
    for n in pane.placedNotes {
      log(String(format: "bench:   %@ page %d line y %.1f h %.1f, %@ margin slot %d, %d word rect(s)%@", n.id, n.page + 1,
        n.line.minY, n.line.height, n.side == .left ? "left" : "right", n.slot, n.words.count,
        n.words.map { String(format: " (%.0f,%.0f %.0f×%.0f)", $0.minX, $0.minY, $0.width, $0.height) }.joined()))
    }
    // --note ID: the note to hover, click and pin (default: the first placed)
    let pick = opt("--note")
    guard let first = pane.placedNotes.first(where: { $0.id == pick }) ?? pane.placedNotes.first else { NSApp.terminate(nil); return }
    view.scrollTo(page: first.page, y: first.line.minY)
    try? await Task.sleep(for: .milliseconds(900))
    if let shotOpt { shoot(view.window!, shotOpt) }
    let pt = view.notePoint(first.id)!
    view.hoverPages(at: pt)
    try? await Task.sleep(for: .milliseconds(300))
    log("bench: hover -> card \(view.noteCardShown ?? "none")")
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-hover.png")) }
    view.hoverPages(at: nil)
    let took = view.clickPages(at: pt)
    try? await Task.sleep(for: .milliseconds(120))
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-click.png")) }
    log("bench: click -> \(took ? "taken" : "not taken"), onCommentClick \(clicked ?? "none") \(clicked == first.id ? "ok" : "MISMATCH"), pinned \(view.notePinned ?? "none")")
    // pinned: it follows its note through a scroll and a zoom
    func gapToNote() -> String {
      guard let f = view.pinnedCardFrame, let p = view.notePoint(first.id) else { return "card hidden" }
      let m = view.toPane(p)
      return String(format: "card (%.0f, %.0f %.0f×%.0f), note at (%.0f, %.0f), card's right edge %.0f pt from the note", f.minX, f.minY, f.width, f.height, m.x, m.y, m.x - f.maxX)
    }
    log("bench: pinned: \(gapToNote())")
    let b0 = view.clipView.bounds.origin
    view.clipView.scroll(to: NSPoint(x: b0.x, y: b0.y + 120))
    view.scrollView.reflectScrolledClipView(view.clipView)
    try? await Task.sleep(for: .milliseconds(200))
    log("bench: scrolled 120 pt: \(gapToNote())")
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-pinned.png")) }
    let mag = view.scrollView.magnification
    view.scrollView.setMagnification(mag * 1.4, centeredAt: view.notePoint(first.id)!)
    try? await Task.sleep(for: .milliseconds(300))
    log("bench: zoomed ×1.4: \(gapToNote())")
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-pinned-zoomed.png")) }
    view.scrollView.magnification = mag
    let off = view.clickPages(at: NSPoint(x: pt.x - 200, y: pt.y))
    log("bench: then a click on the page -> pinned \(view.notePinned ?? "none")")
    log("bench: click off a note -> \(off ? "taken (WRONG)" : "passed on")")
    try? await Task.sleep(for: .milliseconds(800))
    pane.showComments = false
    try? await Task.sleep(for: .milliseconds(200))
    if let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-off.png")) }
    log("bench: toggled off -> click \(view.clickPages(at: pt) ? "taken (WRONG)" : "passed on")")
    pane.showComments = true
    NSApp.terminate(nil)
  }

  /// Word-level SyncTeX both ways: for each `--cols` column of `--line`, jump there (the word read off the page and
  /// matched), then click the middle of the box it marked and check the click comes back to the same source word.
  /// `--shot F.png`: the first forward mark; F-click.png: the first click.
  func runWords() async {
    let line = Int(jumpLine ?? "177") ?? 177
    var cols = (opt("--cols") ?? "0").split(separator: ",").compactMap { Int($0) }
    // --insert WORD (with --socket): first type " WORD" through the engine before the word at the first column, wait
    // for the page, then look for the new word (at its column) both ways
    if let word = opt("--insert"), let sock = socketOpt.map({ ($0 as NSString).expandingTildeInPath }), let col = cols.first {
      do {
        let c = try JSONRPCConnection(socket: sock)
        let p = try await c.call("project.open", ["folder": folder.path])
        let d = try await c.call("doc.open", ["project_id": p["project_id"] as! String, "path": mainFile])
        let bytes = Array((d["text"] as! String).utf8)
        var start = 0, n = 1
        for (i, b) in bytes.enumerated() where n < line && b == 10 { n += 1; start = i + 1 }
        let gen = pane.lastPages?.gen ?? 0
        _ = try await c.call("doc.edit", ["doc_id": d["doc_id"] as! String, "seq": d["seq"] as! Int, "edits": [["pos": start + col, "del": 0, "ins": word + " "]]])
        c.close()
        let t0 = CACurrentMediaTime()
        while !(pane.lastPages.map { $0.gen > gen && $0.done } ?? false) && CACurrentMediaTime() - t0 < 10 { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(600))  // SyncTeX is fetched once reports are quiet
        log("bench: inserted \(word) at \(line):\(col); the pane's copy of the line: \(pane.sourceLine(mainFile, line)?.contains(word) == true ? "has it" : "MISSING it")")
        cols[0] = col + 1
      } catch { log("bench: \(error)") }
    }
    let text = pane.sourceLine(mainFile, line) ?? ""
    if let r = pane.syncTex?.rows(file: mainFile, line: line) {
      log("bench: rows \(r.rows.map { String(format: "p%d y%.1f h%.1f", $0.page + 1, $0.rect.minY, $0.rect.height) }), marks \(r.marks)")
    }
    let src = WordMatch.sourceWords(text)
    var results: [[String: Any]] = []
    for (n, col) in cols.enumerated() {
      let want = WordMatch.wordIndex(src, column: col).map { src[$0] }
      let t0 = CACurrentMediaTime()
      let m0 = view.markCounts
      pane.jump(path: mainFile, line: line, column: col)
      var fwd: String?
      for _ in 0..<200 {
        try? await Task.sleep(for: .milliseconds(5))
        if let w = pane.lastForwardWord { fwd = w; break }
      }
      let fms = (CACurrentMediaTime() - t0) * 1000
      try? await Task.sleep(for: .milliseconds(330))
      guard let r = view.revealed else { continue }
      let u = r.rects.dropFirst().reduce(r.rects[0]) { $0.union($1) }
      log(String(format: "bench: col %d (%@) -> %@ in %.0f ms, box (%.1f, %.1f, %.1f × %.1f)", col, want?.text ?? "-",
        fwd ?? "line only", fms, u.minX, u.minY, u.width, u.height))
      try? await Task.sleep(for: .milliseconds(100))  // a late mark would show here
      let c1 = view.markCounts
      log("bench:   marks for the jump: \(c1.appear - m0.appear) appeared, \(c1.glide - m0.glide) glided, \(c1.stay - m0.stay) stayed")
      let bands = view.revealedLines.map { String(format: "(%.1f, %.1f, %.1f × %.1f)", $0.minX, $0.minY, $0.width, $0.height) }
      log("bench:   line band \(bands.isEmpty ? "none" : bands.joined(separator: " "))")
      if n == 0, let shotOpt { shoot(view.window!, shotOpt) }
      try? await Task.sleep(for: .milliseconds(900))
      let c0 = CACurrentMediaTime()
      await pane.syncClick(page: r.page, x: r.rects[0].midX, y: r.rects[0].midY)
      let cms = (CACurrentMediaTime() - c0) * 1000
      let inv = pane.lastInverse
      try? await Task.sleep(for: .milliseconds(450))  // the round trip's forward jump (PDFHost echoes like the app's cursor-follow)
      let c2 = view.markCounts
      log("bench:   marks for the double-click and its echo: \(c2.appear - c1.appear) appeared, \(c2.glide - c1.glide) glided, \(c2.stay - c1.stay) stayed")
      if n == 0, let shotOpt { shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-click.png")) }
      let back = inv?.column.map { c in WordMatch.wordIndex(src, column: c).map { src[$0] } } ?? nil
      let ok = inv?.line == line && back == want
      log(String(format: "bench: click -> %@:%d col %@ (%@) in %.0f ms %@", inv?.path ?? "-", inv?.line ?? -1,
        inv?.column.map(String.init) ?? "nil", inv?.word ?? "-", cms, ok ? "ok" : "MISMATCH"))
      results.append(["col": col, "want": want?.text ?? NSNull(), "forward": fwd ?? NSNull(), "forward_ms": fms.rounded(),
        "line_heights": view.revealedLines.map { ($0.height * 10).rounded() / 10 }, "inverse_col": inv?.column ?? NSNull(), "inverse_line": inv?.line ?? -1, "inverse_ms": cms.rounded(), "ok": ok])
      try? await Task.sleep(for: .milliseconds(700))
    }
    // the mark stays (no timed fade), then dims to an underline when idle
    if let shotOpt {
      pane.jump(path: mainFile, line: line, column: cols[0])
      try? await Task.sleep(for: .milliseconds(3000))
      shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-after3s.png"))
      view.dimMarkNow()
      try? await Task.sleep(for: .milliseconds(800))
      shoot(view.window!, shotOpt.replacingOccurrences(of: ".png", with: "-dimmed.png"))
    }
    let d = try! JSONSerialization.data(withJSONObject: ["kind": "words", "line": line, "results": results], options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    NSApp.terminate(nil)
  }

  var sentAt: CFTimeInterval = 0, swapAt: CFTimeInterval = 0
  var swaps: [Double] = [], shown: [Double] = [], pagesShown: [Int] = []

  /// Keystrokes through a second engine connection: doc.edit inserts a character (then deletes it) in a paragraph,
  /// timed from the send to the changed page's swap and to the frame that shows it.
  func runEdits() async {
    let sock = (socketOpt! as NSString).expandingTildeInPath
    do {
      let c = try JSONRPCConnection(socket: sock)
      let p = try await c.call("project.open", ["folder": folder.path])
      let d = try await c.call("doc.open", ["project_id": p["project_id"] as! String, "path": mainFile])
      let docId = d["doc_id"] as! String
      var seq = d["seq"] as! Int
      let text = Array((d["text"] as! String).utf8)
      let targets = (editTargets ?? "Paragraph 3.,Paragraph 14.").split(separator: ",").map(String.init)
      pane.onEditShown = { [weak self] ms, page in
        guard let self else { return }
        self.swaps.append(ms)
        self.pagesShown.append(page + 1)
        self.swapAt = CACurrentMediaTime()
      }
      for target in targets {
        guard let r = findBytes(text, Array(target.utf8)) else { log("bench: no \(target) in the doc"); continue }
        let pos = r + target.utf8.count - 1  // before the period
        for k in 0..<edits {
          try await Task.sleep(for: .milliseconds(1200))
          let before = swaps.count
          sentAt = CACurrentMediaTime()
          pane.noteEdit(at: sentAt)
          let ins = k % 2 == 0
          let e: [String: Any] = ["pos": pos, "del": ins ? 0 : 1, "ins": ins ? "x" : ""]
          let res = try await c.call("doc.edit", ["doc_id": docId, "seq": seq, "edits": [e]])
          seq = res["seq"] as? Int ?? seq
          for _ in 0..<200 where swaps.count == before { try await Task.sleep(for: .milliseconds(5)) }
          for _ in 0..<20 where shown.count < swaps.count { try await Task.sleep(for: .milliseconds(5)) }
          if swaps.count == before { log("bench: \(target) #\(k): nothing shown in 1 s"); swaps.append(-1); shown.append(-1); pagesShown.append(0) }
          else { log(String(format: "bench: %@ #%d: swap %.1f ms, on screen %.1f ms, page %d", target, k, swaps.last!, shown.last ?? -1, pagesShown.last!)) }
        }
      }
      c.close()
    } catch { log("bench: \(error)") }
    let r: [String: Any] = ["kind": "edit", "targets": editTargets ?? "Paragraph 3.,Paragraph 14.", "swap_ms": swaps, "shown_ms": shown, "pages": pagesShown]
    let d = try! JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    if let out { try? d.write(to: URL(fileURLWithPath: out)) }
    NSApp.terminate(nil)
  }

  /// One frame of motion at time t (s); true when done.
  func step(_ t: Double) -> Bool {
    let clip = view.clipView
    let docH = view.scrollView.documentView!.frame.height
    switch kind {
    case "scroll":
      // 8 s down through the document at a steady ~2400 pt/s, eased at both ends, then up again for 4 s
      let dur = 12.0
      let maxY = docH - clip.bounds.height
      let u = min(t / dur, 1)
      let f = u < 2.0 / 3 ? ease(u * 1.5) : 1 - ease((u - 2.0 / 3) * 3)
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: f * maxY * 0.98))
      view.scrollView.reflectScrolledClipView(clip)
      return u >= 1
    case "pinch":
      // 2 s in to 3×, 2 s out to 0.5×, 1 s back, anchored at the view's center
      if t < 0.02 { view.setLiveMagnify(true) }
      let m: CGFloat
      if t < 2 { m = startMag * (1 + 2 * ease(t / 2)) }
      else if t < 4 { m = startMag * (3 - 2.5 * ease((t - 2) / 2)) }
      else { m = startMag * (0.5 + 0.5 * ease(min((t - 4), 1))) }
      let c = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
      view.scrollView.setMagnification(m, centeredAt: c)
      return t >= 5
    case "edges":
      return edgeStep(t)
    default: return true
    }
  }

  func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

  // ---- edges: trackpad flicks into each edge, as real scroll events (phases, then momentum) ------------------------

  struct Edge { var name: String; var dx: Double; var dy: Double }
  let edgeList = [Edge(name: "top", dx: 0, dy: 1), Edge(name: "bottom", dx: 0, dy: -1),
                  Edge(name: "left", dx: 1, dy: 0), Edge(name: "right", dx: -1, dy: 0)]
  var edgeIdx = -1, edgeFrame = 0
  var edgeLog: [[Any]] = []  // [edge, frame, x, y]

  /// A continuous (trackpad) scroll event, delivered to the scroll view directly (no cursor or window focus needed).
  func sendScroll(dx: Double, dy: Double, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
    e.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    let win = view.window!
    e.location = CGPoint(x: win.frame.midX, y: NSScreen.screens[0].frame.maxY - win.frame.midY)
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.windowNumber))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(win.windowNumber))
    // to this process only: NSScrollView tracks a gesture by pulling its next events from the queue
    e.post(tap: .cghidEventTap)
  }

  func edgeStep(_ t: Double) -> Bool {
    let clip = view.clipView
    let doc = view.scrollView.documentView!.frame
    if edgeIdx < 0 {
      // the window server routes scroll events by the pointer: put it over the pane (put back at the end)
      savedCursor = CGEvent(source: nil)?.location
      NSApp.activate(ignoringOtherApps: true)
      view.window?.orderFrontRegardless()
      let w = view.window!.frame
      CGWarpMouseCursorPosition(CGPoint(x: w.midX, y: NSScreen.screens[0].frame.maxY - w.midY))
    }
    if edgeIdx < 0 || edgeFrame >= 300 {  // 2.5 s an edge
      edgeIdx += 1
      edgeFrame = 0
      if edgeIdx >= edgeList.count {
        if let c = savedCursor { CGWarpMouseCursorPosition(c) }
        return true
      }
      let e = edgeList[edgeIdx]
      if e.name == "left" { view.scrollView.magnification = startMag * 3 }
      let b = clip.bounds
      // start 500 pt from the edge
      var o = b.origin
      switch e.name {
      case "top": o.y = 500
      case "bottom": o.y = doc.height - b.height - 500
      case "left": o.x = 150; o.y = 300
      default: o.x = doc.width - b.width - 150
      }
      clip.setBoundsOrigin(o)
      view.scrollView.reflectScrolledClipView(clip)
    }
    let e = edgeList[edgeIdx]
    let f = edgeFrame
    edgeFrame += 1
    let b = clip.bounds
    edgeLog.append([e.name, f, Double(b.minX), Double(b.minY)])
    // 6 frames of finger at 70 pt/frame, lift, then momentum decaying 4 % a frame (as AppKit's own feels)
    let v = 70.0
    if f < 6 {
      sendScroll(dx: e.dx * v, dy: e.dy * v, phase: f == 0 ? .began : .changed, momentum: .none)
    } else if f == 6 {
      sendScroll(dx: 0, dy: 0, phase: .ended, momentum: .none)
    } else if f >= 7 {
      let k = Double(f - 7)
      let m = v * pow(0.96, k)
      if m > 0.5 {
        sendScroll(dx: e.dx * m, dy: e.dy * m, phase: nil, momentum: k == 0 ? .begin : .continuous)
      } else if f < 300, edgeLog.last.map({ _ in true }) == true, !momentumEnded.contains(edgeIdx) {
        momentumEnded.insert(edgeIdx)
        sendScroll(dx: 0, dy: 0, phase: nil, momentum: .end)
      }
    }
    return false
  }
  var momentumEnded: Set<Int> = []
  var savedCursor: CGPoint?

  /// Per edge: how often the motion reverses on its axis (a rubber band reverses once), the overshoot past the
  /// edge, where it came to rest.
  func edgeReport() -> [String: Any] {
    var r: [String: Any] = [:]
    let doc = view.scrollView.documentView!.frame
    for e in edgeList {
      let rows = edgeLog.filter { $0[0] as! String == e.name }
      let pos = rows.map { e.dy != 0 ? $0[3] as! Double : $0[2] as! Double }
      var reversals = 0, lastSign = 0.0
      var steps: [Double] = []
      for i in 1..<pos.count {
        let d = pos[i] - pos[i - 1]
        steps.append((d * 10).rounded() / 10)
        if abs(d) < 0.05 { continue }
        let s = d > 0 ? 1.0 : -1.0
        if lastSign != 0 && s != lastSign { reversals += 1 }
        lastSign = s
      }
      var stalls = 0
      if steps.count > 2 { for i in 1..<(steps.count - 1) where steps[i] == 0 && abs(steps[i - 1]) >= 0.2 && abs(steps[i + 1]) >= 0.2 && (steps[i - 1] > 0) == (steps[i + 1] > 0) { stalls += 1 } }
      r[e.name] = ["reversals": reversals, "stalls": stalls, "min": pos.min() ?? 0, "max": pos.max() ?? 0, "rest": pos.last ?? 0,
                   "doc": e.dy != 0 ? Double(doc.height) : Double(doc.width), "steps": steps.prefix(160).map { $0 }]
    }
    return r
  }

  func finish(_ l: CADisplayLink) {
    l.invalidate()
    let period = l.duration * 1000
    let iv = intervals.dropFirst()
    let sorted = iv.sorted()
    func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count) * p))] }
    let dropped = iv.reduce(0) { $0 + max(0, Int(($1 / period).rounded()) - 1) }
    let ws = work.sorted()
    var r: [String: Any] = [
      "kind": kind, "frames": iv.count, "period_ms": period,
      "interval_p50": pct(sorted, 0.5), "interval_p99": pct(sorted, 0.99), "interval_max": sorted.last ?? 0,
      "dropped": dropped, "work_p50": pct(ws, 0.5), "work_p99": pct(ws, 0.99), "work_max": ws.last ?? 0,
      "renders": view.renderCount, "render_p50": pct(view.renderMs.sorted(), 0.5),
      "settle_ms": settleMs, "pages": view.pageCount,
    ]
    if kind == "edges" { r["edges"] = edgeReport() }
    let d = try! JSONSerialization.data(withJSONObject: r, options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
    if let out { try? d.write(to: URL(fileURLWithPath: out)) }
    if let shotOpt, let w = view.window { shoot(w, shotOpt.replacingOccurrences(of: ".png", with: "-after.png")) }
    NSApp.terminate(nil)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(background ? .prohibited : .regular)
let host = Host()
app.delegate = host
app.run()
