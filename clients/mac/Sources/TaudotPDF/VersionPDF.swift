// A project as it was at a past version, on its own pane (History, docs/agents/history.md): typeset once by the
// project's typesetter, then kept as a finished PDF beside the version's files, and its changes marked on the pages.
// Insertions are boxed in their author's colour; a deletion is a small mark where the text was, its words on hover.
// The marks are placed the way review comments are (SyncTeX's line, then the words read off the page).
//
// Public API (owner of this file: the history agent; TaudotPDF is livepane's):
//   TaudotPDFPane.openVersion(folder:main:engine:)  the version's pane; a saved PDF if the folder has one
//   TaudotPDFPane.setChanges(_:) / selectChange(_:) / onChangeClick / placedChanges / versionSaved
//   PDFChange
import AppKit
import QuartzCore
import TaudotCursor
import TaudotShared

/// One change of a version, as History hands it to the PDF: where it is in the version's source, and who made it.
public struct PDFChange: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable { case insert, delete }
  public var id: String
  public var kind: Kind
  /// The source file, relative to the version's folder.
  public var path: String
  /// 1-based lines; columns are UTF-8 byte offsets, the end exclusive. A deletion is a place: end == start.
  public var line: Int
  public var column: Int
  public var endLine: Int
  public var endColumn: Int
  /// What was inserted or deleted.
  public var text: String
  public var author: String
  public var color: NSColor
  public var time: Date?
  public init(id: String, kind: Kind, path: String, line: Int, column: Int, endLine: Int, endColumn: Int, text: String,
              author: String, color: NSColor, time: Date?) {
    self.id = id; self.kind = kind; self.path = path; self.line = line; self.column = column
    self.endLine = endLine; self.endColumn = endColumn; self.text = text; self.author = author; self.color = color; self.time = time
  }
}

/// A change where it landed: its page and the boxes (an insertion's lines) or the mark's spot (a deletion).
public struct PlacedChange: Sendable, Equatable {
  public var id: String
  public var page: Int
  /// Page points from the page's top-left: an insertion's boxes, one per typeset line; a deletion's one rect, the
  /// height of its line, zero wide, where the text was.
  public var rects: [CGRect]
}

extension TaudotPDFPane {
  /// Opens a version's folder (its files as they were, made by History): the PDF saved there by an earlier open if
  /// there is one (instant), else typeset by `engine` (the project's) and saved when it settles. No engine feed and
  /// no folder watching: a version doesn't change.
  public func openVersion(folder: URL, main: String, engine: EngineChoice?) {
    close()
    self.folder = folder
    openedMainName = main
    versionFolder = folder
    versionSaved = false
    let saved = Self.savedVersion(folder)
    if FileManager.default.fileExists(atPath: saved.pdf.path), let t = FinishedPDF(pdf: saved.pdf, synctex: saved.synctex) {
      versionSaved = true
      install(t, choice: nil)
      return
    }
    let mainText = try? String(contentsOf: folder.appendingPathComponent(main), encoding: .utf8)
    startTypesetter(engine ?? EngineChoice.choose(compiler: nil, image: nil, mainText: mainText))
  }

  static func savedVersion(_ folder: URL) -> (pdf: URL, synctex: URL) {
    let d = folder.appendingPathComponent(".taudot")
    return (d.appendingPathComponent("version.pdf"), d.appendingPathComponent("version.synctex"))
  }

  /// A version's compile settled (again, after a rerun: the newest wins): keep its PDF and SyncTeX beside its files (the live pdfTeX's; TeXpresso's pages
  /// are drawn by its own process and aren't saved: that version is typeset again next time).
  func saveVersion(synctex text: String) {
    guard let folder = versionFolder, let live = txp as? LiveTex, let data = live.finalPDF else { return }
    let s = Self.savedVersion(folder)
    try? FileManager.default.createDirectory(at: s.pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try Data(text.utf8).write(to: s.synctex, options: .atomic)
      try data.write(to: s.pdf, options: .atomic)  // last: its being there says both are
      versionSaved = true
    } catch {
      onStatus?("history: can't keep this version's PDF: \(error.localizedDescription)")
    }
  }

  /// History's changes to mark (placed now if SyncTeX is in, and again after the typesetting settles).
  public func setChanges(_ c: [PDFChange]) {
    guard c != changeList else { return }
    changeList = c
    placeChanges()
  }

  /// Where the changes landed (tests, and History's count of those not on the pages).
  public var placedChanges: [PlacedChange] { pane.changes.placed }
  /// True once every change has been looked for on the pages (some may not be: a preamble, a comment).
  public var changesPlaced: Bool { changesDone }

  /// For snapshots (`cacheDisplay` draws sublayers in order, not by zPosition as the screen does).
  public func raiseChangeMarks() { pane.changes.raise() }

  /// Shows a change: scrolls it into view and pulses it, and keeps it outlined as the selected one.
  public func selectChange(_ id: String?) {
    pane.changes.selected = id
    guard let id, let p = pane.changes.placed.first(where: { $0.id == id }), let r = p.rects.first else { return }
    let visible = pane.convert(pane.scroll.contentView.bounds, from: pane.scroll.contentView)
    let shown = pane.toPane(pane.pagePoint(p.page, CGPoint(x: r.minX, y: r.midY)))
    if !visible.insetBy(dx: 0, dy: 30).contains(shown) { pane.scrollTo(page: p.page, y: max(0, r.minY - 120)) }
    pane.changes.pulse(id)
  }

  /// A change cut into what is placed: an insertion's source lines, each with its columns, leaving out lines with
  /// nothing to typeset (blank, a `%` comment); a deletion's place, then (in case its line has nothing typeset, e.g.
  /// a paragraph deleted between two others) the start of the next few lines that have text. A big insertion (a
  /// file uploaded, a section pasted) is marked line by line, so it shows wherever it starts.
  nonisolated static func pieces(_ c: PDFChange, maxLines: Int = 3000, line: (Int) -> String?) -> [(line: Int, from: Int, to: Int?)] {
    func typeset(_ s: Substring) -> Bool {
      let t = s.trimmingCharacters(in: .whitespaces)
      return !t.isEmpty && !t.hasPrefix("%")
    }
    var out: [(Int, Int, Int?)] = []
    switch c.kind {
    case .insert:
      for l in c.line...max(c.line, min(c.endLine, c.line + maxLines)) {
        guard let text = line(l) else { break }
        let b = Array(text.utf8)
        let from = l == c.line ? min(c.column, b.count) : 0, to = l == c.endLine ? min(max(c.endColumn, from), b.count) : b.count
        guard to > from, typeset(Substring(String(decoding: b[from..<to], as: UTF8.self))) else { continue }
        out.append((l, from, to))
      }
    case .delete:
      out.append((c.line, c.column, nil))
      var l = c.line + 1
      while out.count < 5, l <= c.line + 40, let text = line(l) {
        if typeset(Substring(text)) { out.append((l, 0, nil)) }
        l += 1
      }
    }
    return out
  }

  func placeChanges() {
    changesGen += 1
    changesDone = false
    let gen = changesGen
    guard let st = synctex else { pane.changes.set([], changes: changeList); return }
    let list = changeList
    // each piece as a comment: its typeset line through SyncTeX, then its words read off that page
    var pieces: [(change: PDFChange, k: Int, comment: PDFComment)] = []
    var text: [String: String] = [:]
    for c in list {
      let ps = Self.pieces(c) { l in
        let key = "\(c.path)\n\(l)"
        if let t = text[key] { return t }
        let t = self.sourceLine(c.path, l)
        text[key] = t
        return t
      }
      for (k, p) in ps.enumerated() {
        pieces.append((c, k, PDFComment(id: "\(c.id)\u{1}\(k)", path: c.path, line: p.line, column: p.from, endLine: p.line,
                                        endColumn: p.to, quote: "", author: c.author, firstMessage: "", replies: 0, resolved: false)))
      }
    }
    let lines = text
    let allComments = pieces.map(\.comment)
    // only the pieces matched word by word go through the placer (a deletion's, an insertion's ends)
    var lastK: [String: Int] = [:]
    for p in pieces { lastK[p.change.id] = p.k }
    let comments = pieces.filter { $0.change.kind == .delete || $0.k == 0 || $0.k == lastK[$0.change.id] }.map(\.comment)
    let widths = pane.pageSizes.map(\.width)
    Task {
      // SyncTeX's rows for every piece's line, once, off the main thread (each lookup scans the pages)
      let (placedRows, rowsMap) = await Task.detached(priority: .userInitiated) {
        var m: [String: (rows: [SyncTex.Row], marks: [Int])] = [:]
        for c in allComments where m["\(c.path)\n\(c.line)"] == nil { m["\(c.path)\n\(c.line)"] = st.rows(file: c.path, line: c.line) }
        let map = m
        let r = NotePlacement.place(comments, rows: { map["\($0)\n\($1)"] ?? st.rows(file: $0, line: $1) }, source: { lines["\($0)\n\($1)"] },
                                    pageWidth: { $0 < widths.count ? widths[$0] : 612 })
        return (r, map)
      }.value
      guard gen == self.changesGen else { return }
      let look: (String, Int) -> (rows: [SyncTex.Row], marks: [Int])? = { rowsMap["\($0)\n\($1)"] ?? st.rows(file: $0, line: $1) }
      let byPiece = Dictionary(placedRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      var placed: [PlacedChange] = []
      var deleted: Set<String> = []
      var shown = 0
      var last: [String: Int] = [:]
      for p in pieces { last[p.change.id] = p.k }
      // an insertion's ends: matched word by word; the typeset lines of its whole source lines between them are
      // inserted as a whole (boxed from SyncTeX's rows, no words to read), except the lines its ends are on
      // (only ends whose words were found: an end with nothing typeset, such as the `\end{itemize}` an inserted list
      // item ends on, has SyncTeX rows that are the last item's lines, which are inserted whole)
      var endRows: [String: [CGRect]] = [:]
      var endWords: [String: [CGRect]] = [:]
      for p in pieces where p.change.kind == .insert && (p.k == 0 || p.k == last[p.change.id]) {
        guard let n = byPiece[p.comment.id] else { continue }
        let q = await self.quoteRects(st, p.comment, page: n.page, rows: look)
        guard gen == self.changesGen else { return }
        endWords[p.comment.id] = q.words
        guard !q.words.isEmpty else { continue }
        for r in look(p.comment.path, p.comment.line)?.rows ?? [] { endRows[p.change.id, default: []].append(r.rect) }
      }
      func add(_ id: String, _ page: Int, _ boxes: [CGRect]) {
        guard !boxes.isEmpty else { return }
        if let i = placed.lastIndex(where: { $0.id == id && $0.page == page }) {
          placed[i].rects = ChangesOverlay.lineBoxes(placed[i].rects + boxes)
        } else {
          placed.append(PlacedChange(id: id, page: page, rects: ChangesOverlay.lineBoxes(boxes)))
        }
      }
      for piece in pieces {
        let c = piece.change
        if c.kind == .insert, piece.k > 0, piece.k < last[c.id] ?? 0 {
          let ends = endRows[c.id] ?? []
          let rows = (look(piece.comment.path, piece.comment.line)?.rows ?? []).filter { $0.rect.height <= LineMark.maxLine && !ends.contains($0.rect) }
          for (page, rs) in Dictionary(grouping: rows, by: \.page) { add(c.id, page, rs.map(\.rect)) }
          continue
        }
        guard let n = byPiece[piece.comment.id] else { continue }
        if c.kind == .insert {
          add(c.id, n.page, endWords[piece.comment.id] ?? [])
          continue
        }
        if deleted.contains(c.id) { continue }
        let q = await self.quoteRects(st, piece.comment, page: n.page, rows: look)
        guard gen == self.changesGen else { return }
        switch c.kind {
        case .insert:
          break
        case .delete:
          guard let w = q.words.first ?? q.line else { continue }
          // before the word the deletion was at, or after it when it was at the word's end (on its own line)
          var after = false
          if piece.k == 0 {
            let words = WordMatch.sourceWords(lines["\(c.path)\n\(c.line)"] ?? "")
            after = words.first { c.column > $0.start && c.column <= $0.end } != nil
          }
          let line = q.line ?? w
          placed.append(PlacedChange(id: c.id, page: n.page, rects: [CGRect(x: after ? w.maxX : w.minX, y: line.minY, width: 0, height: line.height)]))
          deleted.insert(c.id)
        }
        if placed.count >= shown + 8 {
          shown = placed.count
          self.pane.changes.set(placed, changes: list)
        }
      }
      self.pane.changes.set(placed, changes: list)
      self.changesDone = true
      self.onChangesPlaced?()
    }
  }
}

// ---- drawing ----------------------------------------------------------------------------------------------------------

@MainActor final class ChangesOverlay {
  private unowned let view: PDFPaneView
  private(set) var placed: [PlacedChange] = []
  private var changes: [String: PDFChange] = [:]
  private var layers: [String: [CALayer]] = [:]
  /// The hover card (a view of the pane over the pages that never takes the mouse) and the change it is for.
  private var card: HoverCardView?
  private var cardID: String?
  private var pendingID: String?
  private var showTask: Task<Void, Never>?
  private var hideTask: Task<Void, Never>?
  /// Tests: how many times a card was shown and hidden.
  private(set) var cardShows = 0, cardHides = 0
  static var showDelay: Duration = .milliseconds(350)
  static var hideDelay: Duration = .milliseconds(250)
  var onClick: ((String) -> Void)?
  /// The change outlined as selected (the diff view's current one).
  var selected: String? {
    didSet { if selected != oldValue { restyle([oldValue, selected].compactMap { $0 }) } }
  }

  init(view: PDFPaneView) { self.view = view }

  /// A deletion's mark is this many page points wide: ~7 screen points at any zoom.
  private var markWidth: CGFloat { min(30, max(4, 7 / max(view.scroll.magnification, 0.05))) }

  func set(_ placed: [PlacedChange], changes: [PDFChange]) {
    self.placed = placed
    self.changes = Dictionary(changes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for ls in layers.values { ls.forEach { $0.removeFromSuperlayer() } }
    layers = [:]
    for p in placed where p.page < view.pages.count {
      guard let c = self.changes[p.id] else { continue }
      var ls: [CALayer] = []
      switch c.kind {
      case .insert:
        for r in p.rects { ls.append(Self.box(r)) }
      case .delete:
        ls.append(Self.mark())
      }
      for l in ls { view.pages[p.page].layer.addSublayer(l) }
      layers[p.id, default: []] += ls
    }
    CATransaction.commit()
    restyle(Array(layers.keys))
    if let id = cardID, layers[id] == nil { closePopover() }
    // a card waiting for a change that went (marks placed again): it can't show; a hover will ask again
    if let id = pendingID, layers[id] == nil {
      showTask?.cancel()
      pendingID = nil
    }
  }

  /// For snapshots (`cacheDisplay` ignores zPosition): the marks moved to the top of their pages' sublayers.
  func raise() {
    for ls in layers.values {
      for l in ls {
        let s = l.superlayer
        l.removeFromSuperlayer()
        s?.addSublayer(l)
      }
    }
  }

  /// After a zoom: deletion marks keep their screen size.
  func rescale() { restyle(placed.compactMap { changes[$0.id]?.kind == .delete ? $0.id : nil }) }

  private func restyle(_ ids: [String]) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let w = markWidth
    for id in ids {
      guard let c = changes[id], let p = placed.first(where: { $0.id == id }), let ls = layers[id] else { continue }
      let on = id == selected
      switch c.kind {
      case .insert:
        for l in ls {
          l.backgroundColor = c.color.withAlphaComponent(on ? 0.26 : 0.16).cgColor
          l.borderColor = c.color.withAlphaComponent(on ? 1 : 0.75).cgColor
          l.borderWidth = on ? 1.6 : 0.9
        }
      case .delete:
        guard let l = ls.first as? CAShapeLayer, let r = p.rects.first else { continue }
        l.frame = Self.markRect(r, width: w)
        l.path = Self.markPath(l.bounds.size)
        l.fillColor = c.color.cgColor
        l.strokeColor = on ? NSColor.white.withAlphaComponent(0.9).cgColor : nil
        l.lineWidth = on ? max(0.6, w * 0.12) : 0
      }
    }
    CATransaction.commit()
  }

  /// The mark's rect for a deletion at `r` (zero wide, its line's height): a thin bar through the line with a small
  /// triangle on top, centred on the spot.
  static func markRect(_ r: CGRect, width w: CGFloat) -> CGRect {
    CGRect(x: r.minX - w / 2, y: r.minY - w * 0.55, width: w, height: r.height + w * 0.55)
  }

  /// In the layer's (flipped) coordinates: the triangle at the top, the bar down to the baseline.
  static func markPath(_ s: CGSize) -> CGPath {
    let p = CGMutablePath()
    let tri = s.width * 0.9
    p.move(to: CGPoint(x: 0, y: 0))
    p.addLine(to: CGPoint(x: s.width, y: 0))
    p.addLine(to: CGPoint(x: s.width / 2, y: tri))
    p.closeSubpath()
    let bw = max(0.8, s.width * 0.22)
    p.addRect(CGRect(x: (s.width - bw) / 2, y: tri * 0.5, width: bw, height: s.height - tri * 0.5))
    return p
  }

  private static func box(_ r: CGRect) -> CALayer {
    let l = CALayer()
    l.zPosition = 4
    l.frame = r.insetBy(dx: -1.2, dy: -0.8)
    l.cornerRadius = 1.5
    return l
  }

  private static func mark() -> CAShapeLayer {
    let l = CAShapeLayer()
    l.zPosition = 7
    l.isGeometryFlipped = false
    l.shadowColor = NSColor.black.cgColor
    l.shadowOpacity = 0.25
    l.shadowRadius = 0.8
    l.shadowOffset = .zero
    return l
  }

  /// An insertion's word boxes merged into one box per typeset line (a line of the other column, across the gap
  /// between columns, stays a box of its own).
  nonisolated static func lineBoxes(_ words: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for w in words {
      if let i = out.lastIndex(where: {
        abs($0.midY - w.midY) < max(2, min($0.height, w.height) * 0.5) && w.minX >= $0.minX - 1
          && w.minX <= $0.maxX + max(6, min($0.height, w.height) * 1.2)
      }) {
        out[i] = out[i].union(w)
      } else {
        out.append(w)
      }
    }
    return out
  }

  // ---- hover and click

  /// The change under a point of the pages view: the smallest that holds it (a deletion's mark before a box).
  func hit(_ pt: NSPoint) -> PlacedChange? {
    guard !placed.isEmpty, let i = view.pages.firstIndex(where: { $0.rect.contains(pt) }) else { return nil }
    let o = view.pages[i].origin
    let local = CGPoint(x: pt.x - o.x, y: pt.y - o.y)
    let w = markWidth
    var best: (PlacedChange, CGFloat)?
    for p in placed where p.page == i {
      let kind = changes[p.id]?.kind
      for r in p.rects {
        let area = kind == .delete ? Self.markRect(r, width: w).insetBy(dx: -2, dy: -1) : r.insetBy(dx: -1.5, dy: -1)
        guard area.contains(local) else { continue }
        let size = kind == .delete ? 0 : area.width * area.height
        if best == nil || size < best!.1 { best = (p, size) }
      }
    }
    return best?.0
  }

  /// True when the point is on a change, or on its card. The card shows after a short rest on the change (at once
  /// when another change's card is up), stays while the pointer is on any of the change's marks or on the card, and
  /// goes a moment after it leaves both. It is a view in the pane that hit-testing skips, so it never takes the mouse
  /// from the pages (an NSPopover's window did: the pages saw the mouse leave, closed it, saw it come back, reopened
  /// it, and so on: a flicker).
  func hover(_ pt: NSPoint?) -> Bool {
    if let pt, let c = card, cardID != nil, c.frame.contains(view.convert(pt, from: view.pagesView)) {
      cancelHide()
      return true
    }
    guard let pt, let p = hit(pt) else {
      showTask?.cancel()
      pendingID = nil
      if cardID != nil, hideTask == nil {
        hideTask = Task { [weak self] in
          try? await Task.sleep(for: Self.hideDelay)
          guard !Task.isCancelled else { return }
          self?.closePopover()
        }
      }
      return false
    }
    NSCursor.pointingHand.set()
    cancelHide()
    if cardID == p.id {
      // back on the shown card's change: a card still waiting for another one doesn't replace it
      if pendingID != nil { showTask?.cancel(); pendingID = nil }
      return true
    }
    if pendingID == p.id { return true }
    showTask?.cancel()
    pendingID = p.id
    if cardID != nil {
      showCard(p, at: pt)
      return true
    }
    showTask = Task { [weak self] in
      try? await Task.sleep(for: Self.showDelay)
      guard !Task.isCancelled, let self, self.pendingID == p.id else { return }
      self.showCard(p, at: pt)
    }
    return true
  }

  private func cancelHide() {
    hideTask?.cancel()
    hideTask = nil
  }

  func click(_ pt: NSPoint) -> Bool {
    guard let p = hit(pt) else { return false }
    closePopover()
    selected = p.id
    pulse(p.id)
    onClick?(p.id)
    return true
  }

  /// A gentle flash: an insertion's boxes brighten and settle; a deletion's mark swells once (with Reduce Motion it
  /// brightens instead).
  func pulse(_ id: String) {
    guard let ls = layers[id] else { return }
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for l in ls {
      if l is CAShapeLayer, !reduce {
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.3, 1]
        a.keyTimes = [0, 0.35, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        a.duration = 0.55
        l.add(a, forKey: "pulse")
      } else if l is CAShapeLayer {
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [1, 0.4, 1]
        o.duration = 0.5
        l.add(o, forKey: "pulse")
      } else {
        let f = CABasicAnimation(keyPath: "backgroundColor")
        f.fromValue = (l.backgroundColor ?? .clear).copy(alpha: 0.42)
        f.toValue = l.backgroundColor
        f.duration = 0.75
        f.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(f, forKey: "pulse")
      }
    }
  }

  /// The card for `p`, under the mark the pointer is on (above it when there's no room below), inside the pane.
  func showCard(_ p: PlacedChange, at pt: NSPoint) {
    pendingID = nil  // shown or not, it isn't waiting any more (a hover asks again)
    guard let c = changes[p.id], p.page < view.pages.count, !p.rects.isEmpty else { return }
    let o = view.pages[p.page].origin
    let local = CGPoint(x: pt.x - o.x, y: pt.y - o.y)
    let r0 = p.rects.first { $0.insetBy(dx: -2, dy: -2).contains(local) } ?? p.rects[0]
    let mark = (c.kind == .delete ? Self.markRect(r0, width: markWidth) : r0).offsetBy(dx: o.x, dy: o.y)
    let r = view.convert(mark, from: view.pagesView)
    let isNew = card == nil
    let v = card ?? HoverCardView()
    v.show(ChangeCard(c))
    let s = v.frame.size, b = view.bounds
    let y: CGFloat
    if view.isFlipped {
      y = r.maxY + 6 + s.height > b.maxY - 4 ? r.minY - 6 - s.height : r.maxY + 6
    } else {
      y = r.minY - 6 - s.height < b.minY + 4 ? r.maxY + 6 : r.minY - 6 - s.height
    }
    let x = min(max(b.minX + 6, view.convert(pt, from: view.pagesView).x - 24), b.maxX - s.width - 6)
    v.frame.origin = CGPoint(x: x, y: min(max(b.minY + 4, y), b.maxY - s.height - 4))
    if isNew || v.superview == nil {
      view.addSubview(v)
      v.alphaValue = 0
      NSAnimationContext.runAnimationGroup { c in
        c.duration = 0.12
        v.animator().alphaValue = 1
      }
    }
    card = v
    cardID = p.id
    cardShows += 1
  }

  func closePopover() {
    showTask?.cancel()
    pendingID = nil
    cancelHide()
    guard cardID != nil else { return }
    if let v = card {
      // fades out (the next card is a new view, so this one only has to go)
      NSAnimationContext.runAnimationGroup({ c in
        c.duration = 0.12
        v.animator().alphaValue = 0
      }, completionHandler: { MainActor.assumeIsolated { v.removeFromSuperview() } })
    }
    card = nil
    cardID = nil
    cardHides += 1
  }

  var popoverShown: String? { cardID }
  /// Tests: the shown card's size and frame (in the pane).
  var popoverSize: NSSize? { card?.frame.size }
  var cardFrame: NSRect? { card?.frame }
}

/// The hover card's frame: rounded, solid (the page's text never shows through), a hairline and a soft shadow; a view
/// of the pane that hit-testing passes over, so the pages keep the mouse.
final class HoverCardView: NSView {
  private(set) var content: NSViewController?
  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 0.5
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    restyle()
  }
  private func restyle() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  func show(_ vc: NSViewController) {
    content?.view.removeFromSuperview()
    content = vc
    let v = vc.view
    v.frame.origin = .zero
    frame.size = v.frame.size
    addSubview(v)
  }
  override func hitTest(_ p: NSPoint) -> NSView? { nil }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    restyle()
  }
}

/// The hover card: "Added by Bob" (or Deleted), when, and the text (struck through for a deletion).
final class ChangeCard: NSViewController {
  let change: PDFChange
  init(_ c: PDFChange) {
    change = c
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  static func when(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: d)
  }

  override func loadView() {
    let c = change
    let head = NSMutableAttributedString(string: c.kind == .insert ? "Added by " : "Deleted by ",
                                         attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
    head.append(NSAttributedString(string: c.author, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: c.color]))
    let w = Self.when(c.time)
    if !w.isEmpty { head.append(NSAttributedString(string: " · " + w, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])) }
    let title = NSTextField(labelWithAttributedString: head)
    var t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count > 280 { t = String(t.prefix(280)) + "…" }
    var a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor]
    if c.kind == .delete {
      a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      a[.strikethroughColor] = c.color
    }
    a[.backgroundColor] = c.color.withAlphaComponent(0.14)
    let body = NSTextField(wrappingLabelWithString: "")
    body.attributedStringValue = NSAttributedString(string: t.isEmpty ? "(spaces)" : t, attributes: a)
    body.maximumNumberOfLines = 8
    body.lineBreakMode = .byWordWrapping
    // sized by hand: a wrapping label in an auto-sized popover gets no width and wraps a letter a line, which drew
    // a tall empty capsule over the page
    title.sizeToFit()
    let pad = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    let cw = min(Self.maxWidth, max(Self.minWidth, title.frame.width, ceil(body.attributedStringValue.size().width) + 4))
    let bh = min(ceil(body.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: cw, height: 400)).height), 8 * 16)
    let size = NSSize(width: cw + pad.left + pad.right, height: pad.top + title.frame.height + 6 + bh + pad.bottom)
    let v = NSView(frame: NSRect(origin: .zero, size: size))
    title.frame = NSRect(x: pad.left, y: size.height - pad.top - title.frame.height, width: cw, height: title.frame.height)
    body.frame = NSRect(x: pad.left, y: pad.bottom, width: cw, height: bh)
    body.preferredMaxLayoutWidth = cw
    v.addSubview(title)
    v.addSubview(body)
    view = v
    preferredContentSize = size
  }
  static let minWidth: CGFloat = 160, maxWidth: CGFloat = 320
}

// ---- a finished PDF as a typesetter -------------------------------------------------------------------------------

/// A version's saved PDF, served the way the live pdfTeX serves its PDFs: every page at once, settled.
@MainActor final class FinishedPDF: Typesetter {
  let pdf: LivePDF
  var onPages: ((PagesEvent) -> Void)?
  var onError: ((String) -> Void)?
  var onLine: ((String) -> Void)?
  var onNote: ((String) -> Void)?
  var onRestart: (() -> Void)?
  var pageStyle = "white"
  var restartCount: Int { 0 }
  var sent: Int { 0 }
  var hasGlyphs: Bool { true }
  var engineName: String { "saved PDF" }

  init?(pdf: URL, synctex: URL) {
    guard let p = LivePDF(path: pdf.path, synctex: synctex.path, log: nil, seq: 0, run: 0) else { return nil }
    self.pdf = p
  }

  func start() {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let sizes = self.pdf.sizes.map { [Double($0.width), Double($0.height)] }
        let ev: [String: Any] = ["ev": "pages", "gen": 1, "n": sizes.count, "typeset": sizes.count, "done": true,
                                 "sizes": sizes, "changed": Array(0..<sizes.count), "edit_us": 0, "applied": 0]
        if let e = PagesEvent(ev) { self.onPages?(e) }
      }
    }
  }
  func stop() {}
  func killForTest() {}
  func open(_ path: String, _ text: String) {}
  func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) {}
  func rescan() {}
  func goal(_ page: Int) {}
  func synctex() async -> String? { pdf.synctex }
  func glyphs(page: Int) async -> PageGlyphs? {
    guard page >= 0, page < pdf.sizes.count else { return nil }
    let pdf = self.pdf
    return await Task.detached(priority: .userInitiated) { LiveDraw.glyphs(pdf, page: page).map(UncheckedBox.init) }.value?.v
  }
  func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    guard page >= 0, page < pdf.sizes.count else { return nil }
    let pdf = self.pdf, style = pageStyle
    return await Task.detached(priority: .userInitiated) {
      LiveDraw.render(pdf, page: page, scale: scale, x: x, y: y, w: w, h: h, style: style).map(UncheckedBox.init)
    }.value?.v
  }
}
