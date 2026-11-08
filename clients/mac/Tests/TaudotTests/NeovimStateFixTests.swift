// statefix A16: trackpad scroll replies from a gesture that was already settled must not be paid into the next one.
import AppKit
import Testing
@testable import TaudotNeovim
@testable import TaudotShared

@Test @MainActor func a16StaleScrollRepliesStayWithTheirGesture() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 700, height: 500))
  try await v.attach()
  _ = try await nv.execLua("""
    local l = {}
    for i = 1, 600 do l[#l + 1] = 'line ' .. i end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, l)
    vim.cmd('normal! gg')
    """, [])
  var t = 1000.0
  func frames(_ n: Int) async {
    for _ in 0..<n { t += 1.0 / 120; v.advance(now: t); try? await Task.sleep(for: .milliseconds(3)) }
  }
  await frames(30)
  let grid = v.currentGrid
  // Gesture A: Neovim held busy until the test lets go (mid-B), so A's rows are still on their way when the 0.3 s
  // wait gives up on them, and land while B is under way however loaded the machine is (a fixed sleep either ended
  // before A settled or outlasted B, and then no reply of A's ever met B). At most 20 s, should the test die.
  let release = FileManager.default.temporaryDirectory.appendingPathComponent("a16-\(UUID().uuidString)").path
  defer { try? FileManager.default.removeItem(atPath: release) }
  nv.send("nvim_exec_lua", [.string("""
    local p = ...
    local t = vim.uv.hrtime()
    while not vim.uv.fs_stat(p) and vim.uv.hrtime() - t < 2e10 do vim.uv.sleep(5) end
    """), .array([.string(release)])])
  if let e = trackpadEvent(v, dy: 40, phase: 1, momentum: 0) { v.scrollWheel(with: e) }
  for _ in 0..<4 { await frames(1); if let e = trackpadEvent(v, dy: 40, phase: 2, momentum: 0) { v.scrollWheel(with: e) } }
  if let e = trackpadEvent(v, dy: 0, phase: 4, momentum: 0) { v.scrollWheel(with: e) }
  for _ in 0..<150 where v.fingerGrid != 0 { await frames(1); try? await Task.sleep(for: .milliseconds(10)) }
  #expect(v.fingerGrid == 0, "A settled while its replies were outstanding")
  #expect(v.fingerReplies > 0, "A's replies still on their way")
  // Gesture B, down (A pushed up at the top), while A's replies land.
  let snapsBefore = v.debugSnapBacks
  if let e = trackpadEvent(v, dy: -20, phase: 1, momentum: 0) { v.scrollWheel(with: e) }
  let requestedAtStart = v.fingerRequested
  for i in 0..<40 {
    await frames(1)
    if i == 10 {
      #expect(v.fingerGrid == grid && v.fingerReplies > 0, "B under way, A's replies still out")
      FileManager.default.createFile(atPath: release, contents: nil)
    }
    if let e = trackpadEvent(v, dy: -20, phase: 2, momentum: 0) { v.scrollWheel(with: e) }
    try? await Task.sleep(for: .milliseconds(10))
  }
  if let e = trackpadEvent(v, dy: 0, phase: 4, momentum: 0) { v.scrollWheel(with: e) }
  _ = requestedAtStart
  #expect(v.debugSnapBacks == snapsBefore, "no snap-back paid into B from A's replies at the top")
  // Wait until really quiet: settled, no reply out, and Neovim's topline already drawn, for 10 frames running.
  // Neovim answers the scroll requests before the flush that carries their redraw, so "no reply out" alone can
  // come while the last scroll (B's rows, landing after B gave up on them) is still to arrive and animate.
  var quiet = 0
  for _ in 0..<1000 where quiet < 10 {
    await frames(1)
    let top = (try? await nv.execLua("return vim.fn.line('w0') - 1", []))?.int
    quiet = v.scrollSettled(grid: grid) && v.fingerReplies == 0 && top == v.ui.windows[grid]?.topline ? quiet + 1 : 0
  }
  #expect(quiet == 10, "the view came to rest where Neovim is")
  await frames(10)
  #expect(v.scrollSettled(grid: grid))
  #expect(v.drawnRows(grid: grid) == v.gridRows(grid: grid), "after both gestures the drawn rows are Neovim's")
  #expect(v.debugBlankRows == 0, "no blank rows")
}
