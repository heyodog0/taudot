// Settings ▸ Appearance live: after a light ↔ dark switch every review piece (cards, header, pills, the bar, the
// floating cards, the lines) looks as it would if it had been built in the new appearance.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let ada = ReviewUser(id: "u-a", name: "Ada Lovelace", initials: "AL")
private let linus = ReviewUser(id: "u-l", name: "Linus Yarrow", initials: "LY")
private func note(_ id: String, _ line: Int, resolved: Bool = false, color: String? = "#f59e0b") -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: ada, color: color, ts: Date(timeIntervalSince1970: 1_700_000_000),
             quote: "the quoted words",
             messages: [ReviewMessage(id: "m" + id, text: "A comment \(id)", ts: Date(timeIntervalSince1970: 1_700_000_000), user: ada, mine: false),
                        ReviewMessage(id: "r" + id, text: "A reply", ts: Date(timeIntervalSince1970: 1_700_000_100), user: linus, mine: true)],
             range: ReviewRange(line: line, col: 2, endLine: line, endCol: 9), resolved: resolved)
}
private func change(_ id: String, _ line: Int, kind: ReviewKind = .insert) -> ReviewItem {
  ReviewItem(id: id, kind: kind, author: linus, color: "#14b8a6", ts: Date(timeIntervalSince1970: 1_700_000_000), quote: "w\(id)",
             range: ReviewRange(line: line, col: 0, endLine: line, endCol: 3))
}
private let items = [note("n0", 1), change("a", 4), change("b", 6, kind: .delete), note("n1", 9), note("n2", 12, resolved: true),
                     note("far", 120), change("far2", 130)]

private final class Ed: NSView { override var isFlipped: Bool { true } }

@MainActor private final class Scene {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  var ed: Ed!, sidebar: SidebarView!, bar: ReviewBar!
  var m: ReviewMarginView { sidebar.margin }
  /// Built while `a` is the current appearance (as the app builds its views under the appearance of the moment).
  init(_ a: NSAppearance.Name, floating: Bool) {
    NSAppearance(named: a)!.performAsCurrentDrawingAppearance { build(a, floating: floating) }
  }
  private func build(_ a: NSAppearance.Name, floating: Bool) {
    w.appearance = NSAppearance(named: a)
    let cv = w.contentView!
    cv.wantsLayer = true
    ed = Ed(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
    sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    sidebar.tab = .comments
    sidebar.scope = .file
    bar = ReviewBar(frame: NSRect(x: 400, y: 520, width: 520, height: 40))
    cv.addSubview(ed)
    cv.addSubview(sidebar)
    cv.addSubview(bar)
    bar.isHidden = false
    bar.show(text: "Comment 1 of 3 · Ada", comment: true)
    m.animationDuration = 0
    m.floating.fade = 0
    let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 200, viewHeight: 600)
    g.cellWidth = 8
    m.geometry = g
    m.editorView = ed
    m.showResolved = true
    sidebar.isHidden = floating
    m.state = ReviewState(buf: 1, items: items)
    var c = ReviewCursor(buf: 1, line: 9, col: 4, here: ["n1"])
    c.at = ScreenAt(columns: 80, cursorWrap: 0, items: ["n1": .init(startWrap: 0, startCol: 2, endWrap: 0)])
    m.cursor = c
    m.layoutSubtreeIfNeeded()
    m.place()
    settle()
  }
  /// What AppKit does on the next frame: layout, then every view that needs it redraws (updateLayer).
  func settle() {
    w.contentView!.layoutSubtreeIfNeeded()
    func display(_ v: NSView) {
      v.displayIfNeeded()
      v.layer?.displayIfNeeded()
      v.subviews.forEach(display)
    }
    display(w.contentView!)
  }
  /// Settings ▸ Appearance: the window's appearance changes; the next frames run in it.
  func flip(to a: NSAppearance.Name) {
    w.appearance = NSAppearance(named: a)
    NSAppearance(named: a)!.performAsCurrentDrawingAppearance { settle() }
  }
}

private func rgba(_ c: CGColor?) -> String {
  guard let c, let s = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
        let p = s.components else { return "-" }
  return p.map { String(format: "%.3f", $0) }.joined(separator: ",")
}
private func rgba(_ c: NSColor?, in v: NSView) -> String {
  guard let c else { return "-" }
  var out = "-"
  v.effectiveAppearance.performAsCurrentDrawingAppearance { out = rgba(c.cgColor) }
  return out
}

/// Every colour the review pieces show, by where it is: layer colours (backgrounds, borders, lines) and the colours of
/// text, attributed text and tinted symbols (resolved in the view's appearance, as they would draw).
@MainActor private func colours(_ s: Scene) -> [String: String] {
  var out: [String: String] = [:]
  /// A layer's colours, and those of the plain layers in it (the lines, masks; not its subviews' layers), the plain
  /// ones in a stable order (the lines' order in the overlay is the dictionary's).
  func sig(_ l: CALayer) -> [String] {
    guard !l.isHidden else { return [] }
    var mine = ["bg " + rgba(l.backgroundColor), "border " + rgba(l.borderColor)]
    if let sh = l as? CAShapeLayer, sh.path != nil { mine += ["stroke " + rgba(sh.strokeColor), "fill " + rgba(sh.fillColor)] }
    let subs = (l.sublayers ?? []).filter { !($0.delegate is NSView) }.map { sig($0).joined(separator: " ") }.filter { !$0.isEmpty }.sorted()
    return mine + subs.map { "{" + $0 + "}" }
  }
  func views(_ v: NSView, _ path: String) {
    let here = path + "/" + String(describing: type(of: v))
    if !v.isHiddenOrHasHiddenAncestor {
      if let l = v.layer { for (i, x) in sig(l).enumerated() { out[here + ".layer\(i)"] = x } }
      if let f = v as? NSTextField {
        out[here + ".text"] = rgba(f.textColor, in: f)
        let a = f.attributedStringValue
        a.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: a.length)) { c, r, _ in
          out[here + ".attr\(r.location)"] = rgba(c as? NSColor, in: f)
        }
      }
      if let b = v as? NSButton { out[here + ".tint"] = rgba(b.contentTintColor, in: b) }
      if let i = v as? NSImageView { out[here + ".tint"] = rgba(i.contentTintColor, in: i) }
    }
    for (i, sub) in v.subviews.enumerated() { views(sub, here + "[\(i)]") }
  }
  views(s.w.contentView!, "")
  return out
}

@MainActor private func expectSame(_ live: Scene, _ fresh: Scene, _ what: String) {
  let a = colours(live), b = colours(fresh)
  let keys = Set(a.keys).union(b.keys).sorted()
  let diff = keys.filter { a[$0] != b[$0] }
  #expect(diff.isEmpty, "\(what): \(diff.count) colours differ, e.g. \(diff.prefix(40).map { "\($0): \(a[$0] ?? "missing") vs \(b[$0] ?? "missing")" })")
  #expect(a.count > 30, "\(what): only \(a.count) colours seen")
}

@MainActor @Test func theMarginFollowsALiveAppearanceChange() {
  UserDefaults.standard.removeObject(forKey: ConnectorMode.key)
  for (from, to) in [(NSAppearance.Name.aqua, NSAppearance.Name.darkAqua), (.darkAqua, .aqua)] {
    let live = Scene(from, floating: false)
    // (the light and dark looks really differ, or the comparison proves nothing)
    #expect(colours(live) != colours(Scene(to, floating: false)))
    live.flip(to: to)
    expectSame(live, Scene(to, floating: false), "margin \(from.rawValue) → \(to.rawValue)")
  }
}

@MainActor @Test func floatingCardsFollowALiveAppearanceChange() {
  for (from, to) in [(NSAppearance.Name.aqua, NSAppearance.Name.darkAqua), (.darkAqua, .aqua)] {
    let live = Scene(from, floating: true)
    #expect(live.m.floating.shownIDs == ["n1"])
    live.flip(to: to)
    expectSame(live, Scene(to, floating: true), "floating \(from.rawValue) → \(to.rawValue)")
  }
}

