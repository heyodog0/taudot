import AppKit
import Foundation
import Testing
@testable import TaudotNeovim
@testable import TaudotShared

// MARK: msgpack

@Test func msgpackRoundTrip() throws {
  let values: [Value] = [
    .null, .bool(true), .bool(false),
    .int(0), .int(127), .int(128), .int(255), .int(256), .int(65535), .int(65536), .int(1 << 40),
    .int(-1), .int(-32), .int(-33), .int(-128), .int(-129), .int(-40000), .int(-(1 << 40)),
    .float(1.5), .float(-0.25),
    .string(""), .string("héllo ✓ 😀"), .string(String(repeating: "x", count: 31)), .string(String(repeating: "y", count: 300)),
    .string(String(repeating: "z", count: 70000)),
    .binary([1, 2, 3]), .binary([UInt8](repeating: 7, count: 300)),
    .array([]), .array((0..<20).map { .int(Int64($0)) }),
    .map([(.string("a"), .int(1)), (.string("b"), .array([.null]))]),
    .map((0..<20).map { (.int(Int64($0)), .string("\($0)")) }),
  ]
  for v in values {
    var d = MsgPackDecoder()
    d.feed(MsgPack.encode(v))
    #expect(try d.next() == v)
    #expect(try d.next() == nil)
  }
}

@Test func msgpackStreamsByteByByte() throws {
  let vs: [Value] = [.array([.int(2), .string("redraw"), .array([.array([.string("flush"), .array([])])])]), .int(-5), .string("ok")]
  let bytes = vs.flatMap { MsgPack.encode($0) }
  var d = MsgPackDecoder()
  var out: [Value] = []
  for b in bytes { d.feed([b]); out += try d.drain() }
  #expect(out == vs)
}

@Test func msgpackKnownBytes() throws {
  #expect(MsgPack.encode(.int(-1)) == [0xff])
  #expect(MsgPack.encode(.int(200)) == [0xcc, 200])
  #expect(MsgPack.encode(.array([.int(1), .string("a")])) == [0x92, 0x01, 0xa1, 0x61])
  // Neovim EXT handle (Window 1000 as fixext2 with a uint16 payload is not valid msgpack-int; use int16 0xcd form).
  var d = MsgPackDecoder()
  d.feed([0xd6, 0x01, 0xcd, 0x03, 0xe8, 0x00]) // fixext4, type 1, payload: uint16 1000 + pad
  #expect(try d.next() == .int(1000))
  d.feed([0xd4, 0x00, 0x05]) // fixext1, Buffer 5
  #expect(try d.next() == .int(5))
}

@Test func msgpackFloat32() throws {
  var d = MsgPackDecoder()
  d.feed([0xca, 0x3f, 0xc0, 0x00, 0x00])
  #expect(try d.next() == .float(1.5))
}

// MARK: RPC against a real nvim

@MainActor func headless() throws -> Neovim {
  try Neovim(args: ["--clean", "--headless", "-n"])
}

@Test @MainActor func rpcRequestsAndNotifications() async throws {
  let nv = try headless()
  defer { nv.terminate() }
  #expect(try await nv.request("nvim_eval", [.string("1+2")]) == .int(3))
  #expect(try await nv.execLua("return {...}", [.int(1), .string("x")]) == .array([.int(1), .string("x")]))
  try await nv.command("let g:t = 42")
  #expect(try await nv.request("nvim_get_var", [.string("t")]) == .int(42))
  // Errors come back as thrown NeovimError.
  await #expect(throws: NeovimError.self) { try await nv.command("nosuchcommand") }
  // rpcnotify reaches the registered handler on the main actor.
  let chan = try await nv.channelID()
  let got = await withCheckedContinuation { (c: CheckedContinuation<[Value], Never>) in
    nv.notify("taudot_test") { args in c.resume(returning: args) }
    Task { _ = try await nv.execLua("vim.rpcnotify(\(chan), 'taudot_test', 'a', {b = 1})", []) }
  }
  #expect(got.first == .string("a"))
  #expect(got.last?["b"] == .int(1))
}

@Test @MainActor func rpcManyConcurrentRequests() async throws {
  let nv = try headless()
  defer { nv.terminate() }
  let rpc = nv.rpc
  try await withThrowingTaskGroup(of: (Int, Value).self) { g in
    for i in 0..<200 { g.addTask { (i, try await rpc.request("nvim_eval", [.string("\(i)*2")])) } }
    for try await (i, v) in g { #expect(v == .int(Int64(i * 2))) }
  }
}

// MARK: UI protocol against a real nvim

@MainActor final class UIHarness {
  let nv: Neovim
  let ui = UIModel()
  var flushes = 0
  var scrolls: [Int: Int] = [:]
  var waiters: [(UIModel) -> Bool] = []
  var conts: [CheckedContinuation<Void, Never>] = []

  init(width: Int = 80, height: Int = 24) async throws {
    nv = try Neovim(args: ["--clean", "-n"])
    nv.onRedraw = { [ui] in ui.apply($0) }
    ui.onFlush = { [unowned self] m in
      flushes += 1
      for (g, d) in m.pendingScroll { scrolls[g, default: 0] += d }
      check()
    }
    _ = try await nv.request("nvim_ui_attach", [.int(Int64(width)), .int(Int64(height)),
      .map([(.string("ext_linegrid"), .bool(true)), (.string("ext_multigrid"), .bool(true)), (.string("rgb"), .bool(true))])])
  }

  func check() {
    var i = 0
    while i < waiters.count { if waiters[i](ui) { waiters.remove(at: i); conts.remove(at: i).resume() } else { i += 1 } }
  }

  /// Wait (up to 3 s) for a flush after which `cond` holds.
  func until(_ cond: @escaping (UIModel) -> Bool) async {
    if cond(ui) { return }
    let timeout = Task { @MainActor in try await Task.sleep(for: .seconds(3)); self.waiters.append { _ in true }; self.check() }
    await withCheckedContinuation { c in waiters.append(cond); conts.append(c) }
    timeout.cancel()
  }

  func mainGrid() -> Grid? { ui.windows.values.first { $0.kind == .normal && $0.grid != 1 }.flatMap { ui.grids[$0.grid] } }
}

@Test @MainActor func uiGridsWindowsAndScroll() async throws {
  let h = try await UIHarness()
  defer { h.nv.terminate() }
  _ = try await h.nv.execLua("vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(function(i) return 'line ' .. i end, vim.fn.range(1, 200)))", [])
  await h.until { $0.windows.values.contains { $0.kind == .normal && $0.grid != 1 } && ($0.grids[2]?.rows[0].text.hasPrefix("line 1 ") ?? false) }
  let g = try #require(h.mainGrid())
  #expect(g.rows[0].text.hasPrefix("line 1 "))
  #expect(g.rows[1].text.hasPrefix("line 2 "))
  let w = try #require(h.ui.windows[g.id])
  #expect(w.width == 80)
  #expect(w.topline == 0)
  #expect(h.ui.hl.count > 1)
  #expect(!h.ui.modes.isEmpty)

  // Scroll by 5: win_viewport reports scroll_delta 5 and the grid shows line 6 on top.
  var ss = SmoothScroll()
  ss.reset(g.rows[...])
  h.ui.onFlush = { [unowned h] m in
    h.flushes += 1
    for (gid, d) in m.pendingScroll { h.scrolls[gid, default: 0] += d }
    if let gg = m.grids[g.id] { ss.flush(gg.rows[...], delta: m.pendingScroll[g.id] ?? 0) }
    h.check()
  }
  h.nv.input("5<C-e>")
  await h.until { $0.windows[g.id]?.topline == 5 }
  #expect(h.scrolls[g.id] == 5)
  #expect(g.rows[0].text.hasPrefix("line 6 "))
  // The old top lines are kept above, and the view starts 5 lines up, animating to 0.
  #expect(ss.spring.position == -5)
  #expect(ss.row(-5)?.text.hasPrefix("line 1 ") == true)
  #expect(ss.visible().first?.row.text.hasPrefix("line 1 ") == true)
  var t = 0.0
  while ss.step(1.0 / 120, length: 0.12) { t += 1.0 / 120 }
  #expect(t > 0.1 && t < 0.3)
  #expect(ss.visible().first?.row.text.hasPrefix("line 6 ") == true)

  // A float gets a position and a z-index above the main window.
  _ = try await h.nv.execLua("vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {relative='editor', row=3, col=10, width=20, height=4, border='none'})", [])
  await h.until { $0.windows.values.contains { $0.kind == .floating } }
  let f = try #require(h.ui.windows.values.first { $0.kind == .floating })
  #expect(f.row == 3 && f.col == 10 && f.width == 20 && f.height == 4)
  let order = h.ui.drawOrder.map(\.grid)
  #expect(order.firstIndex(of: f.grid)! > order.firstIndex(of: g.id)!)

  // option_set and default colours.
  try await h.nv.command("set linespace=3")
  await h.until { $0.linespace == 3 }
  #expect(h.ui.linespace == 3)
}

@Test func springSettlesAndRetargets() {
  var s = Spring()
  s.position = -10
  var frames = 0
  while s.step(1.0 / 120, length: 0.12) { frames += 1; if frames == 6 { s.position -= 5 } }
  #expect(s.position == 0)
  #expect(frames > 12 && frames < 60)
}

// MARK: EditorView geometry during a smooth scroll

@Test @MainActor func editorGeometryFollowsSmoothScroll() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  // No window: no display link, so the test drives the frames itself.
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 640, height: 480))
  var changes = 0
  v.onChange { changes += 1 }
  try await v.attach()
  // Line 2 (0-based) wraps to 3 rows at this width; the rest are short.
  _ = try await nv.execLua("""
    local l = {}
    for i = 1, 300 do l[i] = 'line ' .. (i - 1) end
    l[3] = string.rep('wrap ', 80)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, l)
    """, [])
  // y(ofLine:) describes the last drawn frame: waits draw frames (at a fixed time, so no animation advances).
  var t = 1000.0
  func waitFor(_ cond: @escaping () -> Bool) async {
    for _ in 0..<1000 { v.advance(now: t); if cond() { break }; try? await Task.sleep(for: .milliseconds(10)) }
  }
  // Wrapped line 2 (400 characters) takes w rows, so line 3 sits 2 + w rows down and line 10 9 + w. Wait for exactly
  // that: before Neovim's line map arrives y() estimates without wraps (line 3 at 3 rows), which ran parallel tests
  // 4 rows (62 pt) off.
  let w = CGFloat((400 + v.cols - 1) / v.cols)
  await waitFor { v.y(ofLine: 10) != nil && v.y(ofLine: 3).map { abs($0 - (2 + w) * v.lineHeight) < 0.6 } == true }
  let lh = v.lineHeight
  #expect(lh > 5)
  let y3 = try #require(v.y(ofLine: 3)), y10 = try #require(v.y(ofLine: 10))
  #expect(abs(y3 - (2 + w) * lh) < 0.6)
  #expect(abs(y10 - (9 + w) * lh) < 0.6)
  #expect(v.visibleLines.lowerBound == 0)

  // Scroll 5 lines (= 4 + w screen rows: the wrapped line is among them).
  nv.input("5<C-e>")
  await waitFor { v.ui.windows[v.currentGrid]?.topline == 5 }
  // At the flush the content hasn't jumped: the animation starts where the old view was (the frame drawn after the
  // flush may already be one animation step, a few pt, along).
  #expect(abs(v.y(ofLine: 10)! - y10) < 6)
  var ys: [CGFloat] = []
  changes = 0
  for _ in 0..<60 { t += 1.0 / 120; v.advance(now: t); ys.append(v.y(ofLine: 10)!) }
  // Moves up monotonically, by pixels (many distinct values), to 4 + w rows higher; onChange each frame.
  #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 >= $1 })
  #expect(Set(ys).count > 10)
  #expect(abs(ys.last! - (y10 - (4 + w) * lh)) < 0.6)
  #expect(changes >= 10)
  // Lines that scrolled out keep a position above the top while the animation runs.
  await waitFor { v.y(ofLine: 6) != nil }
  #expect(abs(v.y(ofLine: 6)! - 1 * lh) < 0.6)
}

// MARK: input

@MainActor func keyEvent(_ chars: String, _ ign: String? = nil, code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                   characters: chars, charactersIgnoringModifiers: ign ?? chars, isARepeat: false, keyCode: code)!
}

@Test @MainActor func keyNotationAndIME() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv)
  #expect(v.keyNotation(keyEvent("a")) == nil)  // plain text goes through the input system
  #expect(v.keyNotation(keyEvent("\u{1}", "a", [.control])) == "<C-a>")
  #expect(v.keyNotation(keyEvent("\u{1}", "A", [.control, .shift])) == "<C-S-a>")
  #expect(v.keyNotation(keyEvent("≈", "x", [.option])) == "<M-x>")
  #expect(v.keyNotation(keyEvent("s", "s", [.command])) == "<D-s>")
  #expect(v.keyNotation(keyEvent("\r", code: 36)) == "<CR>")
  #expect(v.keyNotation(keyEvent("\u{1b}", code: 53)) == "<Esc>")
  #expect(v.keyNotation(keyEvent("\t", code: 48, [.shift])) == "<S-Tab>")
  #expect(v.keyNotation(keyEvent(String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), nil, [.control])) == "<C-Up>")
  #expect(v.keyNotation(keyEvent(String(UnicodeScalar(UInt16(NSF5FunctionKey))!))) == "<F5>")
  #expect(v.keyNotation(keyEvent(" ", code: 49, [.control])) == "<C-Space>")
  #expect(v.keyNotation(keyEvent("<", "<", [.control])) == "<C-lt>")
  v.optionAsMeta = false
  #expect(v.keyNotation(keyEvent("≈", "x", [.option])) == nil)  // Option types the character

  try await v.attach()
  try await nv.command("startinsert")
  // IME: marked text isn't sent; the committed text is, with "<" escaped.
  v.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
  #expect(v.hasMarkedText())
  v.insertText("日本<語", replacementRange: NSRange(location: NSNotFound, length: 0))
  #expect(!v.hasMarkedText())
  var line = ""
  for _ in 0..<100 {
    line = try await nv.execLua("return vim.api.nvim_get_current_line()", []).string ?? ""
    if !line.isEmpty { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(line == "日本<語")
}

@Test @MainActor func resizeAndGuifont() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 640, height: 480))
  try await v.attach()
  func waitFor(_ cond: @escaping () -> Bool) async {
    for _ in 0..<1000 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
  }
  await waitFor { v.ui.grids[1]?.width == v.cols }
  let cols0 = v.cols, rows0 = v.rows
  #expect(v.ui.grids[1]?.width == cols0 && v.ui.grids[1]?.height == rows0)
  v.setFrameSize(NSSize(width: 960, height: 600))
  #expect(v.cols > cols0 && v.rows > rows0)
  await waitFor { v.ui.grids[1]?.width == v.cols && v.ui.grids[1]?.height == v.rows }
  #expect(v.ui.grids[1]?.width == v.cols && v.ui.grids[1]?.height == v.rows)
  let lh0 = v.lineHeight, cols1 = v.cols
  try await nv.command("set guifont=Menlo:h20 linespace=4")
  await waitFor { v.lineHeight > lh0 + 4 && v.ui.grids[1]?.width == v.cols }
  #expect(v.lineHeight > lh0 + 4)
  #expect(v.cols < cols1)
  #expect(v.ui.grids[1]?.width == v.cols)
}

// MARK: smooth scroll ring never draws a row saved for another position (user's stale-rows report)

@Test func ringNeverShowsRowsFromOtherPositions() {
  func row(_ line: Int) -> Row { var r = Row(width: 1); r.cells = [Cell("L\(line)")]; return r }
  var rng = SystemRandomNumberGenerator()
  for h in [3, 10, 40] {
    var s = SmoothScroll()
    var top = 1000
    s.reset((top..<top + h).map(row)[...])
    for _ in 0..<3000 {
      let delta = Int.random(in: -(2 * h + 5)...(2 * h + 5), using: &rng) / (Bool.random() ? 1 : 4)
      top += delta
      s.flush((top..<top + h).map(row)[...], delta: delta, fromFinger: Bool.random())
      // Any offset, including far past the kept rows (the user's case: a finger offset of 41 rows).
      s.finger = Double.random(in: -3 * Double(h)...3 * Double(h))
      for v in s.visible() {
        #expect(v.row.text == "L\(top + v.k)", "h \(h): k \(v.k) shows \(v.row.text), want L\(top + v.k)")
        if v.row.text != "L\(top + v.k)" { return }
      }
    }
  }
}

// MARK: trackpad scrolling end to end (user's reports: stale rows, blank top, bounce)

@MainActor func trackpadEvent(_ v: EditorView, dy: Double, phase: Int64, momentum: Int64) -> NSEvent? {
  guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return nil }
  e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
  e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
  // A window-less event's location is in screen coordinates; with no window the view reads it as its own.
  let primary = NSScreen.screens.first?.frame.height ?? 1000
  e.location = CGPoint(x: v.bounds.midX, y: primary - v.bounds.midY)
  return NSEvent(cgEvent: e)
}

@Test @MainActor func trackpadScrollDrawsNeovimsRows() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 700, height: 500))
  v.traceRows = true
  try await v.attach()
  // The paper's shape: one long paragraph per line, blank lines between, the user's display options.
  _ = try await nv.execLua("""
    vim.o.scrolloff = 8; vim.wo.wrap = true; vim.wo.linebreak = true; vim.wo.breakindent = true
    vim.wo.smoothscroll = true; vim.wo.cursorline = true; vim.wo.number = true; vim.wo.relativenumber = true
    local l = {}
    for i = 1, 400 do
      l[#l + 1] = (i % 3 == 0) and '' or ('para ' .. i .. ' ' .. string.rep('words that wrap across the window ', (i * 7) % 11 + 1))
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, l)
    """, [])
  var t = 1000.0
  // A frame is drawn right after each event, before Neovim can answer (the app saw a gesture's first redraw come
  // 8–30 ms late), then Neovim gets a moment.
  func frames(_ n: Int) async {
    for _ in 0..<n { t += 1.0 / 120; v.advance(now: t); try? await Task.sleep(for: .milliseconds(3)) }
  }
  await frames(30)
  let grid = v.currentGrid
  #expect(grid > 1)
  var lastPos = v.scrolls[grid]?.position ?? 0
  var backwards = 0, cursorOff = 0, cursorHops = 0
  var lastCursor: Int?
  func check(_ dir: Double) {
    let p = v.scrolls[grid]?.position ?? 0
    if (p - lastPos) * dir < -0.02 { backwards += 1 }
    lastPos = p
    // The cursor rides with its line: never drawn away from it while the text scrolls.
    if let c = v.debugCursor {
      if max(abs(c.offY), abs(c.offX)) > 0.5 { cursorOff += 1 }
      if let l = lastCursor, l != c.abs { cursorHops += 1 }
      lastCursor = c.abs
    }
  }
  func gesture(_ dy: Double, events: Int, momentum: Bool) async {
    let dir: Double = dy < 0 ? 1 : -1
    if let e = trackpadEvent(v, dy: dy, phase: 1, momentum: 0) { v.scrollWheel(with: e) }
    for _ in 0..<events {
      await frames(1); check(dir)
      if let e = trackpadEvent(v, dy: dy, phase: 2, momentum: 0) { v.scrollWheel(with: e) }
    }
    if let e = trackpadEvent(v, dy: 0, phase: 4, momentum: 0) { v.scrollWheel(with: e) }
    if momentum {
      var m = dy
      if let e = trackpadEvent(v, dy: m, phase: 0, momentum: 1) { v.scrollWheel(with: e) }
      while abs(m) > 1 {
        await frames(1); check(dir)
        m *= 0.93
        if let e = trackpadEvent(v, dy: m, phase: 0, momentum: 2) { v.scrollWheel(with: e) }
      }
      if let e = trackpadEvent(v, dy: 0, phase: 0, momentum: 3) { v.scrollWheel(with: e) }
    }
    for _ in 0..<1000 { await frames(1); check(dir); if v.scrollSettled(grid: grid) { break } }
    await frames(5)
    #expect(v.scrollSettled(grid: grid))
    #expect(v.drawnRows(grid: grid) == v.gridRows(grid: grid), "after a gesture the drawn rows are Neovim's")
  }
  await gesture(-40, events: 6, momentum: true)
  await gesture(-40, events: 6, momentum: true)
  await gesture(-7, events: 30, momentum: false)
  await gesture(35, events: 6, momentum: true)
  await gesture(7, events: 30, momentum: false)
  #expect(v.debugBlankRows == 0, "no frame drew a blank row where Neovim has text")
  #expect(backwards == 0, "the view never moved against the gesture")
  #expect(v.visibleLines.lowerBound > 0, "it scrolled")
  #expect(cursorHops > 0, "Neovim dragged the cursor along (scrolloff)")
  #expect(cursorOff == 0, "the cursor never glided on its own while the text scrolled")
  // A cursor move of the user's own (no scroll) still glides.
  try? await Task.sleep(for: .milliseconds(300))  // past the gesture's tail
  v.nvim.input("H")
  await frames(30)
  v.nvim.input("2j")
  var glided = false
  for _ in 0..<40 { await frames(1); if let c = v.debugCursor, abs(c.offY) > 0.5 { glided = true; break } }
  #expect(glided, "keys still animate the cursor")
}

// MARK: EditorGeometry describes the drawn frame (margin's captures: cards a row or a few pt off while scrolling)

@Test @MainActor func geometryMatchesTheDrawnFrame() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 700, height: 500))
  v.traceRows = true
  try await v.attach()
  // Wrapped paragraphs tagged L<n> at their start (continuation rows hold only lowercase words), blank lines between.
  _ = try await nv.execLua("""
    vim.o.scrolloff = 8; vim.wo.wrap = true; vim.wo.linebreak = true; vim.wo.breakindent = true
    vim.wo.smoothscroll = true; vim.wo.number = true; vim.wo.relativenumber = true
    local l = {}
    for i = 1, 400 do
      l[#l + 1] = (i % 3 == 0) and '' or ('L' .. i .. ' ' .. string.rep('words that wrap across the window ', (i * 7) % 11 + 1))
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, l)
    """, [])
  var t = 2000.0
  let tag = try Regex(#"^\s*\d*\s*L(\d+) "#, as: (Substring, Substring).self)
  var checked = 0, cursorChecked = 0, wrong: [String] = [], markerDrawn = 0, markerInNeovim = 0
  func verify() {
    for (y, text) in v.debugDrawn {
      guard let m = text.firstMatch(of: tag), let n = Int(m.1) else { continue }
      checked += 1
      let g = v.y(ofLine: n - 1)
      if g.map({ abs($0 - y) > 0.01 }) ?? true {
        if wrong.count < 8 { wrong.append("line \(n - 1) drawn at \(y), geometry \(g.map { "\($0)" } ?? "nil")") }
        else { wrong.append("") }
      }
    }
    // Neovim's smoothscroll marker is never drawn (Neovim shows it on the top row while a line is partly scrolled).
    if v.debugDrawn.contains(where: { $0.1.hasPrefix("<<<") }) { markerDrawn += 1 }
    if v.gridRowsRaw(grid: v.currentGrid).contains(where: { $0.hasPrefix("<<<") }) { markerInNeovim += 1 }
    // The cursor (geometry's cursorRect) sits on a drawn row of this frame.
    // (Not mid-glide, and not on a row scrolled just past the window's edge, where it is clipped away.)
    if let d = v.debugCursor, d.offY == 0, let c = v.cursorRect, let last = v.debugDrawn.map(\.0).max(), c.minY <= last {
      cursorChecked += 1
      if !v.debugDrawn.contains(where: { abs($0.0 - c.minY) < 0.01 }) && wrong.count < 8 { wrong.append("cursor at \(c.minY), no row there (rows \(v.debugDrawn.map(\.0).filter { abs($0 - c.minY) < 40 }), off \(d))") }
    }
  }
  func frames(_ n: Int) async {
    for _ in 0..<n { t += 1.0 / 120; v.advance(now: t); verify(); try? await Task.sleep(for: .milliseconds(3)) }
  }
  // Waits on events, not time (other builds may load the machine): after an action, until Neovim has flushed for it,
  // no line map is in flight, the scroll and the cursor have come to rest, and a few more frames passed without a flush.
  var flushes = 0
  v.onFlush = { flushes += 1 }
  func settle(after f0: Int) async {
    var quiet = 0, last = flushes
    for _ in 0..<5000 {
      await frames(1)
      let rest = flushes > f0 && !v.lineMapPending && v.scrollSettled(grid: v.currentGrid) && (v.debugCursor?.offY ?? 0) == 0
      if rest && flushes == last { quiet += 1 } else { quiet = 0 }
      last = flushes
      if quiet >= 10 { return }
    }
    Issue.record("never settled")
  }
  func key(_ k: String) async { let f0 = flushes; v.nvim.input(k); await settle(after: f0) }
  await settle(after: -1)
  checked = 0; wrong = []
  func gesture(_ dy: Double, events: Int, momentum: Bool) async {
    if let e = trackpadEvent(v, dy: dy, phase: 1, momentum: 0) { v.scrollWheel(with: e) }
    for _ in 0..<events {
      await frames(1)
      if let e = trackpadEvent(v, dy: dy, phase: 2, momentum: 0) { v.scrollWheel(with: e) }
    }
    if let e = trackpadEvent(v, dy: 0, phase: 4, momentum: 0) { v.scrollWheel(with: e) }
    if momentum {
      var m = dy
      if let e = trackpadEvent(v, dy: m, phase: 0, momentum: 1) { v.scrollWheel(with: e) }
      while abs(m) > 1 {
        await frames(1)
        m *= 0.93
        if let e = trackpadEvent(v, dy: m, phase: 0, momentum: 2) { v.scrollWheel(with: e) }
      }
      if let e = trackpadEvent(v, dy: 0, phase: 0, momentum: 3) { v.scrollWheel(with: e) }
    }
    await settle(after: -1)
  }
  await gesture(-40, events: 6, momentum: true)
  await gesture(-40, events: 6, momentum: true)
  await gesture(-7, events: 30, momentum: false)
  await gesture(35, events: 6, momentum: true)
  await gesture(7, events: 30, momentum: false)
  for k in ["<C-d>", "<C-d>", "<C-u>", "<C-e><C-e><C-e>", "<C-y>"] { await key(k) }
  #expect(checked > 1000, "line starts checked: \(checked)")
  #expect(wrong.isEmpty, "\(wrong.count) of \(checked) line starts drawn elsewhere than y(ofLine:): \(wrong.prefix(8))")
  #expect(cursorChecked > 500, "cursor checks: \(cursorChecked)")
  #expect(markerInNeovim > 0 && markerDrawn == 0, "<<< in Neovim's grid \(markerInNeovim) frames, drawn \(markerDrawn)")
  // A float takes the cursor; the main window scrolls 3 rows under it: cursorRect moves with the text.
  await key("M")
  let before = try #require(v.cursorRect)
  let f0 = flushes
  _ = try await nv.execLua("""
    local main = vim.api.nvim_get_current_win()
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, { relative = 'editor', row = 2, col = 10, width = 20, height = 3 })
    vim.api.nvim_win_call(main, function() vim.cmd('normal! 3' .. vim.keycode('<C-e>')) end)
    """, [])
  await settle(after: f0)
  let after = try #require(v.cursorRect)
  #expect(v.ui.cursorGrid != v.currentGrid, "the float has the cursor")
  // On a row of the drawn text (the scroll may settle a pixel off whole rows), 3 rows up.
  #expect(v.debugDrawn.contains { abs($0.0 - after.minY) < 0.01 }, "cursor at \(after.minY) on a drawn row")
  #expect(abs((before.minY - after.minY) - 3 * v.lineHeight) <= 0.5, "cursor \(before.minY) → \(after.minY), 3 rows = \(3 * v.lineHeight)")
  #expect(after.minX == before.minX)
}

// MARK: quitting (⌘Q, ⌘W, close button)

@MainActor func quitNvim(_ lua: String = "") async throws -> (Neovim, URL) {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("txs-quit-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let f = dir.appendingPathComponent("notes.txt")
  try "old\n".write(to: f, atomically: true, encoding: .utf8)
  let nv = try Neovim(args: ["--clean", "--headless", "-n", f.path])
  _ = try await nv.execLua("vim.api.nvim_buf_set_lines(0, 0, -1, false, {'new'})" + lua, [])
  return (nv, f)
}

@Test @MainActor func quitAsksOnlyAboutNonTaudotBuffers() async throws {
  // A taudot buffer (registered in taudot.buffer.by_buf), modified: synced live, so not asked about.
  let (nv, f) = try await quitNvim("""
  ; local b = vim.api.nvim_create_buf(true, false); vim.api.nvim_buf_set_name(b, 'synced.tex')
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {'edited'}); vim.bo[b].modified = true
  package.loaded['taudot.buffer'] = { by_buf = { [b] = true } }
  """)
  var asked: [String] = []
  let t0 = CACurrentMediaTime()
  let ok = await nv.quit { bufs, _ in asked = bufs.map { ($0.name as NSString).lastPathComponent }; return .save }
  #expect(ok)
  #expect(asked == ["notes.txt"])
  #expect(!nv.isRunning)
  #expect(CACurrentMediaTime() - t0 < 3)  // slack for a loaded parallel run
  #expect(try String(contentsOf: f, encoding: .utf8) == "new\n")
}

@Test @MainActor func quitDiscardAndCancel() async throws {
  let (nv, f) = try await quitNvim()
  #expect(await nv.quit { _, _ in .cancel } == false)
  #expect(nv.isRunning)
  #expect(await nv.quit { _, _ in .discard })
  #expect(!nv.isRunning)
  #expect(try String(contentsOf: f, encoding: .utf8) == "old\n")
}

@Test @MainActor func quitNeverHangs() async throws {
  // Neovim stuck in a prompt that blocks the API, then stuck for good: quit still returns, Neovim gone.
  let (nv, _) = try await quitNvim()
  nv.input(":call input('waiting: ')<CR>")
  try await Task.sleep(for: .milliseconds(200))
  var t0 = CACurrentMediaTime()
  #expect(await nv.quit { _, _ in .discard })
  #expect(!nv.isRunning)
  #expect(CACurrentMediaTime() - t0 < 4)  // quit gives up after ~2 s; slack for a loaded parallel run

  let (hung, _) = try await quitNvim()
  hung.send("nvim_exec_lua", [.string("while true do end"), .array([])])
  try await Task.sleep(for: .milliseconds(200))
  t0 = CACurrentMediaTime()
  #expect(await hung.quit { _, _ in .save })
  #expect(!hung.isRunning)
  #expect(CACurrentMediaTime() - t0 < 4)  // quit gives up after ~2 s; slack for a loaded parallel run
}

// MARK: box drawing and blocks fill their cells

@Test @MainActor func blockAndBoxCharactersFillTheirCells() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 500, height: 300))
  try await v.attach()
  // A line height well above the font's, where font glyphs leave gaps between rows.
  _ = try await nv.execLua("""
    vim.o.linespace = 10
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      '██████', '██████', '──────', '▐▛███▜▌', '▝▜█████▛▘', '│ ╭──╮ ║ ══', '│ ╰──╯ ║ ╔╗', '▌🬀🬁▐ ░▒▓', '',
    })
    vim.api.nvim_win_set_cursor(0, { 9, 0 })  -- the block cursor would draw a cell inverted
    """, [])
  var t = 1000.0
  for _ in 0..<60 { t += 1.0 / 60; v.advance(now: t); try await Task.sleep(for: .milliseconds(5)) }
  #expect(v.font.linespace == 10)
  let surf = try #require(v.surfaceLayer.contents.map { $0 as! IOSurface })
  surf.lock(options: .readOnly, seed: nil)
  defer { surf.unlock(options: .readOnly, seed: nil) }
  let base = surf.baseAddress.assumingMemoryBound(to: UInt8.self), bpr = surf.bytesPerRow
  func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let p = base + y * bpr + x * 4; return (Int(p[2]), Int(p[1]), Int(p[0])) }
  let cw = Int(v.font.cellWidth), ch = Int(v.font.cellHeight)
  let bg = px(cw * 30, ch / 2)  // an empty cell
  func ink(_ x: Int, _ y: Int) -> Bool { let p = px(x, y); return abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 60 }
  // █ above █: no background row between them, at every column of the six cells.
  var gaps = 0
  for x in stride(from: 0, to: 6 * cw, by: 1) { for y in 0..<(2 * ch) where !ink(x, y) { gaps += 1 } }
  #expect(gaps == 0, "\(gaps) background pixels inside two rows of █ (cell \(cw)×\(ch))")
  // ─ next to ─: one pixel row is ink across all six cells.
  let row2 = (2 * ch)..<(3 * ch)
  #expect(row2.contains { y in (0..<(6 * cw)).allSatisfy { ink($0, y) } }, "─ ─ ─ joins across cells")
  // │ above │ (rows 5–6, column 0) and ║ (column 7): continuous through both rows.
  func column(_ c: Int) -> [Int] { (0..<cw).filter { dx in ((5 * ch)..<(7 * ch)).allSatisfy { ink(c * cw + dx, $0) } } }
  #expect(!column(0).isEmpty, "│ │ joins across rows")
  let dbl = column(7)
  #expect(dbl.count >= 2 && zip(dbl, dbl.dropFirst()).contains { $1 - $0 > 1 }, "║ ║: two lines, continuous: \(dbl)")
  // The Claude logo's rows (3–4): the █ in column 3 runs through both rows.
  #expect(((3 * ch)..<(5 * ch)).allSatisfy { ink(3 * cw + cw / 2, $0) }, "logo: █ over █ without a gap")
  // ╭──╮ and ╰──╯ (columns 2–5): the top and bottom runs touch their corners.
  #expect(((2 * cw + cw / 2 + 2)..<(5 * cw + cw / 2 - 2)).allSatisfy { x in row5Has(x) }, "╭──╮ is one line")
  func row5Has(_ x: Int) -> Bool { ((5 * ch)..<(6 * ch)).contains { ink(x, $0) } }
  // Shades: ░ ▒ ▓ step from the background towards the fg (columns 5–7 of row 7).
  func lum(_ c: Int) -> Int { let p = px(c * cw + cw / 2, 7 * ch + ch / 2); return p.0 + p.1 + p.2 }
  #expect(lum(5) < lum(6) && lum(6) < lum(7) || lum(5) > lum(6) && lum(6) > lum(7), "shades step: \(lum(5)) \(lum(6)) \(lum(7))")
}

// MARK: themes and settings

@Test func themeGroupsAreCompleteAndUnique() {
  for t in Theme.builtIn {
    let g = ThemeLua.groups(t)
    #expect(g.count > 100, "\(t.id): \(g.count) groups")
    #expect(Set(g.map(\.0)).count == g.count, "\(t.id): duplicate group names")
    for name in ["Normal", "LineNr", "Pmenu", "Visual", "Search", "DiagnosticInfo", "texCmd", "@function.latex", "@markup.math.latex"] {
      #expect(g.contains { $0.0 == name }, "\(t.id) lacks \(name)")
    }
  }
}

@Test @MainActor func themeAppliesToNeovimAndRestoresTheUsersColours() async throws {
  let nv = try headless()
  defer { nv.terminate() }
  func hl(_ name: String) async throws -> (fg: Int?, bg: Int?) {
    let v = try await nv.execLua("local h = vim.api.nvim_get_hl(0, { name = ..., link = false }); return { h.fg or -1, h.bg or -1 }", [.string(name)])
    let a = v.array ?? []
    let f = a.first?.int ?? -1, b = a.count > 1 ? a[1].int ?? -1 : -1
    return (f < 0 ? nil : f, b < 0 ? nil : b)
  }
  func str(_ lua: String) async throws -> String { try await nv.execLua("return " + lua, []).string ?? "" }
  _ = try await nv.execLua("vim.cmd.colorscheme('habamax')", [])
  let userNormal = try await hl("Normal"), userBg = try await str("vim.o.background")
  let paper = try #require(Theme.named("paper"))
  _ = try await nv.execLua(ThemeLua.apply(paper), [])
  #expect(try await str("vim.g.colors_name") == "taudot-paper")
  #expect(try await str("vim.o.background") == "light")
  let n1 = try await hl("Normal")
  #expect(n1.bg == Int(paper.bg) && n1.fg == Int(paper.fg))
  #expect(try await hl("@function.latex").fg == Int(paper.command))
  #expect(try await hl("@markup.math.latex").fg == Int(paper.math))
  #expect(try await hl("texBeginEndName").fg == Int(paper.env))
  #expect(try await hl("DiagnosticInfo").fg == Int(paper.info))
  #expect(try await hl("LineNr").fg == Int(paper.lineNr))
  // Another theme on top, then "Your Neovim colours": habamax again.
  _ = try await nv.execLua(ThemeLua.apply(Theme.named("tomorrow-night")), [])
  #expect(try await str("vim.g.colors_name") == "taudot-tomorrow-night")
  _ = try await nv.execLua(ThemeLua.apply(nil), [])
  #expect(try await str("vim.g.colors_name") == "habamax")
  #expect(try await str("vim.o.background") == userBg)
  let n2 = try await hl("Normal")
  #expect(n2.bg == userNormal.bg && n2.fg == userNormal.fg)
}

@Test @MainActor func settingsPersistAndDriveNeovim() async throws {
  let suite = "taudot.tests.\(UUID().uuidString)"
  let d = try #require(UserDefaults(suiteName: suite))
  defer { d.removePersistentDomain(forName: suite) }
  let s = TaudotSettings(d)
  #expect(s.editorTheme == Theme.neovimID && s.appearance == "system" && s.lineSpace == -1 && s.fontSize == 0 && s.commentStyle == "tint")
  var notified: [String] = []
  let obs = NotificationCenter.default.addObserver(forName: TaudotSettings.changed, object: s, queue: nil) { n in
    if let k = n.userInfo?["key"] as? String { MainActor.assumeIsolated { notified.append(k) } }
  }
  defer { NotificationCenter.default.removeObserver(obs) }
  s.editorTheme = "solarized-dark"; s.fontSize = 16; s.lineSpace = 4; s.maxTextWidth = 80; s.commentStyle = "bar"; s.showResolved = true
  s.appearance = "dark"; s.accent = "#14b8a6"; s.pdfPage = "sepia"; s.pdfComments = false; s.floatingCards = false
  let again = TaudotSettings(d)
  #expect(again.editorTheme == "solarized-dark" && again.fontSize == 16 && again.lineSpace == 4 && again.maxTextWidth == 80)
  #expect(again.commentStyle == "bar" && again.showResolved && again.appearance == "dark" && again.accent == "#14b8a6")
  #expect(again.pdfPage == "sepia" && !again.pdfComments && !again.floatingCards)
  #expect(notified.count == 11)
  // The Neovim side: theme, guifont size, linespace; cleared, the user's come back.
  let nv = try headless()
  defer { nv.terminate() }
  _ = try await nv.execLua("vim.o.guifont = 'Menlo:h13'; vim.o.linespace = 2", [])
  _ = try await nv.execLua(again.neovimLua(), [])
  func str(_ lua: String) async throws -> String { try await nv.execLua("return tostring(" + lua + ")", []).string ?? "" }
  #expect(try await str("vim.g.colors_name") == "taudot-solarized-dark")
  #expect(try await str("vim.o.guifont").hasPrefix("Menlo:h16"))
  #expect(try await str("vim.o.linespace") == "4")
  again.editorTheme = Theme.neovimID; again.fontSize = 0; again.lineSpace = -1
  _ = try await nv.execLua(again.neovimLua(), [])
  #expect(try await str("vim.o.guifont") == "Menlo:h13")
  #expect(try await str("vim.o.linespace") == "2")
  #expect(try await str("vim.g.colors_name") != "taudot-solarized-dark")
}
