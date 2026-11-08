// NativeBridge: the NeovimBridge the shell talks to in native mode. It answers the Lua calls the app makes
// (clients/nvim/lua/taudot/gui.lua's attach/act/jump, preview.jump, app.cursor) from the native editor, and sends
// the payloads gui.lua would, built from the engine's ranges and threads.
import AppKit
import TaudotShared

@MainActor public final class NativeBridge: NeovimBridge {
  weak var editor: NativeEditor?
  private var handlers: [String: [@MainActor ([Value]) -> Void]] = [:]
  /// Every notification sent, for checks: (name, args).
  public private(set) var sent: [(String, [Value])] = []
  public var keepLog = false

  public init() {}

  public func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {
    handlers[name, default: []].append(handler)
  }

  func emit(_ name: String, _ args: [Value]) {
    if keepLog { sent.append((name, args)) }
    for h in handlers[name] ?? [] { h(args) }
  }

  public func execLua(_ code: String, _ args: [Value]) async throws -> Value {
    guard let e = editor else { return .null }
    if code.contains("taudot.gui').attach") {
      e.reviewChanged()
      return .bool(true)
    }
    if code.contains("taudot.gui').act") {
      let kind = args.first?.str ?? ""
      let id = args.count > 1 ? args[1].str : nil
      let a = args.count > 2 ? args[2] : .map([])
      return await e.act(kind, id: id, args: a)
    }
    if code.contains("taudot.gui').jump") {
      let dir = args.first?.num ?? 1
      let n = args.count > 1 ? args[1].num ?? 1 : 1
      _ = await e.act("jump", id: nil, args: .map([(.string("dir"), .int(Int64(dir))), (.string("count"), .int(Int64(n)))]))
      return .null
    }
    if code.contains("taudot.preview').jump") {
      let path = args.first?.str ?? ""
      let line = args.count > 1 ? args[1].num ?? 1 : 1
      let col = args.count > 2 ? args[2].num : nil
      await e.jump(path: path, line: line, col: col)
      return .null
    }
    if code.contains("taudot.app').cursor(true)") {
      e.forwardSearch()
      return .null
    }
    if code.contains("vim_did_enter") { return .bool(true) }
    return .null
  }

  public func command(_ cmd: String) async throws {
    if cmd.hasPrefix("edit ") { try await editor?.open(path: String(cmd.dropFirst(5))) }
  }
}

extension Value {
  var str: String? { if case let .string(s) = self { return s }; return nil }
  var num: Int? {
    switch self {
    case let .int(i): return Int(i)
    case let .float(f): return Int(f)
    default: return nil
    }
  }
  subscript(_ k: String) -> Value {
    if case let .map(pairs) = self { for (a, b) in pairs where a.str == k { return b } }
    return .null
  }
  static func obj(_ pairs: [(String, Value)]) -> Value { .map(pairs.map { (.string($0.0), $0.1) }) }
  static func from(_ any: Any?) -> Value {
    switch any {
    case nil, is NSNull: return .null
    case let b as Bool where type(of: any!) == type(of: NSNumber(value: true)) || any is Bool: return .bool(b)
    case let i as Int: return .int(Int64(i))
    case let d as Double: return .float(d)
    case let s as String: return .string(s)
    case let a as [Any]: return .array(a.map { from($0) })
    case let m as [String: Any]: return .map(m.map { (.string($0.key), from($0.value)) })
    default: return .null
    }
  }
}

extension NativeEditor {
  // MARK: review payloads

  func user(_ u: Any?) -> Value {
    guard let u = u as? [String: Any] else { return .obj([("user_id", .null), ("name", .string("?")), ("initials", .string("?"))]) }
    let name = u["name"] as? String ?? "?"
    var ini = u["initials"] as? String ?? ""
    if ini.isEmpty { ini = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased() }
    return .obj([("user_id", .from(u["user_id"])), ("name", .string(name)), ("initials", .string(ini))])
  }

  /// The review items of the shown doc, as gui.lua's `items`.
  func items() -> [Value] {
    guard let d = doc else { return [] }
    let starts = Utf.lineStarts(d.text)
    let mine = me["user_id"] as? String
    return d.ranges.map { r in
      let (l, c) = Utf.lineCol(starts, r.start), (el, ec) = Utf.lineCol(starts, r.end)
      var f: [(String, Value)] = [
        ("id", .string(r.id)), ("kind", .string(r.kind)), ("quote", .string(r.text)), ("ts", r.ts.map { .float($0) } ?? .null),
        ("line", .int(Int64(l))), ("col", .int(Int64(c))), ("end_line", .int(Int64(el))), ("end_col", .int(Int64(ec))),
      ]
      var resolved = false
      var author: Any? = r.author
      if r.kind == "comment" {
        let t = r.threadID.flatMap { threads[$0] }
        f.append(("thread_id", r.threadID.map { .string($0) } ?? .null))
        resolved = (t?["resolved"] as? Bool) ?? r.resolved
        let msgs = t?["messages"] as? [[String: Any]] ?? []
        if let first = msgs.first?["user"] { author = first }
        f.append(("messages", .array(msgs.map { m in
          let u = m["user"] as? [String: Any]
          return .obj([
            ("id", .from(m["id"])), ("text", .string(m["text"] as? String ?? "")), ("ts", .from(m["ts"])), ("user", user(u)),
            ("mine", .bool(u?["user_id"] as? String == mine && mine != nil)),
          ])
        })))
        if let rb = t?["resolved_by"] as? [String: Any] { f.append(("resolved_by", user(rb))) }
        if let ts = msgs.first?["ts"] { f.append(("ts", .from(ts))) }
      } else {
        f.append(("messages", .array([])))
      }
      let au = user(author)
      f.append(("author", au))
      f.append(("resolved", .bool(resolved)))
      f.append(("color", .string(NativeEditor.hex(NativeEditor.color(au["user_id"].str ?? au["name"].str ?? "?")))))
      return .obj(f)
    }
  }

  func payload(reason: String) -> Value {
    let d = doc
    var meUser: Value = .null
    if !me.isEmpty {
      var u = user(me)
      if case var .map(p) = u {
        p.append((.string("color"), .string(NativeEditor.hex(NativeEditor.color(me["user_id"] as? String ?? "?")))))
        u = .map(p)
      }
      meUser = u
    }
    return .obj([
      ("buf", .int(Int64(view.buffer))), ("synced", .bool(d != nil)), ("path", d.map { .string($0.path) } ?? .null),
      ("file", current.map { .string(folder.appendingPathComponent($0).path) } ?? .null),
      ("doc_id", d.map { .string($0.docID) } ?? .null), ("me", .from(me["user_id"])), ("me_user", meUser),
      ("supported", .bool(threadsSupported)), ("track", .bool(track)), ("items", .array(items())), ("reason", .string(reason)),
    ])
  }

  /// Ranges or threads changed: tints in the text, the margin's state.
  func reviewChanged() {
    guard let d = doc else { return }
    var tints: [(NSRange, NSColor, CGFloat, Bool)] = []
    for r in d.ranges where r.end > r.start {
      let t = r.threadID.flatMap { threads[$0] }
      let resolved = (t?["resolved"] as? Bool) ?? r.resolved
      if r.kind == "comment" && resolved && !showResolved { continue }
      let key = (t?["messages"] as? [[String: Any]])?.first.flatMap { ($0["user"] as? [String: Any])?["user_id"] as? String }
        ?? r.author["user_id"] ?? r.author["name"] ?? "?"
      let loc = Utf.utf16(d.text, r.start)
      tints.append((NSRange(location: loc, length: Utf.utf16(d.text, r.end) - loc), NativeEditor.color(key), r.kind == "comment" ? 0.22 : 0.3, r.kind == "comment"))
    }
    view.setTints(tints)
    updateLineNotes()
    bridge.emit("taudot_review", [payload(reason: "native")])
    pushCursor()
  }

  /// The end-of-line notes, as gui.lua draws them: while the margin is hidden and comments aren't hidden in the text.
  func updateLineNotes() {
    let notes = marginShown || inlineHidden ? [] : doc.map { d in LineNote.make(text: d.text, ranges: d.ranges, threads: threads, color: NativeEditor.color) } ?? []
    guard notes != lineNotes else { return }
    lineNotes = notes
    view.lineNotes = notes
    onLineNotes?(notes)
  }

  /// taudot_review_cursor: where the caret is, the items under it, the selection.
  func pushCursor() {
    guard let d = doc else { return }
    let sel = view.textView.selectedRange()
    let pos = Utf.utf8(d.text, sel.location)
    let (l, c) = view.lineCol(sel.location)
    let here = d.ranges.filter { $0.start <= pos && pos <= $0.end && $0.end > $0.start }.map { Value.string($0.id) }
    var visual: Value = .null
    if sel.length > 0 {
      let (el, ec) = view.lineCol(NSMaxRange(sel))
      visual = .obj([("line", .int(Int64(l))), ("col", .int(Int64(c))), ("end_line", .int(Int64(el))), ("end_col", .int(Int64(ec)))])
    }
    bridge.emit("taudot_review_cursor", [.obj([
      ("buf", .int(Int64(view.buffer))), ("line", .int(Int64(l))), ("col", .int(Int64(c))), ("here", .array(here)), ("visual", visual),
    ])])
  }

  // MARK: actions (gui.lua's act)

  private func ok(_ more: [(String, Value)] = []) -> Value { .obj([("ok", .bool(true))] + more) }
  private func fail(_ e: String) -> Value { .obj([("ok", .bool(false)), ("error", .string(e))]) }

  /// Run an engine call in the background; `taudot_review_done {req, ok, error}` when it returns.
  private func request(_ method: String, _ params: [String: Any], req: Value) -> Value {
    guard let c = conn else { return fail("not connected") }
    Task { @MainActor in
      var out: [(String, Value)] = [("req", req)]
      do {
        _ = try await c.call(method, params)
        out.append(("ok", .bool(true)))
      } catch {
        out.append(("ok", .bool(false)))
        out.append(("error", .string("\(error)")))
      }
      bridge.emit("taudot_review_done", [.obj(out)])
    }
    return ok()
  }

  func act(_ kind: String, id: String?, args: Value) async -> Value {
    let req = args["req"]
    guard let d = doc else { return fail("no doc open") }
    let starts = Utf.lineStarts(d.text)
    func byte(_ l: Value, _ c: Value) -> Int? {
      guard let l = l.num, let c = c.num, l >= 0, l < starts.count else { return nil }
      return min(d.text.count, starts[l] + c)
    }
    switch kind {
    case "comment":
      guard let text = args["text"].str, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fail("empty comment") }
      // A draft started in another file (A3): never placed at the same line/col in this one.
      if let b = args["buf"].num, b != view.buffer { return fail("this comment's file isn't the one open") }
      guard let a = byte(args["line"], args["col"]), let b = byte(args["end_line"], args["end_col"]), b > a else {
        return fail("select some text to comment on")
      }
      if d.unconfirmed > 0 { d.flush() }
      return request("comment.add", ["doc_id": d.docID, "start": a, "end": b, "text": text], req: req)
    case "start_comment":
      let sel = view.textView.selectedRange()
      guard sel.length > 0 else { return fail("select some text to comment on") }
      let (l, c) = view.lineCol(sel.location), (el, ec) = view.lineCol(NSMaxRange(sel))
      let quote = (view.textView.string as NSString).substring(with: sel)
      return ok([("line", .int(Int64(l))), ("col", .int(Int64(c))), ("end_line", .int(Int64(el))), ("end_col", .int(Int64(ec))), ("quote", .string(quote))])
    case "margin_shown":
      marginShown = args["shown"] == .bool(true)
      return ok([("inline", .bool(!marginShown && !inlineHidden))])
    case "show_resolved":
      showResolved = args["on"] == .bool(true)
      reviewChanged()
      return ok()
    case "open":
      guard let p = args["path"].str else { return fail("no path") }
      do { try await open(path: p); return ok() } catch { return fail("\(error)") }
    case "kinds":
      kinds = (args["comments"] != .bool(false), args["suggestions"] != .bool(false))
      return ok()
    case "jump":
      // ]r [r ⌥⌘↓ ⌥⌘↑ and the review bar: in text order (the ranges come in any order), following the filter, round
      // at the ends, `count` at a time.
      let dir = (args["dir"].num ?? 1) < 0 ? -1 : 1
      let count = max(1, args["count"].num ?? 1)
      let pos = Utf.utf8(d.text, view.caret)
      let list = d.ranges.filter { r in
        let isComment = r.kind == "comment"
        guard isComment ? kinds.comments : kinds.suggestions else { return false }
        return !isComment || showResolved || !((r.threadID.flatMap { threads[$0] }?["resolved"] as? Bool) ?? r.resolved)
      }.sorted { ($0.start, $0.kind == "comment" ? 0 : 1) < ($1.start, $1.kind == "comment" ? 0 : 1) }
      var target: DocRange?
      if !list.isEmpty {
        // From the item landed on last (two can start at one place), else from the caret.
        var i: Int
        if let last = lastJumped, let k = list.firstIndex(where: { $0.id == last && $0.start == pos }) {
          i = k
        } else if dir > 0 {
          i = (list.lastIndex { $0.start <= pos } ?? -1)
          if let k = list.firstIndex(where: { $0.start > pos }), list.indices.contains(i), list[i].start == pos { i = k - 1 }
        } else {
          i = list.firstIndex { $0.start >= pos } ?? list.count
        }
        i = ((i + dir * count) % list.count + list.count) % list.count
        target = list[i]
      }
      if let t = target {
        let (l, c) = Utf.lineCol(starts, t.start)
        view.jump(line: l + 1, col: c)
        lastJumped = t.id
        // The panel opens its card, as a click would.
        bridge.emit("taudot_review_landed", [.obj([("id", .string(t.id))])])
      }
      bridge.emit("taudot_review_done", [.obj([("req", req), ("ok", .bool(target != nil))] + (target == nil ? [("error", .string("nothing to go to"))] : []))])
      return ok()
    case "reveal", "layout":
      // reveal (the panel's stacked list): the item's text, centred; layout: nothing to keep here.
      guard kind == "reveal", let id, let r = d.ranges.first(where: { $0.id == id }) else { return ok() }
      let (l, c) = Utf.lineCol(starts, r.start)
      view.jump(line: l + 1, col: c)
      lastJumped = r.id
      bridge.emit("taudot_review_landed", [.obj([("id", .string(r.id))])])
      bridge.emit("taudot_review_done", [.obj([("req", req), ("ok", .bool(true))])])
      return ok()
    case "verb":
      // ga gx gC: the change (or comment) at the caret, then the next one.
      let v = args["verb"].str ?? ""
      let pos = Utf.utf8(d.text, view.caret)
      let here = d.ranges.filter { $0.start <= pos && pos <= max($0.end, $0.start) }.first { v == "resolve" ? $0.kind == "comment" : $0.kind != "comment" }
      guard let r = here else { return fail(v == "resolve" ? "no comment here" : "no tracked change here") }
      let res: Value
      if v == "resolve" {
        guard let tid = r.threadID, let pid = projectID else { return fail("no thread") }
        res = request("thread.resolve", ["project_id": pid, "thread_id": tid, "doc_id": d.docID], req: req)
      } else {
        res = request("change.\(v)", ["doc_id": d.docID, "ids": [r.id]], req: req)
      }
      _ = await act("jump", id: nil, args: .map([(.string("dir"), .int(1))]))
      return res
    default: break
    }
    guard let id, let r = d.ranges.first(where: { $0.id == id }) else { return fail("no comment or change \(id ?? "")") }
    let isComment = r.kind == "comment"
    switch kind {
    case "goto", "select":
      let (l, c) = Utf.lineCol(starts, r.start)
      view.jump(line: l + 1, col: c)
      return ok()
    case "accept", "reject":
      if isComment { return fail("\(kind) is for tracked changes") }
      return request("change.\(kind)", ["doc_id": d.docID, "ids": [r.id]], req: req)
    default: break
    }
    guard isComment, let tid = r.threadID, let pid = projectID else { return fail("\(kind) is for comments") }
    switch kind {
    case "reply":
      guard let t = args["text"].str, !t.isEmpty else { return fail("empty reply") }
      return request("thread.reply", ["project_id": pid, "thread_id": tid, "text": t], req: req)
    case "resolve", "reopen", "delete":
      return request("thread.\(kind)", ["project_id": pid, "thread_id": tid, "doc_id": d.docID], req: req)
    case "edit_message":
      guard let t = args["text"].str, let m = args["message_id"].str else { return fail("edit_message needs message_id and text") }
      return request("message.edit", ["project_id": pid, "thread_id": tid, "message_id": m, "text": t], req: req)
    case "delete_message":
      guard let m = args["message_id"].str else { return fail("delete_message needs message_id") }
      return request("message.delete", ["project_id": pid, "thread_id": tid, "message_id": m], req: req)
    default:
      return fail("unknown action \(kind)")
    }
  }
}
