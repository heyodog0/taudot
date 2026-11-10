// The Claude pane: `claude` in a terminal, under the editor column (⌘J). It's a second `nvim --embed` (the user's
// config, so the same font and colours) whose only window is a `:terminal`, drawn by its own EditorView. A second
// Neovim rather than a split in the editor's: a terminal window there would take the cursor from the main text
// window, which the margin's geometry and gui.lua follow, and squeeze the taudot buffer's window.
import AppKit
import TaudotEditor
import TaudotNeovim
import TaudotShared

@MainActor final class ClaudePane {
  let nvim: Neovim
  let view: EditorView
  var exited = false
  var onExit: (() -> Void)?

  /// The command run in the terminal: $TAUDOT_CLAUDE (tests), else `claude`.
  static var command: String { ProcessInfo.processInfo.environment["TAUDOT_CLAUDE"] ?? "claude" }

  let folder: URL
  let env: [String: String]
  /// Where claude runs (ClaudeSession): its socket and how it was found or started; nil: a plain terminal of this
  /// pane's own (tau-attach missing, or claude isn't on PATH).
  private(set) var session: (sock: String, how: ClaudeSession.How)?

  init(folder: URL, env: [String: String]) throws {
    self.folder = folder
    self.env = env
    nvim = try Neovim(args: [], cwd: folder, env: env)
    view = EditorView(nvim: nvim, frame: NSRect(x: 0, y: 0, width: 600, height: 240))
    view.focused = false
    view.typingResumesTerminal = true
    nvim.onExit = { [weak self] in self?.exited = true; self?.onExit?() }
  }

  /// Attach, then run the command in a terminal filling the only window (or a one-line note if it isn't on PATH).
  func start() async throws {
    try await view.attach()
    for _ in 0..<250 {
      if (try? await nvim.execLua("return vim.v.vim_did_enter == 1", [])) == .bool(true) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let chan = try await nvim.channelID()
    // claude behind tau-attach (in Rex, or started here), outliving Taudot; the terminal attaches to it
    let command = Self.command, folder = folder, env = env, inRex = TaudotSettings.shared.claudeInRex
    let found = Self.executable(command, env: env)
      ? await Task.detached { ClaudeSession.ensure(folder: folder, command: command, env: env, inRex: inRex) }.value : nil
    session = found
    if ClaudeSession.isTest, ProcessInfo.processInfo.environment["TAUDOT_CLAUDE_KEEP"] == nil, let pid = await claudePid() { ClaudeSession.endWithUs(pid) }
    var run = command
    if let found, let t = ClaudeSession.tool { run = Self.quote(t) + " attach " + Self.quote(found.sock) }
    _ = try await nvim.execLua(Self.lua, [.string(run), .int(Int64(chan)), .string(command)])
    nvim.notify("taudot_claude_exit") { [weak self] _ in self?.exited = true; self?.onExit?() }
  }

  /// Type `text` at the prompt (no Return): written to the terminal's input as if typed. Waits (≤ 5 s) for the
  /// program to have drawn something, so it reads the input once it's ready.
  func type(_ text: String) async {
    for _ in 0..<100 {
      if (try? await nvim.execLua("return #table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '') > 0", [])) == .bool(true) { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    _ = try? await nvim.execLua("""
      local job = vim.b.taudot_claude_job
      if job then vim.api.nvim_chan_send(job, ...) end
      vim.cmd('startinsert')
      """, [.string(text)])
  }

  /// claude's own pid (behind tau-attach), to check a reopen reattached to the same one.
  func claudePid() async -> Int? {
    guard let sock = session?.sock else { return nil }
    return await Task.detached { ClaudeSession.pid(sock) }.value
  }

  /// The command's program is on PATH (the login environment's): else the pane shows how to install claude.
  static func executable(_ command: String, env: [String: String]) -> Bool {
    guard let prog = command.split(separator: " ").first.map(String.init) else { return false }
    if prog.contains("/") { return FileManager.default.isExecutableFile(atPath: prog) }
    let path = env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(prog)") }
  }

  static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  /// The terminal's job and its process, to check a toggle kept the same session.
  func job() async -> (job: Int, pid: Int)? {
    guard let a = (try? await nvim.execLua("local j = vim.b.taudot_claude_job; return j and {j, vim.fn.jobpid(j)} or nil", []))?.array,
          a.count == 2, let j = a[0].int, let p = a[1].int else { return nil }
    return (j, p)
  }

  func text() async -> String {
    (try? await nvim.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", []))?.string ?? ""
  }

  /// The pane goes (the window closes, Taudot quits): claude keeps running behind tau-attach, except a test's.
  func stop() async {
    if ClaudeSession.isTest, ProcessInfo.processInfo.environment["TAUDOT_CLAUDE_KEEP"] == nil, let pid = await claudePid() {
      kill(pid_t(pid), SIGTERM)
    }
    _ = await nvim.quit { _, _ in .discard }
  }

  static let lua = """
  local cmd, chan, check = ...
  local o = vim.o
  o.laststatus = 0; o.cmdheight = 0; o.showtabline = 0; o.ruler = false; o.showmode = false
  local function plain()
    local wo = vim.wo
    wo.number = false; wo.relativenumber = false; wo.signcolumn = 'no'; wo.foldcolumn = '0'
    wo.statuscolumn = ''; wo.cursorline = false; wo.spell = false; wo.list = false
    wo.colorcolumn = ''; wo.fillchars = 'eob: '
  end
  vim.cmd('enew')
  if vim.fn.executable(vim.split(check or cmd, ' ')[1]) == 0 then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "  claude isn't on PATH. Install Claude Code:  curl -fsSL https://claude.ai/install.sh | bash   (then ⌘J again)" })
    vim.bo.modified = false; vim.bo.buftype = 'nofile'
    plain()
    vim.b.taudot_claude_missing = true
    return
  end
  -- A taudot started from inside a Claude Code session must not make this one its child (no transcripts, etc.).
  for k in pairs(vim.fn.environ()) do
    if k == 'CLAUDECODE' or k:match('^CLAUDE_CODE_') then vim.env[k] = nil end
  end
  vim.cmd.terminal(cmd)
  plain()
  -- Every key goes straight to claude: the user's terminal-mode mappings (e.g. `<Space>j`) would make Space wait
  -- 'timeoutlen' for the rest of the mapping. This Neovim only hosts the pane, so they're dropped here.
  for _, m in ipairs(vim.api.nvim_get_keymap('t')) do pcall(vim.keymap.del, 't', m.lhs) end
  vim.o.ttimeoutlen = 0
  -- Mac text-editing keys, as Terminal/iTerm/Ghostty send them to a shell or Claude Code's prompt.
  local job = vim.b.terminal_job_id
  local function send(seq) return function() vim.api.nvim_chan_send(job, seq) end end
  for lhs, seq in pairs({
    ['<D-BS>'] = '\\21',        -- ⌘⌫: delete to the start of the line (Ctrl-U)
    ['<M-BS>'] = '\\27\\127',    -- ⌥⌫: delete the word before (Esc DEL)
    ['<D-Left>'] = '\\1',       -- ⌘←: start of line (Ctrl-A)
    ['<D-Right>'] = '\\5',      -- ⌘→: end of line (Ctrl-E)
    ['<M-Left>'] = '\\27b',     -- ⌥←: word left
    ['<M-Right>'] = '\\27f',    -- ⌥→: word right
    ['<D-k>'] = '\\12',         -- ⌘K: clear (Ctrl-L)
  }) do vim.keymap.set('t', lhs, send(seq), { buffer = 0 }) end
  vim.b.taudot_claude_job = vim.b.terminal_job_id
  vim.api.nvim_create_autocmd('TermClose', { buffer = 0, callback = function()
    vim.rpcnotify(chan, 'taudot_claude_exit')
  end })
  -- Back in the pane: straight to the prompt.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'FocusGained' }, { buffer = 0, command = 'startinsert' })
  vim.cmd('startinsert')
  """
}

extension ProjectWindow {
  var claudeShown: Bool { claude.map { !$0.view.isHidden } ?? false && !claudeFading }

  /// ⌘J: start the pane; then show and focus it, or hide it when it has the focus. The session keeps running.
  @objc func toggleClaude(_ sender: Any?) {
    if claudeShown && focusedPane == 3 {
      setClaude(shown: false)
      focus(pane: 1)
    } else {
      focus(pane: 3)
    }
  }

  /// ⌘L: `@path#La-b` for the Visual selection (or the cursor's line) at the Claude pane's prompt, focused, no Return.
  @objc func askClaude(_ sender: Any?) {
    Task {
      let ref: String? = if let native { nativeRef(native) } else { (try? await nvim.execLua(Self.refLua, []))?.string }
      guard let v = ref else { return }
      focus(pane: 3)
      try? await Task.sleep(for: .milliseconds(10))
      await claude?.type(v + " ")
    }
  }

  /// ⌘L in the native editor: the selection's lines (or the caret's).
  func nativeRef(_ ed: NativeEditor) -> String? {
    guard var path = ed.current else { return nil }
    if path.hasPrefix(folder.path + "/") { path = String(path.dropFirst(folder.path.count + 1)) }
    let tv = ed.view.textView, s = tv.string as NSString, r = tv.selectedRange()
    func line(_ loc: Int) -> Int {
      var n = 1
      let end = min(loc, s.length)
      var i = 0
      while i < end { let f = s.range(of: "\n", range: NSRange(location: i, length: end - i)); if f.location == NSNotFound { break }; n += 1; i = f.location + 1 }
      return n
    }
    let a = line(r.location), b = r.length > 0 ? line(r.location + r.length - 1) : a
    return "@" + path + "#L\(a)" + (b != a ? "-\(b)" : "")
  }

  /// The reference for ⌘L, relative to the project folder; leaves Visual mode.
  static let refLua = """
  local m = vim.fn.mode()
  local a, b = vim.fn.line('.'), vim.fn.line('.')
  if m == 'v' or m == 'V' or m == '\\22' then
    a, b = vim.fn.line('v'), vim.fn.line('.')
    if a > b then a, b = b, a end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ':.')
  if path == '' then return nil end
  return '@' .. path .. '#L' .. a .. (b ~= a and ('-' .. b) or '')
  """

  /// Docked (a split under the editor) or floating (a glass panel over it, the default). View ▸ Claude, or
  /// double-click the panel's top strip to dock. TAUDOT_CLAUDE_MODE=docked|floating overrides it for a run.
  var claudeDocked: Bool {
    get {
      if let m = ProcessInfo.processInfo.environment["TAUDOT_CLAUDE_MODE"] { return m == "docked" }
      return UserDefaults.standard.bool(forKey: "taudot.claudeDocked")
    }
    set { if !backgroundRun { UserDefaults.standard.set(newValue, forKey: "taudot.claudeDocked") } }
  }

  @objc func setClaudeFloating(_ sender: Any?) { morphClaude(docked: false) }
  @objc func setClaudeDocked(_ sender: Any?) { morphClaude(docked: true) }

  /// Dock / undock with the panel's frame morphing between the floating place and the docked split's (~220 ms).
  func morphClaude(docked: Bool) {
    guard docked != dockedNow, let c = claude, claudeShown, !reduceMotion, zoom == nil else { setClaudeMode(docked: docked); return }
    let dockRect: NSRect = {
      let b = editorBox.bounds, h = min(max(claudeHeight, 80), b.height - 120)
      return NSRect(x: 0, y: editorBox.isFlipped ? b.height - h : 0, width: b.width, height: h)
    }()
    // Overtaken (another morph, a mode change, ⌘J: each bumps claudeGen) its end only lets go of the grid (A15).
    claudeGen += 1
    let gen = claudeGen
    c.view.holdGridSize = true
    if docked {
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        claudeFloat.animator().frame = dockRect
      }, completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          c.view.holdGridSize = false
          guard let self, self.claudeGen == gen else { return }
          self.setClaudeMode(docked: true)
        }
      })
    } else {
      setClaudeMode(docked: false)
      claudeFloat.frame = dockRect
      claudeFloat.layer?.removeAllAnimations()
      let to = claudeFloat.frameFor(editorBox.bounds)
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        claudeFloat.animator().frame = to
      }, completionHandler: { MainActor.assumeIsolated { c.view.holdGridSize = false } })
    }
  }

  /// Move the terminal between the column split and the floating panel, keeping it shown or hidden and focused.
  func setClaudeMode(docked: Bool) {
    if zoom != nil { unzoom(animated: false) }
    dockedNow = docked
    claudeDocked = docked
    guard let c = claude else { return }
    let shown = claudeShown, hadFocus = focusedPane == 3
    claudeGen += 1  // (a fade running ends here)
    claudeFading = false
    c.view.isHidden = true
    claudeFloat.isHidden = true
    column.adjustSubviews()
    place(c)
    if shown { setClaude(shown: true) }
    if hadFocus { focus(pane: 3) }
  }

  /// Put the terminal view in its host for the current mode.
  func place(_ c: ClaudePane) {
    c.view.removeFromSuperview()
    if dockedNow {
      column.addArrangedSubview(c.view)
      column.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
    } else {
      c.view.frame = claudeFloat.content.bounds
      c.view.autoresizingMask = [.width, .height]
      claudeFloat.content.addSubview(c.view)
    }
  }

  /// The floating panel's frame: its remembered place in the column, or the whole column while it's zoomed.
  func layoutClaudeFloat() {
    guard !claudeFloat.isHidden else { return }
    if editorHost.isHidden { claudeFloat.frame = editorBox.bounds } else { claudeFloat.layoutIn(editorBox.bounds) }
  }

  /// Show or hide the pane, starting it the first time.
  func setClaude(shown: Bool) {
    if shown && (claude == nil || claude!.exited) { startClaude() }
    // Against what the pane is (a fading panel counts as hidden), not whether its view is still up (A1: ⌘J again
    // during the fade shows it again).
    guard let c = claude, claudeShown != shown else { return }
    // A fade still running is stale from here: its completion must not hide what this shows.
    claudeGen += 1
    claudeFading = false
    // The keys never stay in a pane on its way out.
    if !shown, window.firstResponder === c.view { focusedPane = 1; giveEditorKeys() }
    if !dockedNow {
      if shown {
        claudeFloat.layer?.removeAllAnimations()
        c.view.isHidden = false
        claudeFloat.isHidden = false
        c.view.frame = claudeFloat.content.bounds
        layoutClaudeFloat()
        claudeFloat.appear(reduce: reduceMotion)
      } else {
        claudeFading = true
        let gen = claudeGen
        claudeFloat.disappear(reduce: reduceMotion) { [weak self, weak c] in
          guard let self, self.claudeFading, self.claudeGen == gen else { return }
          self.claudeFading = false
          c?.view.isHidden = true
          self.claudeFloat.isHidden = true
          self.claudeFloat.layer?.removeAllAnimations()
          self.updateFocusLine(animated: false)
        }
      }
      updateFocusLine(animated: false)
      return
    }
    if shown {
      c.view.isHidden = false
      column.adjustSubviews()
      let h = min(max(claudeHeight, 80), column.bounds.height - 120)
      column.setPosition(column.bounds.height - h - column.dividerThickness, ofDividerAt: 0)
    } else {
      c.view.isHidden = true
      column.adjustSubviews()
    }
    updateFocusLine(animated: false)
  }

  func startClaude() {
    if let old = claude { old.view.removeFromSuperview(); Task { await old.stop() } }
    do {
      let c = try ClaudePane(folder: folder, env: ProjectWindow.environment())
      c.view.isHidden = true
      place(c)
      // Esc twice (within 0.35 s) leaves the pane for the editor; the first Esc still reaches claude.
      c.view.onKeyDown = { [weak self] e in
        guard let self, e.keyCode == 53, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let now = e.timestamp
        defer { self.lastClaudeEsc = now }
        if now - self.lastClaudeEsc < 0.35 { self.lastClaudeEsc = 0; self.focus(pane: 1); return true }
        return false
      }
      c.onExit = { [weak self, weak c] in
        guard let self, let c, self.claude === c else { return }
        if self.focusedPane == 3 { self.focus(pane: 1) }
        self.setClaude(shown: false)
      }
      claude = c
      Task { do { try await c.start() } catch { status.note("claude: \(error)") } }
    } catch {
      status.note("claude: \(error)")
    }
  }

  /// The pane's height, remembered for every project.
  var claudeHeight: CGFloat {
    get { CGFloat(UserDefaults.standard.double(forKey: "taudot.claudeHeight")).nonZero ?? 260 }
    set { if !backgroundRun { UserDefaults.standard.set(Double(newValue), forKey: "taudot.claudeHeight") } }
  }
}

extension CGFloat { var nonZero: CGFloat? { self == 0 ? nil : self } }

extension ProjectWindow: NSMenuItemValidation {
  /// View ▸ Claude ▸ Floating / Docked carry a check mark for the current mode.
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(setClaudeFloating(_:)): item.state = dockedNow ? .off : .on
    case #selector(setClaudeDocked(_:)): item.state = dockedNow ? .on : .off
    case #selector(findNext(_:)), #selector(findPrevious(_:)): return find?.bar.query.text.isEmpty == false
    case #selector(togglePDFComments(_:)): item.state = pdf.showComments ? .on : .off
    case #selector(toggleCommentsInText(_:)): item.state = TaudotSettings.shared.commentsHiddenInText ? .off : .on
    case #selector(reviewShow(_:)): item.state = sidebar.kinds.rawValue == item.tag ? .on : .off
    case #selector(reviewPreview(_:)):
      let m = review?.previewMode ?? "off"
      item.state = (item.tag == 11 && m == "accepted") || (item.tag == 12 && m == "rejected") || (item.tag == 10 && m == "off") ? .on : .off
    default: break
    }
    return true
  }
}
