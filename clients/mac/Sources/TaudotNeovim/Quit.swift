// Quitting: Cmd-Q, Cmd-W and the close button end Neovim without ever hanging. taudot buffers sync live, so only
// other modified buffers are offered for saving; then `qall!`, and if Neovim isn't gone within a second it is killed.
import Foundation
import TaudotShared

public enum UnsavedChoice: Sendable { case save, discard, cancel }

extension Neovim {
  public var isRunning: Bool { process?.process.isRunning ?? false }

  /// Modified buffers that aren't taudot's (those are synced by the engine): (buffer, name). nil if Neovim didn't
  /// answer within `timeout` (blocked in a prompt, or gone).
  public func unsavedBuffers(timeout: Double = 0.7) async -> [(buf: Int, name: String)]? {
    guard let v = await deadline(timeout, { try await self.execLua(unsavedLua, []) }), let a = v.array else { return nil }
    var out: [(Int, String)] = []
    var i = 0
    while i + 1 < a.count { out.append((a[i].int ?? 0, a[i + 1].string ?? "")); i += 2 }
    return out
  }

  /// End Neovim. `confirm` is asked about modified non-taudot buffers (`retry`: again, for those that couldn't be
  /// saved). Returns false if the user cancelled; otherwise Neovim has exited (or was killed) when this returns.
  public func quit(confirm: (_ bufs: [(buf: Int, name: String)], _ retry: Bool) async -> UnsavedChoice) async -> Bool {
    guard await resolveUnsaved(confirm: confirm) else { return false }
    await stop()
    return true
  }

  /// The save question for modified non-taudot buffers, answered (saves done), Neovim left running: ⌘Q asks every
  /// window this first and stops none until all have agreed (A4). False if the user cancelled.
  public func resolveUnsaved(confirm: (_ bufs: [(buf: Int, name: String)], _ retry: Bool) async -> UnsavedChoice) async -> Bool {
    // Out of insert mode and past any prompt (hit-enter, confirm): those block API requests.
    input("<C-\\><C-n><Esc>")
    var bufs = await unsavedBuffers() ?? []
    var retry = false
    while !bufs.isEmpty {
      switch await confirm(bufs, retry) {
      case .cancel: return false
      case .discard: return true
      case .save:
        _ = await deadline(3) { try await self.execLua(saveLua, [.array(bufs.map { .int(Int64($0.buf)) })]) }
        bufs = await unsavedBuffers() ?? []
        retry = true
      }
    }
    return true
  }

  /// `qall!`, then SIGTERM and SIGKILL if Neovim is still there; it has exited (or was killed) when this returns.
  public func stop() async {
    rpc.request("nvim_command", [.string("qall!")]) { _ in }
    for _ in 0..<50 where isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    // Still there: SIGTERM, and SIGKILL if Lua is stuck in a loop (it only handles signals between events).
    terminate()
    for _ in 0..<10 where isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    if isRunning, let pid = process?.process.processIdentifier { kill(pid, SIGKILL) }
    for _ in 0..<10 where isRunning { try? await Task.sleep(for: .milliseconds(20)) }
  }
}

final class Once: @unchecked Sendable { var done = false }

/// The value of `op`, or nil if it fails or takes longer than `seconds` (the request is then left unanswered).
@MainActor func deadline<T: Sendable>(_ seconds: Double, _ op: @escaping @MainActor () async throws -> T) async -> T? {
  let once = Once()
  return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
    Task { @MainActor in
      let v = try? await op()
      if !once.done { once.done = true; c.resume(returning: v) }
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))
      if !once.done { once.done = true; c.resume(returning: nil) }
    }
  }
}

let unsavedLua = """
local ok, B = pcall(require, 'taudot.buffer')
local out = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and vim.bo[b].buftype == ''
      and not (ok and type(B) == 'table' and B.by_buf and B.by_buf[b]) then
    out[#out + 1] = b; out[#out + 1] = vim.api.nvim_buf_get_name(b)
  end
end
return out
"""

let saveLua = """
for _, b in ipairs(...) do
  if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) ~= '' then
    pcall(vim.api.nvim_buf_call, b, function() vim.cmd('silent keepalt write') end)
  end
end
"""
