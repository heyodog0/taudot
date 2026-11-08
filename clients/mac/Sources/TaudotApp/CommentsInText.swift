// View ▸ Comments in the Text (⌥⌘K), the comments sidebar's eye: comments shown in the editor or not, remembered.
// Hidden: no comment tints, no end-of-line notes, no floating card at the cursor, in both editor modes; the sidebar's
// list, its cards and the PDF's comments still work. Settings ▸ Comments ▸ Floating card at the cursor turns only
// the floating card off.
import AppKit
import TaudotNeovim

extension TaudotSettings {
  static let commentsHiddenKey = "taudot.comments.hiddenInText"
  /// Comments hidden in the editor's text (View ▸ Comments in the Text).
  var commentsHiddenInText: Bool {
    get { defaults.object(forKey: Self.commentsHiddenKey) as? Bool ?? false }
    set {
      defaults.set(newValue, forKey: Self.commentsHiddenKey)
      NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["key": Self.commentsHiddenKey])
    }
  }
}

extension ProjectWindow {
  @objc func toggleCommentsInText(_ sender: Any?) {
    TaudotSettings.shared.commentsHiddenInText.toggle()
  }

  /// The setting applied to this window (applySettings, on every change).
  func applyCommentsInText() {
    let s = TaudotSettings.shared
    let hidden = s.commentsHiddenInText
    margin.inlineHidden = hidden
    margin.floatingEnabled = s.floatingCards
    sidebar.inlineHidden = hidden
    if let native {
      native.inlineHidden = hidden
    } else if editorStarted {
      // Neovim: the end-of-line notes are the plugin's `inline` option, which gui.lua's margin_shown parks in
      // inline_saved while the margin shows; the wanted value goes wherever it lives now.
      let lua = """
        local hidden = ...
        local ok, g = pcall(require, 'taudot.gui')
        local o = require('taudot.config').options
        if ok and g.inline_saved ~= nil then g.inline_saved = not hidden else o.inline = not hidden end
        o.comments_hidden = hidden
        local ui, Buffer = require('taudot.ui'), require('taudot.buffer')
        for _, b in pairs(Buffer.by_buf) do
          if b.ranges then b.comments = ui.draw_ranges(b.buf, b.ranges, b:pos_mapper()) end
        end
        require('taudot.review').redraw()
        """
      Task { _ = try? await nvim.execLua(lua, [.bool(hidden)]) }
    }
  }
}
