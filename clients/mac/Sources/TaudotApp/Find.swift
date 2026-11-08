// The find bar in a project window (TaudotEditor/Find): ⌘F, ⌥⌘F, ⌘G / ⇧⌘G from the Edit menu, `/` and `?` from
// Neovim (find.lua) or the native editor's Vim mode, and the current match shown in the PDF.
import AppKit
import TaudotEditor
import TaudotNeovim
import TaudotShared

extension ProjectWindow {
  /// Made with the window (both editors' views exist then); Neovim's side attaches in start().
  func installFind() {
    let target: FindTarget
    if let native {
      let t = NativeFindTarget(editor: native.view)
      target = t
      native.view.onFindEscape = { [weak self] in
        guard let f = self?.find, f.isOpen else { return false }
        f.close()
        return true
      }
      native.view.onVimSearchKey = { [weak self] c in
        guard let self, let f = self.find else { return false }
        self.findAppearance()
        f.open(backward: c == "?", vim: true)
        return true
      }
    } else {
      let t = NeovimFindTarget(bridge: nvim, responder: editor)
      t.onOpenRequest = { [weak self] backward in self?.findAppearance(); self?.find?.open(backward: backward, vim: true) }
      target = t
    }
    let f = FindController(target: target)
    f.install(in: editorHost)
    f.onCount = { [weak self] c in self?.findCountChanged(c) }
    find = f
    if let c = ProcessInfo.processInfo.environment["TAUDOT_FINDCHECK"] { Task { await FindCheck(self, out: URL(fileURLWithPath: c)).run() } }
  }

  /// Neovim: / and ? open the bar from now on.
  func attachFind(channel: Int) async {
    await (find?.target as? NeovimFindTarget)?.attach(channel: channel)
  }

  /// The bar follows the editor's colours: dark glass over a dark theme even in a light app.
  func findAppearance() {
    let bg = native?.view.style.theme.bg ?? editor.ui.defaultBg
    let r = Double((bg >> 16) & 0xff), g = Double((bg >> 8) & 0xff), b = Double(bg & 0xff)
    let dark = (0.299 * r + 0.587 * g + 0.114 * b) / 255 < 0.5
    find?.bar.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
  }

  /// The current match, a moment after it settles: the PDF shows its line (a deliberate jump: the band flashes).
  func findCountChanged(_ c: FindCount) {
    findPDFTimer?.invalidate()
    guard c.total > 0, c.error == nil, !pdf.view.isHidden else { return }
    let t = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.find?.isOpen == true else { return }
        if let native = self.native {
          guard let p = native.current else { return }
          let (l, col) = native.view.lineCol(native.view.caret)
          self.pdf.cursorMoved(path: p, line: l + 1, column: col, deliberate: true)
        } else {
          self.nvim.send("nvim_exec_lua", [.string("local a = package.loaded['taudot.app']; if a then a.deliberate = true; a.cursor(false) end"), .array([])])
        }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    findPDFTimer = t
  }

  @objc func findShow(_ sender: Any?) {
    findAppearance()
    find?.open(prefill: findSelection())
  }

  @objc func findReplace(_ sender: Any?) {
    findAppearance()
    find?.open(replace: true, prefill: findSelection())
  }

  @objc func findNext(_ sender: Any?) { findAppearance(); find?.step(forward: true) }
  @objc func findPrevious(_ sender: Any?) { findAppearance(); find?.step(forward: false) }

  /// ⌘F in the native editor with a selection on one line: search for it (as Mac editors do).
  func findSelection() -> String? {
    guard let tv = native?.view.textView, window.firstResponder === tv else { return nil }
    let r = tv.selectedRange()
    guard r.length > 0, r.length < 200 else { return nil }
    return (tv.string as NSString).substring(with: r)
  }
}
