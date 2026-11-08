// One engine doc as the native editor holds it: its text (UTF-8 bytes), the engine's `seq`, our edit in flight and
// the ones typed since, and its review ranges, all moved with every change. The same protocol as the Neovim client
// (clients/nvim/lua/taudot/buffer.lua, docs/api.md "doc.edit, seq and transforms"): one doc.edit in flight, later
// edits composed into one pending op, each incoming doc.changed transformed past both (theirs first on ties).
import Foundation
import TaudotPDF

/// A comment or tracked change, in local byte offsets.
public struct DocRange: Equatable {
  public var id: String
  public var kind: String
  public var start: Int
  public var end: Int
  public var text: String
  public var author: [String: String]
  public var ts: Double?
  public var threadID: String?
  public var resolved: Bool
}

@MainActor public final class NativeDoc {
  public private(set) var docID: String
  public let path: String
  public private(set) var text: [UInt8]
  public private(set) var seq: Int
  public private(set) var inflight: Op?
  public private(set) var pending: Op?
  public private(set) var ranges: [DocRange] = []
  /// The engine's text at `seq`, without our unconfirmed edits: what a rebase diffs against.
  public private(set) var base: [UInt8]
  /// The text before each edit the engine confirmed but Overleaf hasn't yet (doc.state unconfirmed 0 clears them): a
  /// killed engine may have lost those, and a rebase then finds the server without them.
  private(set) var unflushed: [[UInt8]] = []
  /// An error that leaves edits unsent (doc.edit refused, a failed merge), until the next ack.
  public private(set) var error: String?
  public private(set) var rebasing = false
  /// Rebases done, for checks.
  public private(set) var rebases = 0
  var onError: ((String) -> Void)?
  public var editable = true
  weak var conn: JSONRPCConnection?
  /// Remote edits, already transformed, in local byte offsets: the view applies them.
  var onRemote: ((_ edits: [Edit], _ old: [UInt8]) -> Void)?
  var onRanges: (() -> Void)?
  var onState: (() -> Void)?
  /// The text no longer matches the engine: reopen.
  var onResync: (() -> Void)?
  /// Every change to `text`, in order and in byte offsets, applied one after another: the user's, the remote ones,
  /// a rebase's. The PDF pane typesets from it (pdfpipe).
  var onText: ((_ edits: [Edit]) -> Void)?
  private var sendTimer: Timer?
  /// doc.changed that arrived before the result of our doc.edit (its continuation runs after them).
  private var early: [Int: [String: Any]] = [:]
  private var rangesAt: (seq: Int, list: [[String: Any]])?
  /// How long an edit waits before it goes to the engine: none (a timer of 0 sends it after this turn's frame). The
  /// engine batches for Overleaf (2 s / 0.5 s, engine.rs), and edits typed while one is in flight compose into one
  /// pending op; a 50 ms wait here only delayed the PDF, which gets our edits from the engine (docs/perf.md).
  public var sendDelay: TimeInterval = 0
  /// Counters for checks.
  public private(set) var sent = 0, received = 0

  public init(docID: String, path: String, text: String, seq: Int, conn: JSONRPCConnection?) {
    self.docID = docID
    self.path = path
    self.text = Array(text.utf8)
    self.base = self.text
    self.seq = seq
    self.conn = conn
  }

  public var string: String { String(decoding: text, as: UTF8.self) }
  public var unconfirmed: Int { (inflight?.edits.count ?? 0) + (pending?.edits.count ?? 0) }

  // MARK: local edits

  /// An edit made in the view, in byte offsets of the current text.
  public func local(_ e: Edit) {
    guard let op = try? Op.from(e, len: text.count) else { onResync?(); return }
    text.replaceSubrange(e.pos..<(e.pos + e.del), with: Array(e.ins.utf8))
    onText?([e])
    pending = pending.flatMap { try? Op.compose($0, op) } ?? op
    move(op)
    schedule()
  }

  private func schedule() {
    guard sendTimer == nil else { return }
    let t = Timer(timeInterval: sendDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.sendTimer = nil
        self?.flush()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    sendTimer = t
  }

  public func flush() {
    guard let conn, !conn.closed, let edits = takeSend() else { return }
    sent += 1
    onState?()
    let params: [String: Any] = ["doc_id": docID, "seq": seq, "edits": edits.map { ["pos": $0.pos, "del": $0.del, "ins": $0.ins] }]
    Task { @MainActor in
      do {
        let r = try await conn.call("doc.edit", params)
        ack(r["seq"] as? Int ?? seq + 1)
      } catch {
        // Not applied (as far as we know): back in front of what was typed since.
        if let i = inflight { pending = pending.flatMap { try? Op.compose(i, $0) } ?? i }
        inflight = nil
        onState?()
        // The connection went: the reconnect rebases and sends it. Otherwise the engine refused it (it doesn't know
        // our seq: restarted, or reopened the doc): say so, and start again from its text, keeping ours.
        if conn.closed { return }
        fail("doc.edit failed: \(error)")
        await rebase()
      }
    }
  }

  /// pending becomes inflight: the edits to send, nil if none (or one is already on its way).
  func takeSend() -> [Edit]? {
    guard inflight == nil, !rebasing, let p = pending else { return nil }
    inflight = p
    pending = nil
    if p.edits.isEmpty { inflight = nil; return nil }
    return p.edits
  }

  func ack(_ s: Int) {
    seq = s
    if let i = inflight {
      unflushed.append(base)
      base = i.apply(base)
    }
    error = nil
    inflight = nil
    // Changes that came in while the result was on its way.
    while let p = early.removeValue(forKey: seq + 1) { changed(p) }
    early = [:]
    if let r = rangesAt, r.seq == seq { rangesAt = nil; setRanges(r.list, seq: r.seq) }
    if pending != nil { flush() }
    onState?()
  }

  // MARK: remote edits

  /// `doc.changed` from the engine.
  public func changed(_ p: [String: Any]) {
    guard !rebasing, let s = p["seq"] as? Int else { return }  // (a rebase subscribes again from its seq)
    if s <= seq { return }
    if s != seq + 1 {
      if inflight != nil { early[s] = p; return }
      onResync?()
      return
    }
    let edits = (p["edits"] as? [[String: Any]] ?? []).map {
      Edit(pos: $0["pos"] as? Int ?? 0, del: $0["del"] as? Int ?? 0, ins: $0["ins"] as? String ?? "")
    }
    let base = inflight?.base ?? pending?.base ?? text.count
    guard var remote = try? Op.from(edits, len: base) else { onResync?(); return }
    do {
      if let i = inflight { let (r, i2) = try Op.transform(remote, i); remote = r; inflight = i2 }
      if let q = pending { let (r, q2) = try Op.transform(remote, q); remote = r; pending = q2 }
    } catch { onResync?(); return }
    seq = s
    received += 1
    self.base = self.base.applying(edits)
    unflushed = []
    let local = remote.edits
    let old = text
    text = text.applying(local)
    if !local.isEmpty { onText?(local) }
    move(remote)
    onRemote?(local, old)
    if let r = rangesAt, r.seq == seq { rangesAt = nil; setRanges(r.list, seq: r.seq) }
  }

  /// The engine's doc.state: Overleaf has every edit the engine confirmed. Only a state taken at or after our seq
  /// says so (E9, sm-sync 2612d3c): one sent before an edit's result, arriving after it, says nothing about that
  /// edit. No seq (an older engine): never cleared.
  func engineState(_ p: [String: Any]) {
    guard p["unconfirmed"] as? Int == 0, inflight == nil, let s = p["seq"] as? Int, s >= seq else { return }
    unflushed = []
  }

  func fail(_ msg: String) {
    error = msg
    onError?("\(path): \(msg)")
    onState?()
  }

  /// Re-open the doc and put our unconfirmed edits on top of the engine's text (buffer.lua's `rebase`): after a
  /// reconnect (the engine may be a new one, its seqs starting over), or when the engine refuses our seq. Ours =
  /// diff(confirmed text → our text); theirs = diff(confirmed text → engine's text); theirs goes to the view, ours
  /// (transformed past it) is sent at the engine's seq. Which of our edits the engine has: the confirmed text, with the
  /// one in flight, or without the confirmed ones Overleaf hadn't confirmed yet, whichever is closest to its text.
  public func rebase(projectID: String? = nil) async {
    guard !rebasing, let conn, !conn.closed else { return }
    guard let pid = projectID ?? self.projectID else { return }
    rebasing = true
    defer { rebasing = false }
    sendTimer?.invalidate()
    sendTimer = nil
    let r: [String: Any]
    do {
      r = try await conn.call("doc.open", ["project_id": pid, "path": path])
    } catch {
      if !conn.closed { fail("reopening the doc failed: \(error); your edits are kept, not synced") }
      return
    }
    guard let id = r["doc_id"] as? String, let server = (r["text"] as? String).map({ Array($0.utf8) }), let s = r["seq"] as? Int else {
      fail("reopening the doc gave no text; your edits are kept, not synced")
      return
    }
    func distance(_ x: [UInt8], _ y: [UInt8]) -> Int {
      x == y ? 0 : Op.diff(x, y).comps.reduce(0) { n, c in
        switch c {
        case .retain: return n
        case let .delete(k): return n + k
        case let .insert(t): return n + t.count
        }
      }
    }
    var cands = unflushed + [base]
    if let i = inflight { cands.append(i.apply(base)) }
    var from = base, best = Int.max
    for c in cands.reversed() {
      let d = distance(c, server)
      if d < best { best = d; from = c }
    }
    let mine = text
    do {
      let (theirs, ours) = try Op.transform(Op.diff(from, server), Op.diff(from, mine))
      let edits = theirs.edits
      docID = id
      seq = s
      base = server
      inflight = nil
      unflushed = []
      pending = ours.edits.isEmpty ? nil : ours
      early = [:]
      text = mine.applying(edits)
      if !edits.isEmpty { onText?(edits) }
      guard (pending?.apply(server) ?? server) == text else { throw Op.LengthMismatch() }
      if !edits.isEmpty { onRemote?(edits, mine) }
    } catch {
      fail("could not merge with the engine's text: \(error); your edits are kept, not synced")
      return
    }
    error = nil
    rebases += 1
    onState?()
    _ = try? await conn.call("doc.subscribe", ["doc_id": docID, "since_seq": seq])
    if let rr = try? await conn.call("doc.ranges", ["doc_id": docID]) {
      setRanges(rr["ranges"] as? [[String: Any]] ?? [], seq: rr["seq"] as? Int ?? seq)
    }
    rebasing = false
    flush()
  }

  /// The project, for rebases (set by NativeEditor).
  var projectID: String?

  /// After a reconnect: the new connection.
  func reconnected(_ c: JSONRPCConnection, projectID pid: String) {
    conn = c
    projectID = pid
  }

  // MARK: ranges

  private func move(_ op: Op) {
    guard !ranges.isEmpty else { return }
    for i in ranges.indices {
      let s = op.map(ranges[i].start)
      let e = op.map(ranges[i].end, stickLeft: true)
      ranges[i].start = s
      ranges[i].end = max(s, e)
    }
  }

  /// `doc.ranges` / `ranges.changed`: the whole list at the engine's `seq`.
  public func setRanges(_ list: [[String: Any]], seq s: Int) {
    if s > seq { rangesAt = (s, list); return }
    if s < seq { return }  // a newer list follows the changes we have already applied
    var out: [DocRange] = []
    for r in list {
      guard let id = r["id"] as? String, let kind = r["kind"] as? String, var a = r["start"] as? Int, var b = r["end"] as? Int else { continue }
      for op in [inflight, pending].compactMap({ $0 }) {
        a = op.map(a)
        b = max(a, op.map(b, stickLeft: true))
      }
      let au = r["author"] as? [String: Any] ?? [:]
      out.append(DocRange(
        id: id, kind: kind, start: a, end: b, text: r["text"] as? String ?? "",
        author: au.compactMapValues { $0 as? String }, ts: r["ts"] as? Double,
        threadID: r["thread_id"] as? String, resolved: r["resolved"] as? Bool ?? false))
    }
    ranges = out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    onRanges?()
  }

  /// A position (bytes at `seq`) moved to local text, as the engine's presence positions are.
  public func local(pos: Int, at s: Int) -> Int? {
    guard s == seq else { return nil }
    var p = pos
    for op in [inflight, pending].compactMap({ $0 }) { p = op.map(p) }
    return min(p, text.count)
  }
}

