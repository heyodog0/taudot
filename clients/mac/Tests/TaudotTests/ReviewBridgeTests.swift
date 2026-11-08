// End to end: a headless `nvim --embed` running the plugin against the mock engine (with its bot), the margin fed by
// gui.lua through ReviewController. Needs nvim and deno on PATH.
import AppKit
import Foundation
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

private func onPath(_ tool: String) -> Bool {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = ["which", tool]
  p.standardOutput = FileHandle.nullDevice
  p.standardError = FileHandle.nullDevice
  try? p.run()
  p.waitUntilExit()
  return p.terminationStatus == 0
}

@MainActor private func until(_ what: String, _ seconds: Double = 8, _ f: () -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if f() { return true }
    try? await Task.sleep(for: .milliseconds(30))
  }
  Issue.record("timed out: \(what)")
  return false
}

@MainActor @Test(.enabled(if: onPath("nvim") && onPath("deno")), .timeLimit(.minutes(1)))
func bridgeEndToEnd() async throws {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-e2e-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }
  try FileManager.default.copyItem(at: repo.appendingPathComponent("clients/mock-engine/example/main.tex"), to: tmp.appendingPathComponent("main.tex"))
  let sock = tmp.appendingPathComponent("e.sock").path
  let mock = Process()
  mock.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  mock.arguments = ["deno", "run", "-A", repo.appendingPathComponent("clients/mock-engine/main.ts").path, "--folder", tmp.path,
                    "--socket", sock, "--bot", "--bot-interval", "300", "--bot-char", "10", "--bot-rounds", "3"]
  mock.standardOutput = FileHandle.nullDevice
  mock.standardError = FileHandle.nullDevice
  try mock.run()
  defer { mock.terminate() }
  #expect(await until("mock socket", 10) { FileManager.default.fileExists(atPath: sock) })

  let nvim = try EmbeddedNeovim(env: ["TAUDOT_SOCKET": sock], cwd: tmp)
  defer { nvim.stop() }
  let setup = """
  local rtp, folder = ...
  vim.opt.rtp:prepend(rtp)
  vim.cmd('runtime plugin/taudot.lua')
  vim.o.termguicolors = true
  require('taudot').setup({})
  vim.cmd.edit(folder .. '/main.tex')
  require('taudot').open(folder)
  return true
  """
  #expect(try await nvim.execLua(setup, [.string(repo.appendingPathComponent("clients/nvim").path), .string(tmp.path)]) == .bool(true))

  let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 40)
  let margin = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
  margin.animationDuration = 0
  margin.geometry = g
  margin.confirm = { _, done in done(true) }
  let c = ReviewController(nvim: nvim, margin: margin)
  var results: [(ReviewAction, String?)] = []
  c.onResult = { results.append(($0, $1)) }
  try await c.attach(channel: try await nvim.fetchChannel())

  // The bot's comment and tracked insertion arrive as cards. It stops after them (--bot-rounds 3: a phrase, the
  // comment, the insertion), so from then on nobody but this test edits the text and every check is exact.
  func comment() -> ReviewItem? { margin.state.items.first { $0.kind == .comment && !$0.messages.isEmpty && $0.author.name == "Ada Lovelace" } }
  func insert() -> ReviewItem? { margin.state.items.first { $0.kind == .insert } }
  guard await until("bot comment and change", 15, { comment() != nil && insert() != nil }) else { return }
  let cm = comment()!, ins = insert()!
  #expect(margin.state.path == "main.tex")
  #expect(margin.shown.contains { $0.id == cm.id } && margin.shown.contains { $0.id == ins.id })

  // Cards line up with their lines: the first one exactly, the rest at or below theirs.
  let frames = margin.targetFrames()
  let first = margin.shown[0]
  #expect(frames[first.id]!.minY == CGFloat(first.range.line) * 20)
  for it in margin.shown { #expect(frames[it.id]!.minY >= CGFloat(it.range.line) * 20) }

  // ...and follow scrolling the same call.
  let before = margin.displayedFrames()[first.id]!.minY
  g.top = -33.5
  #expect(margin.displayedFrames()[first.id]!.minY == before - 33.5)
  g.top = 0

  // The cursor entering the comment selects its card; gui.lua highlights the text.
  _ = try await nvim.execLua("vim.api.nvim_win_set_cursor(0, {...})", [.int(Int64(cm.range.line + 1)), .int(Int64(cm.range.col))])
  #expect(await until("cursor selects the card") { margin.selectedID == cm.id })
  // (select goes to Neovim asynchronously: wait for its highlight)
  var marks = Value.null
  for _ in 0..<100 {
    marks = try await nvim.execLua("return #vim.api.nvim_buf_get_extmarks(0, require('taudot.gui').sel_ns, 0, -1, {})", [])
    if marks == .int(1) { break }
    try await Task.sleep(for: .milliseconds(30))
  }
  #expect(marks == .int(1))

  // Reply.
  c.send(.reply(cm.id, text: "From Swift"))
  #expect(await until("reply arrives") { margin.state.items.first { $0.id == cm.id }?.messages.last?.text == "From Swift" })
  #expect(margin.state.items.first { $0.id == cm.id }?.messages.last?.mine == true)

  // Resolve: hidden behind the toggle; reopen brings it back.
  c.send(.resolve(cm.id))
  #expect(await until("resolved") { margin.state.items.first { $0.id == cm.id }?.resolved == true })
  #expect(!margin.shown.contains { $0.id == cm.id })
  c.send(.reopen(cm.id))
  #expect(await until("reopened") { margin.shown.contains { $0.id == cm.id } })

  // Accept the bot's insertion: its card goes.
  c.send(.accept(ins.id))
  #expect(await until("accepted") { !margin.state.items.contains { $0.id == ins.id } })

  // A new comment on a range.
  let line = try await nvim.execLua("for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do if l:match('^The ') then return i - 1 end end", [])
  let l = line.int ?? 0
  c.send(.comment(ReviewRange(line: l, col: 0, endLine: l, endCol: 3), text: "Swift comment"))
  #expect(await until("new comment") { margin.state.items.contains { $0.messages.first?.text == "Swift comment" && $0.range.line == l } })

  // A new comment on a multi-line selection (one line wrapped), started the way the + button does: the draft quotes
  // the selected text and the comment anchors on that range. Once in visual mode, once just after leaving it.
  let pick = """
  vim.o.columns = 40
  local ls = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i = #ls - 1, 1, -1 do
    if #ls[i] > 45 and #ls[i + 1] > 10 and not ls[i]:match('^\\\\') then return i - 1 end
  end
  """
  let row = Int(try await nvim.execLua(pick, []).int ?? 0)
  let selectLua = """
  local row, leave = ...
  vim.cmd('normal! \\27')
  vim.api.nvim_win_set_cursor(0, { row + 1, 4 })
  vim.api.nvim_feedkeys('vj', 'nx', false)
  vim.api.nvim_win_set_cursor(0, { row + 2, 5 })
  if leave then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    vim.api.nvim_win_set_cursor(0, { row + 3, 0 })
  end
  local a = vim.api.nvim_buf_get_lines(0, row, row + 2, false)
  return a[1]:sub(5) .. '\\n' .. a[2]:sub(1, 6)
  """
  for (n, leave) in [false, true].enumerated() {
    let want = try await nvim.execLua(selectLua, [.int(Int64(row)), .bool(leave)]).string ?? ""
    #expect(want.contains("\n"))
    margin.newComment()
    guard await until("draft opens (\(leave ? "just left" : "visual"))", 8, { margin.draftItem != nil }) else {
      Issue.record("notice: \(margin.noticeText ?? "-"), selected \(margin.selectedID ?? "-")")
      return
    }
    let d = margin.draftItem!
    #expect(d.range == ReviewRange(line: row, col: 4, endLine: row + 1, endCol: 6))
    #expect(d.quote == want, "draft quote \(d.quote.debugDescription) want \(want.debugDescription)")
    let mode = try await nvim.execLua("return vim.api.nvim_get_mode().mode", [])
    #expect(mode == .string("n"))
    let card = margin.card("draft")!
    card.reply!.string = "Two lines \(n)"
    card.reply!.onSend?()
    #expect(await until("multi-line comment \(n) arrives", 15) {
      margin.state.items.contains { $0.messages.first?.text == "Two lines \(n)" }
    })
    if let got = margin.state.items.first(where: { $0.messages.first?.text == "Two lines \(n)" }) {
      #expect(got.range == d.range, "range \(got.range) want \(d.range)")
      #expect(got.quote == want, "quote \(got.quote.debugDescription) want \(want.debugDescription)")
    } else {
      Issue.record("no comment \(n); results \(results.map { "\($0.0.kind) \($0.1 ?? "ok")" }) card error \(margin.card("draft")?.error ?? "-")")
    }
    // The draft goes once both the comment and the engine's answer (taudot_review_done) are in, in either order.
    #expect(await until("the comment's card replaces the draft \(n)", 15) { margin.draftItem == nil })
  }
  // No selection: a notice, no card.
  _ = try await nvim.execLua("require('taudot.gui').left_visual = nil; vim.api.nvim_win_set_cursor(0, {1, 0})", [])
  margin.newComment()
  #expect(await until("notice") { margin.noticeText == "Select text to comment" })
  #expect(margin.draftItem == nil)

  // An action gui.lua refuses comes back as an error on the card.
  c.send(.accept(cm.id))
  #expect(await until("refusal reported") { results.contains { $0.0 == .accept(cm.id) && $0.1 != nil } })

  // Every engine action reported success.
  for (a, e) in results where a != .accept(cm.id) { #expect(e == nil, "\(a): \(e ?? "")") }
}
