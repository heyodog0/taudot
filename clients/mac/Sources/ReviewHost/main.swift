// ReviewHost: the review margin beside a plain text view, to build and check it alone (docs/agents/margin.md).
//
//   swift run ReviewHost                       fake comments and changes on a sample document
//   swift run ReviewHost --nvim                headless `nvim --embed` with the plugin and the mock engine's bot
//   ... --dark  --shot out.png  --select N  --scroll PT  --resolved
//   ... --sel L:C-L:C (select that range)  --new (a new comment on it, else on the first line)
//   ... --type TEXT (typed into the selected card's field)
//
// --shot captures the window once it has settled and quits.
import AppKit
import TaudotReview
import TaudotShared

// TEXSYNC_* variables (names before the rename) still work (Compat.swift).
Compat.envFallback()

let args = CommandLine.arguments
func flag(_ f: String) -> Bool { args.contains(f) }
func option(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

// ---- a text view that says where its lines are ------------------------------------------------------------------

@MainActor final class TextEditorGeometry: NSObject, EditorGeometry {
  let scroll: NSScrollView
  let text: NSTextView
  var buffer = 1
  private var handlers: [@MainActor () -> Void] = []
  private var starts: [Int] = [0]

  init(scroll: NSScrollView, text: NSTextView) {
    self.scroll = scroll
    self.text = text
    super.init()
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.changed() }
    }
    NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: text, queue: nil) { [weak self] _ in
      MainActor.assumeIsolated { self?.reindex(); self?.changed() }
    }
    reindex()
  }

  func reindex() {
    let s = text.string as NSString
    starts = [0]
    var i = 0
    while i < s.length {
      let r = s.lineRange(for: NSRange(location: i, length: 0))
      i = NSMaxRange(r)
      if i < s.length || (i == s.length && s.length > 0 && s.character(at: s.length - 1) == 10) { starts.append(i) }
      if r.length == 0 { break }
    }
  }
  func changed() { for h in handlers { h() } }

  var lineHeight: CGFloat { text.layoutManager?.defaultLineHeight(for: text.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)) ?? 17 }

  func y(ofLine line: Int) -> CGFloat? {
    guard line >= 0, line < starts.count, let lm = text.layoutManager else { return nil }
    let ci = min(starts[line], max(0, (text.string as NSString).length))
    let rect: NSRect
    if ci >= (text.string as NSString).length {
      rect = lm.extraLineFragmentRect
    } else {
      let gi = lm.glyphIndexForCharacter(at: ci)
      rect = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
    }
    return rect.minY + text.textContainerOrigin.y - scroll.contentView.bounds.minY
  }

  var visibleLines: ClosedRange<Int> {
    let top = scroll.contentView.bounds.minY
    let h = scroll.contentView.bounds.height
    let first = max(0, Int(top / lineHeight))
    return first...max(first, min(starts.count - 1, Int((top + h) / lineHeight) + 1))
  }
  func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

  /// Character index of (line, character column).
  func offset(line: Int, col: Int) -> Int {
    let l = min(max(0, line), starts.count - 1)
    return min(starts[l] + col, (text.string as NSString).length)
  }

  /// (line, byte col) of a character index, the way Neovim counts.
  func position(_ ci: Int) -> (Int, Int) {
    var line = 0
    while line + 1 < starts.count && starts[line + 1] <= ci { line += 1 }
    let s = (text.string as NSString).substring(with: NSRange(location: starts[line], length: ci - starts[line]))
    return (line, s.utf8.count)
  }
}

// ---- the fake model -------------------------------------------------------------------------------------------------

let sample = """
\\documentclass{article}
\\usepackage{amsmath}
\\title{Counting Paths in a Grid}
\\author{You and Ada}

\\begin{document}
\\maketitle

\\section{Introduction}
We study a simple problem about counting paths in a grid.
The answer is a binomial coefficient, which we prove in two ways.
Both proofs are short, and each says something the other doesn't.

\\section{Result}
For every $n$ the number of monotone paths is $\\binom{2n}{n}$.
The first proof is a bijection with words over two letters.
The second proof uses generating functions.

\\section{The bijection}
A monotone path from $(0,0)$ to $(n,n)$ takes $2n$ unit steps.
Write R for a step right and U for a step up.
Each path gives a word with $n$ letters R and $n$ letters U, and each such word gives a path.
There are $\\binom{2n}{n}$ such words.

\\section{Generating functions}
Let $p_{a,b}$ be the number of paths to $(a,b)$.
Then $p_{a,b} = p_{a-1,b} + p_{a,b-1}$ with $p_{0,0} = 1$.
The generating function $P(x,y) = \\sum p_{a,b} x^a y^b$ satisfies $P = 1 + (x+y)P$.
So $P = 1/(1-x-y)$, and the coefficient of $x^n y^n$ is $\\binom{2n}{n}$.

\\section{Discussion}
The first proof explains the answer; the second computes it.
Both extend to paths in $d$ dimensions, with multinomial coefficients.
We leave lattice paths that avoid a diagonal for later.

\\end{document}
"""

@MainActor final class FakeStore {
  let ada = ReviewUser(id: "u-ada", name: "Ada Lovelace", initials: "AL")
  let grace = ReviewUser(id: "u-grace", name: "Grace Hopper", initials: "GH")
  let me = ReviewUser(id: "u-me", name: "You", initials: "Y")
  var state = ReviewState()
  var next = 100
  var onChange: ((ReviewState) -> Void)?

  init() {
    let now = Date()
    func msg(_ u: ReviewUser, _ t: String, _ ago: Double) -> ReviewMessage {
      next += 1
      return ReviewMessage(id: "m\(next)", text: t, ts: now.addingTimeInterval(-ago), user: u, mine: u == me)
    }
    func r(_ l: Int, _ c: Int, _ e: Int) -> ReviewRange { ReviewRange(line: l, col: c, endLine: l, endCol: e) }
    state = ReviewState(buf: 1, path: "main.tex", me: "u-me", items: [
      ReviewItem(id: "t1", kind: .comment, threadID: "t1", author: ada, color: "#2f80ed", quote: "binomial coefficient",
                 messages: [msg(ada, "Say which one: the central binomial coefficient.", 7200), msg(me, "Good point, will do.", 3500)], range: r(10, 16, 36)),
      ReviewItem(id: "t2", kind: .comment, threadID: "t2", author: grace, color: "#e0752d", quote: "each says something",
                 messages: [msg(grace, "Is this true? The second proof only computes.", 1800)], range: r(11, 22, 41)),
      ReviewItem(id: "c1", kind: .insert, author: ada, color: "#2f80ed", ts: now.addingTimeInterval(-600), quote: " (a Dyck-free count)", range: r(15, 59, 79)),
      ReviewItem(id: "t3", kind: .comment, threadID: "t3", author: ada, color: "#2f80ed", quote: "unit steps",
                 messages: [msg(ada, "Cite Feller here?", 86400 * 2)], range: r(19, 56, 66)),
      ReviewItem(id: "c2", kind: .delete, author: grace, color: "#e0752d", ts: now.addingTimeInterval(-240), quote: "and each such word gives a path", range: r(21, 58, 58)),
      ReviewItem(id: "t4", kind: .comment, threadID: "t4", author: grace, color: "#e0752d", quote: "generating function",
                 messages: [msg(grace, "Define it first.", 86400)], range: r(26, 4, 23), resolved: true, resolvedBy: grace),
      ReviewItem(id: "t5", kind: .comment, threadID: "t5", author: ada, color: "#2f80ed", quote: "for later",
                 messages: [msg(ada, "Or mention the ballot problem now?", 400)], range: r(32, 47, 56)),
    ])
  }

  func act(_ a: ReviewAction) -> String? {
    func edit(_ id: String, _ f: (inout ReviewItem) -> Void) {
      if let i = state.items.firstIndex(where: { $0.id == id }) { f(&state.items[i]) }
    }
    switch a {
    case .select, .goto, .open, .reveal: return nil
    case let .acceptAll(ids), let .rejectAll(ids):
      state.items.removeAll { ids.contains($0.id) }
      return nil
    case let .reply(id, text):
      next += 1
      edit(id) { $0.messages.append(ReviewMessage(id: "m\(next)", text: text, ts: Date(), user: me, mine: true)) }
    case let .resolve(id): edit(id) { $0.resolved = true; $0.resolvedBy = me }
    case let .reopen(id): edit(id) { $0.resolved = false }
    case let .delete(id), let .accept(id), let .reject(id): state.items.removeAll { $0.id == id }
    case let .editMessage(id, mid, text): edit(id) { it in if let k = it.messages.firstIndex(where: { $0.id == mid }) { it.messages[k].text = text } }
    case let .deleteMessage(id, mid): edit(id) { $0.messages.removeAll { $0.id == mid } }
    case let .comment(range, text):
      next += 1
      state.items.append(ReviewItem(id: "t\(next)", kind: .comment, threadID: "t\(next)", author: me, quote: "",
                                    messages: [ReviewMessage(id: "m\(next)", text: text, ts: Date(), user: me, mine: true)], range: range))
    }
    onChange?(state)
    return nil
  }
}

// ---- the window -----------------------------------------------------------------------------------------------------

@MainActor final class Host: NSObject, NSApplicationDelegate, NSTextViewDelegate {
  var window: NSWindow!
  var geometry: TextEditorGeometry!
  let margin = ReviewMarginView(frame: .zero)
  var sidebar: SidebarView?
  var store: FakeStore?
  var nvim: EmbeddedNeovim?
  var controller: ReviewController?
  var mock: Process?
  var tmp: URL?
  var text: NSTextView!

  func applicationDidFinishLaunching(_ n: Notification) {
    if flag("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
    if flag("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
    let frame = NSRect(x: 80, y: 80, width: 980, height: 720)
    window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "ReviewHost"
    window.titlebarAppearsTransparent = false

    let split = NSView(frame: NSRect(origin: .zero, size: frame.size))
    let scroll = NSTextView.scrollableTextView()
    text = scroll.documentView as? NSTextView
    text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    text.isRichText = false
    text.textContainerInset = NSSize(width: 14, height: 10)
    text.delegate = self
    text.string = sample + String(repeating: "\n", count: 20)
    text.isAutomaticQuoteSubstitutionEnabled = false
    let mw: CGFloat = 330
    let top: CGFloat = 0
    // margin | editor (| PDF in the app), docs/mac-app.md.
    margin.frame = NSRect(x: 0, y: 0, width: mw, height: frame.height - top)
    margin.autoresizingMask = [.maxXMargin, .height]
    scroll.frame = NSRect(x: mw, y: 0, width: frame.width - mw, height: frame.height - top)
    scroll.autoresizingMask = [.width, .height]
    split.addSubview(scroll)
    if let folder = option("--sidebar") {
      // The sidebar (Files | Comments) as the left pane, the margin its Comments tab.
      let sb = SidebarView(frame: margin.frame, margin: margin)
      sb.autoresizingMask = [.maxXMargin, .height]
      sb.folder = URL(fileURLWithPath: folder)
      if let t = option("--tab").flatMap(SidebarView.Tab.init(rawValue:)) { sb.tab = t }
      for rel in (option("--expand") ?? "").split(separator: ",") {
        sb.files.expand(String(rel))
      }
      sb.files.current = URL(fileURLWithPath: folder).appendingPathComponent(option("--current") ?? "main.tex")
      sb.files.onOpen = { url in NSLog("open \(url.path)") }
      // --badges main.tex,refs.bib: open comments on the first, a collaborator (Grace) in the second.
      if let b = option("--badges")?.split(separator: ",").map(String.init), b.count >= 2 {
        sb.files.badges = FileBadges(comments: [b[0]: 3], people: [b[1]: [.init(name: "Grace Hopper", initials: "GH", color: "#e0703a")]])
      }
      if let h = option("--hover") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sb.files.cell(h)?.hovered = true }
      }
      split.addSubview(sb)
      sidebar = sb
    } else {
      split.addSubview(margin)
    }
    window.contentView = split
    geometry = TextEditorGeometry(scroll: scroll, text: text)
    margin.geometry = geometry
    margin.editorView = scroll
    margin.me = ReviewUser(id: "u-me", name: "You", initials: "Y")
    // The margin's top is the scroll view's top; both sit under the title bar.
    margin.editorOffset = 0
    addMenu()

    if flag("--nvim") {
      startNvim()
    } else {
      let s = FakeStore()
      store = s
      s.onChange = { [weak self] st in self?.margin.state = st }
      if let sb = sidebar { seedSidebar(sb, s) }
      margin.state = s.state
      margin.onAction = { [weak self] a in
        guard let self, let s = self.store else { return }
        _ = s.act(a)
        self.margin.actionSucceeded(a)
      }
    }
    margin.showResolved = flag("--resolved")
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if let y = option("--scroll").flatMap(Double.init) {
      scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    if let n = option("--select").flatMap(Int.init) {
      DispatchQueue.main.asyncAfter(deadline: .now() + (flag("--nvim") ? 8 : 0.3)) {
        let ids = self.margin.shown.map(\.id)
        if n < ids.count { self.margin.select(ids[n]) }
      }
    }
    // --sel L:C-L:C (0-based lines and columns): select that range in the text (the pill shows under its end).
    if let sel = option("--sel") {
      let n = sel.split(whereSeparator: { ":-".contains($0) }).compactMap { Int($0) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        guard n.count == 4 else { return }
        let a = self.geometry.offset(line: n[0], col: n[1]), b = self.geometry.offset(line: n[2], col: n[3])
        self.window.makeFirstResponder(self.text)
        self.text.setSelectedRange(NSRange(location: a, length: max(0, b - a)))
      }
    }
    if flag("--new") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        if self.text.selectedRange().length == 0 {
          let len = (self.text.string as NSString).lineRange(for: NSRange(location: 0, length: 0)).length
          self.text.setSelectedRange(NSRange(location: 0, length: max(0, len - 1)))
        }
        self.newComment()
      }
    }
    if let t = option("--type") {
      DispatchQueue.main.asyncAfter(deadline: .now() + (flag("--nvim") ? 9 : 0.7)) { self.margin.typeInSelectedReply(t) }
    }
    if let out = option("--shot") {
      DispatchQueue.main.asyncAfter(deadline: .now() + (flag("--nvim") ? 10 : 1.2)) { self.shot(out) }
    }
  }

  func addMenu() {
    let main = NSMenu()
    let app = NSMenuItem()
    app.submenu = NSMenu()
    app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(app)
    let review = NSMenuItem()
    review.submenu = NSMenu(title: "Review")
    let c = NSMenuItem(title: "New Comment", action: #selector(newComment), keyEquivalent: "m")
    c.keyEquivalentModifierMask = [.command, .option]
    c.target = self
    review.submenu?.addItem(c)
    main.addItem(review)
    NSApp.mainMenu = main
  }

  @objc func newComment() {
    if controller != nil { margin.newComment(); return }  // --nvim: gui.lua finds the selection
    let r = text.selectedRange()
    guard r.length > 0 else { NSSound.beep(); return }
    let (l, c) = geometry.position(r.location)
    let (el, ec) = geometry.position(NSMaxRange(r))
    margin.beginNewComment(on: ReviewRange(line: l, col: c, endLine: el, endCol: ec), quote: (text.string as NSString).substring(with: r))
  }

  // The text view's selection is the cursor (fake mode; in --nvim mode the click moves Neovim's cursor).
  func textViewDidChangeSelection(_ n: Notification) {
    guard geometry != nil else { return }
    let r = text.selectedRange()
    let (l, c) = geometry.position(r.location)
    if let nvim {
      Task { _ = try? await nvim.execLua("vim.api.nvim_win_set_cursor(0, {...})", [.int(Int64(l + 1)), .int(Int64(c))]) }
      return
    }
    guard let store else { return }
    var here: [String] = []
    for it in store.state.items {
      let a = (it.range.line, it.range.col), b = (it.range.endLine, it.range.endCol)
      if (l, c) >= a && ((l, c) < b || (a == b && (l, c) == a)) { here.append(it.id) }
    }
    var visual: ReviewRange?
    var end: SelectionEnd?
    if r.length > 0 {
      let (el, ec) = geometry.position(NSMaxRange(r))
      visual = ReviewRange(line: l, col: c, endLine: el, endCol: ec)
      // Where the end is drawn, as the grid numbers gui.lua sends: its row within the wrapped line, its column.
      if let lm = text.layoutManager, let tc = text.textContainer {
        let s = text.string as NSString
        let lineStart = s.lineRange(for: NSRange(location: max(0, NSMaxRange(r) - 1), length: 0)).location
        let a = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: lineStart), effectiveRange: nil)
        let last = lm.glyphIndexForCharacter(at: max(0, NSMaxRange(r) - 1))
        let b = lm.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let x = lm.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: tc).maxX + text.textContainerOrigin.x
        let cw = ("M" as NSString).size(withAttributes: [.font: text.font!]).width
        end = SelectionEnd(wrap: Int(((b.minY - a.minY) / max(1, b.height)).rounded()), screenCol: Int((x / cw).rounded()),
                           columns: max(1, Int((text.enclosingScrollView ?? text).bounds.width / cw)))
      }
    }
    if ProcessInfo.processInfo.environment["REVIEWHOST_DEBUG"] != nil, let end { print("visual end", end, visual!) }
    margin.cursor = ReviewCursor(buf: 1, line: l, col: c, here: here, visual: visual, visualEnd: end)
  }

  // ---- --nvim -------------------------------------------------------------------------------------------------

  func startNvim() {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reviewhost-\(ProcessInfo.processInfo.processIdentifier)")
    self.tmp = tmp
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: repo.appendingPathComponent("clients/mock-engine/example/main.tex"), to: tmp.appendingPathComponent("main.tex"))
    let sock = tmp.appendingPathComponent("e.sock").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["deno", "run", "-A", repo.appendingPathComponent("clients/mock-engine/main.ts").path, "--folder", tmp.path, "--socket", sock,
                   "--bot", "--bot-interval", option("--bot-interval") ?? "700", "--bot-char", "25"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    mock = p
    Task { @MainActor in
      for _ in 0..<200 where !FileManager.default.fileExists(atPath: sock) { try? await Task.sleep(for: .milliseconds(50)) }
      do {
        let nvim = try EmbeddedNeovim(env: ["TAUDOT_SOCKET": sock], cwd: tmp)
        self.nvim = nvim
        _ = try await nvim.execLua(ReviewHostLua.setup, [.string(repo.appendingPathComponent("clients/nvim").path), .string(tmp.path)])
        let c = ReviewController(nvim: nvim, margin: margin)
        controller = c
        nvim.notify("taudot_review") { [weak self] _ in self?.mirror() }
        try await c.attach(channel: try await nvim.fetchChannel())
        mirror()
      } catch {
        FileHandle.standardError.write("ReviewHost: \(error)\n".data(using: .utf8)!)
      }
    }
  }

  /// Show Neovim's buffer in the text view (read-only mirror), keeping the scroll position.
  func mirror() {
    guard let nvim else { return }
    Task { @MainActor in
      guard let v = try? await nvim.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", []), case let .string(s) = v else { return }
      if s != text.string {
        let sel = text.selectedRange()
        let origin = geometry.scroll.contentView.bounds.origin
        text.string = s
        text.setSelectedRange(NSRange(location: min(sel.location, (s as NSString).length), length: 0))
        geometry.scroll.contentView.scroll(to: origin)
        geometry.reindex()
        geometry.changed()
      }
    }
  }

  func seedSidebar(_ sb: SidebarView, _ st: FakeStore) {
    // --pair: an insertion its author later deleted (the same text): one "added, then removed" card.
    if flag("--pair") {
      let r = ReviewRange(line: 29, col: 0, endLine: 29, endCol: 44)
      let q = "Both extend to paths in $d$ dimensions"
      st.state.items.append(ReviewItem(id: "pi", kind: .insert, author: st.grace, color: "#e0752d", ts: Date().addingTimeInterval(-86400 * 36), quote: q, range: r))
      st.state.items.append(ReviewItem(id: "pd", kind: .delete, author: st.grace, color: "#e0752d", ts: Date().addingTimeInterval(-86400 * 9), quote: q, range: r))
    }
      // --suggestions N: N tracked changes in runs by Ada and Grace (a long review, grouped); --scope all: the overview
    // (this file's items and a second file's); --kinds comments|suggestions.
    if let n = option("--suggestions").flatMap(Int.init) {
      let words = [" clearly", "path", " in fact", "steps", " (see below)", "word", " notably", "count"]
      let now = Date()
      for k in 0..<n {
        let run = k / 4, who = run % 2 == 0 ? st.ada : st.grace
        let line = 12 + (run * 3) % 20 + (k % 4) / 2
        st.state.items.append(ReviewItem(id: "s\(k)", kind: k % 3 == 1 ? .delete : .insert, author: who, color: who == st.ada ? "#2f80ed" : "#e0752d",
                                             ts: now.addingTimeInterval(-Double(run) * 3600 - Double(k % 4) * 60), quote: words[k % words.count],
                                             range: ReviewRange(line: line, col: 4 + (k % 4) * 6, endLine: line, endCol: 9 + (k % 4) * 6)))
      }
      st.state.items.sort { ($0.range.line, $0.range.col) < ($1.range.line, $1.range.col) }
    }
    if let k = option("--kinds") { sb.kinds = k == "comments" ? .comments : k == "suggestions" ? .suggestions : .all }
    if option("--scope") == "file" { sb.scope = .file }
    if option("--scope") == "all" {
      sb.scope = .all
      var ov = st.state.items.map { it in
        OverviewItem(id: it.id, kind: it.kind, threadID: it.threadID, path: "main.tex", line: it.range.line, quote: it.quote, author: it.author,
                     color: it.color, text: it.messages.first?.text ?? "", replies: max(0, it.messages.count - 1), ts: it.messages.last?.ts ?? it.ts,
                     resolved: it.resolved, mine: it.messages.first?.mine ?? false)
      }
      ov.append(OverviewItem(id: "x1", path: "sections/proofs.tex", line: 3, quote: "bijection", author: st.grace, color: "#e0752d",
                             text: "Spell the bijection out once.", replies: 2, ts: Date().addingTimeInterval(-5400)))
      ov.append(OverviewItem(id: "x2", kind: .insert, path: "sections/proofs.tex", line: 9, quote: " for every n", author: st.ada, color: "#2f80ed",
                             ts: Date().addingTimeInterval(-900)))
      sb.overview.items = ov
      if let q = option("--search") { sb.overview.search.stringValue = q; sb.overview.query = q }
    }
  }

  func shot(_ path: String) {
    let id = window.windowNumber
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(id)", path]
    try? p.run()
    p.waitUntilExit()
    print("ReviewHost: wrote \(path)")
    NSApp.terminate(nil)
  }

  func applicationWillTerminate(_ n: Notification) {
    nvim?.stop()
    mock?.terminate()
    if let tmp { try? FileManager.default.removeItem(at: tmp) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

enum ReviewHostLua {
  static let setup = """
  local rtp, folder = ...
  vim.opt.rtp:prepend(rtp)
  vim.cmd('runtime plugin/taudot.lua')
  vim.o.termguicolors = true
  require('taudot').setup({})
  vim.cmd.edit(folder .. '/main.tex')
  require('taudot').open(folder)
  return true
  """
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let host = Host()
app.delegate = host
app.run()
