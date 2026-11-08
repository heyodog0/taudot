// The find bar on Neovim: every search is Neovim's own (clients/nvim/lua/taudot/find.lua): the bar's query becomes a
// Vim pattern in the search register, Neovim draws the matches ('hlsearch', CurSearch for the current one) and moves
// the cursor, searchcount() counts, and replace runs :s. So n / N, *, :noh and the `/` history agree with the bar.
import AppKit
import TaudotShared

@MainActor public final class NeovimFindTarget: FindTarget {
  let bridge: NeovimBridge
  public let findResponder: NSView
  public var onFindCount: ((FindCount) -> Void)?
  public var onFindClose: (() -> Void)?
  /// `/` or `?` pressed in Neovim (normal or visual mode): open the bar (backward for `?`).
  public var onOpenRequest: ((_ backward: Bool) -> Void)?
  /// Calls made, for checks.
  public private(set) var calls = 0
  /// The user's 'ignorecase' and 'smartcase' (from open): plain searches then go to Neovim as plain patterns.
  var ignorecase = false, smartcase = false
  public func pattern(_ q: FindQuery) -> String { q.vimPattern(ignorecase: ignorecase, smartcase: smartcase) }

  public init(bridge: NeovimBridge, responder: NSView) {
    self.bridge = bridge
    findResponder = responder
    bridge.notify("taudot_find_open") { [weak self] a in
      self?.onOpenRequest?(a.first?["dir"].str == "?")
    }
    bridge.notify("taudot_find_count") { [weak self] a in
      guard let self, let c = a.first else { return }
      self.onFindCount?(Self.count(c))
    }
    bridge.notify("taudot_find_close") { [weak self] _ in self?.onFindClose?() }
  }

  /// Map / and ? to the bar (unless the user mapped them), notifications to this channel.
  public func attach(channel: Int) async {
    _ = try? await bridge.execLua("return require('taudot.find').attach(...)", [.int(Int64(channel))])
  }

  static func count(_ v: Value) -> FindCount {
    let err = v["error"].str
    return FindCount(current: v["current"].num ?? 0, total: v["total"].num ?? 0, incomplete: v["incomplete"] == .bool(true), error: err)
  }

  private func call(_ fn: String, _ args: [Value]) async -> Value {
    calls += 1
    return (try? await bridge.execLua("return require('taudot.find')." + fn + "(...)", args)) ?? .null
  }

  public func findBegin(backward: Bool) async -> [FindQuery] {
    let r = await call("open", [.string(backward ? "?" : "/")])
    ignorecase = r["ic"] == .bool(true)
    smartcase = r["scs"] == .bool(true)
    guard case let .array(h) = r["history"] else { return [] }
    var seen = Set<String>()
    return h.compactMap { $0.str.flatMap { FindQuery.fromVim($0, ignorecase: ignorecase, smartcase: smartcase) } }.filter { seen.insert($0.text + "\u{0}\($0.matchCase)\($0.wholeWord)\($0.regex)").inserted }
  }

  public func findSearch(_ q: FindQuery) async -> FindCount {
    // An empty field: no pattern (Neovim goes back to where the bar opened).
    Self.count(await call("search", [.string(q.text.isEmpty ? "" : pattern(q))]))
  }

  public func findStep(forward: Bool) async -> FindCount {
    Self.count(await call("step", [.bool(forward)]))
  }

  public func findReplace(_ q: FindQuery, with template: String, all: Bool) async -> (FindCount, Int) {
    let r = await call("replace", [.string(pattern(q)), .string(q.vimReplacement(template)), .bool(all)])
    return (Self.count(r), r["replaced"].num ?? 0)
  }

  public func findPassive(_ on: Bool) async {
    _ = await call("passive", [.bool(on)])
  }

  public func findEnd(keep: Bool) async {
    _ = await call("close", [.bool(keep)])
  }
}
