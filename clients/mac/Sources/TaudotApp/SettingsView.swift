// Settings ▸ every page, in Rex's language on Liquid Glass in the Taudot palette (docs/agents/shell-settings-style.md,
// option B): a floating glass sidebar over a teal ground (traffic lights inside it, a capsule search, coloured
// squircle icons, the selection a lit glass capsule as in the Files tab); on the right a glass back/forward capsule
// and a bold title, bold headings over glass-tinted cards with hairline separators, a live preview card at the top of
// a section (solid inside, so it stays legible), label left / control right, glass capsule buttons, lime (dark) or
// teal (light) switches. Coral is never a control: it means "you". Reduce Transparency (or
// TAUDOT_REDUCE_TRANSPARENCY=1) draws solid fills with a hairline instead of glass.
import AppKit
import SwiftUI
import TaudotNeovim
import TaudotPDF
import TaudotShared

/// Settings' palette is Taudot's (TaudotShared/TaudotPalette.swift), shared with the Projects window.
typealias SettingsPalette = TaudotPalette

/// The sidebar's squircle icons: two-stop gradients from the palette's hues.
let settingsTiles: [SettingsSection: (Color, Color)] = [
  .appearance: (Color(taudot: 0x2fbf9f), Color(taudot: 0x0f5a5c)), .editor: (Color(taudot: 0xe2ff8a), Color(taudot: 0x8fcf3a)),
  .pdf: (Color(taudot: 0x6fd3c0), Color(taudot: 0x1f8f86)), .comments: (Color(taudot: 0x2a8a8c), Color(taudot: 0x0c4752)),
  .account: (Color(taudot: 0x9fb3b0), Color(taudot: 0x56706d)),
]

// MARK: - the window

struct SettingsView: View {
  @ObservedObject var model: SettingsModel
  @Environment(\.colorScheme) var scheme
  var p: SettingsPalette { .make(dark: scheme == .dark) }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .taudotGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: p.panel, fill: p.panelSolid, rim: p.rim)
        .padding(8)
      content
    }
    .background(TaudotGround(p))
    .ignoresSafeArea()
    .foregroundStyle(p.text)
    .tint(p.accent)
    .frame(minWidth: 820, minHeight: 600)
  }

  var sections: [SettingsSection] {
    let q = model.search.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return SettingsSection.allCases }
    return SettingsSection.allCases.filter { ($0.rawValue + " " + $0.keywords).lowercased().contains(q) }
  }

  var sidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      Spacer().frame(height: 40)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(p.secondary)
        TextField("Search Settings", text: $model.search).textFieldStyle(.plain).foregroundStyle(p.text)
          .onSubmit { if let s = sections.first { model.go(s) } }
      }
      .font(.system(size: 13))
      .padding(.horizontal, 12).frame(height: 32)
      .background(Capsule().fill(p.search))
      .padding(.horizontal, 10).padding(.bottom, 10)
      ForEach(sections) { s in
        let on = model.section == s
        HStack(spacing: 10) {
          let t = settingsTiles[s] ?? (.gray, .gray)
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [t.0, t.1], startPoint: .top, endPoint: .bottom))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: s.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(s == .editor ? Color(taudot: 0x0b2a30) : .white))
            .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
          Text(s.rawValue).font(.system(size: 13.5, weight: on ? .semibold : .regular))
          Spacer()
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background {
          if on { Color.clear.taudotGlass(Capsule(), tint: p.selected, fill: p.selected, rim: p.rim.opacity(0.6)) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(s) }
        .padding(.horizontal, 8)
      }
      Spacer()
      HStack(spacing: 6) {
        TaudotMark(dot: TaudotMark.coral).foregroundStyle(p.secondary).frame(width: 18, height: 14)
        Text("Taudot").font(.system(size: 11)).foregroundStyle(p.secondary)
      }
      .padding(.horizontal, 18).padding(.bottom, 14)
    }
  }

  var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 14) {
        HStack(spacing: 0) {
          Button { model.goBack() } label: { Image(systemName: "chevron.left").frame(width: 34, height: 32) }
            .buttonStyle(.plain).disabled(model.back.isEmpty).opacity(model.back.isEmpty ? 0.45 : 1)
          Rectangle().fill(p.separator).frame(width: 1, height: 18)
          Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 34, height: 32) }
            .buttonStyle(.plain).disabled(model.forward.isEmpty).opacity(model.forward.isEmpty ? 0.45 : 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .taudotGlass(Capsule(), tint: p.capsule, fill: p.capsuleSolid, rim: p.rim, interactive: true)
        Text(model.section.rawValue).font(.system(size: 19, weight: .bold))
      }
      .padding(.leading, 12).padding(.top, 12).frame(height: 56, alignment: .center)
      ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          switch model.section {
          case .appearance: AppearancePage(model: model, p: p)
          case .editor: EditorPage(model: model, p: p)
          case .pdf: PDFPage(model: model, p: p)
          case .comments: CommentsPage(model: model, p: p)
          case .account: AccountPage(p: p)
          }
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 24)
        Color.clear.frame(height: 1).id("end")
      }
      // each page opens at its top, and a scrolled page stays inside its frame: without the clip it drew up under the
      // transparent toolbar, over the title and the ‹ › capsule ("Typography" over "Editor", uifix-shots/settings-overlap.png)
      .id(model.section)
      .clipped()
      .onChange(of: model.testScroll) { proxy.scrollTo("end", anchor: .bottom) }
      }
    }
  }
}

// MARK: - parts

struct Heading: View {
  let title: String
  var body: some View { Text(title).font(.system(size: 15, weight: .bold)).padding(.top, 14).padding(.leading, 4) }
}

/// A grouped card: glass tinted over the teal ground, rows separated by hairlines, soft depth.
struct Card<Content: View>: View {
  let p: SettingsPalette
  @ViewBuilder let content: Content
  var body: some View {
    VStack(spacing: 0) { content }
      .padding(.horizontal, 16).padding(.vertical, 4)
      .taudotGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: p.card, fill: p.cardSolid, rim: p.rim.opacity(0.7))
      .shadow(color: .black.opacity(p.dark ? 0.25 : 0.06), radius: 10, y: 4)
  }
}

struct Row<Control: View>: View {
  let p: SettingsPalette
  let label: String
  var note: String? = nil
  var last = false
  @ViewBuilder let control: Control
  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label).font(.system(size: 13.5))
          if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(p.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        Spacer(minLength: 16)
        control
      }
      .padding(.vertical, note == nil ? 11 : 10)
      if !last { Rectangle().fill(p.separator).frame(height: 1) }
    }
  }
}

/// The accent when on (lime in the dark, teal in the light), a dim track and a light knob when off.
struct Switch: View {
  let p: SettingsPalette
  @Binding var on: Bool
  var body: some View {
    ZStack(alignment: on ? .trailing : .leading) {
      Capsule().fill(on ? p.accent : p.switchOff).frame(width: 40, height: 22)
      Circle().fill(on ? (p.dark ? p.onAccent : .white) : p.knobOff).frame(width: 18, height: 18).padding(2)
        .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
    }
    .contentShape(Capsule())
    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { on.toggle() } }
    .accessibilityElement().accessibilityAddTraits(.isButton).accessibilityValue(on ? "on" : "off")
  }
}

/// The value and a glass ⌃⌄ circle; the menu is `items`.
struct Popup<Items: View>: View {
  let p: SettingsPalette
  let value: String
  @ViewBuilder let items: Items
  var body: some View {
    Menu { items } label: {
      HStack(spacing: 10) {
        Text(value).font(.system(size: 13.5)).foregroundStyle(p.text)
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text)
          .frame(width: 22, height: 22)
          .taudotGlass(Circle(), tint: p.capsule, fill: p.capsuleSolid, rim: p.rim)
      }
      .contentShape(Rectangle())
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
  }
}

/// A glass capsule button ("Choose…", "Import…").
struct GlassButton: View {
  let p: SettingsPalette
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 13)).foregroundStyle(p.text).padding(.horizontal, 14).frame(height: 28)
        .taudotGlass(Capsule(), tint: p.capsule, fill: p.capsuleSolid, rim: p.rim, interactive: true)
    }
    .buttonStyle(.plain)
  }
}

/// A glass capsule that opens a menu (the font's "Choose…").
struct GlassMenuButton<Items: View>: View {
  let p: SettingsPalette
  let title: String
  @ViewBuilder let items: Items
  var body: some View {
    Menu { items } label: {
      Text(title).font(.system(size: 13)).foregroundStyle(p.text).padding(.horizontal, 14).frame(height: 28)
        .taudotGlass(Capsule(), tint: p.capsule, fill: p.capsuleSolid, rim: p.rim, interactive: true)
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
  }
}

/// A number in a small field with ⌃⌄ and a unit after it.
struct NumberField: View {
  let p: SettingsPalette
  let text: String
  let unit: String
  let up: () -> Void
  let down: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Text(text).font(.system(size: 13.5).monospacedDigit()).frame(minWidth: 34, alignment: .trailing)
        VStack(spacing: 0) {
          Button(action: up) { Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 10) }
          Button(action: down) { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 10) }
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8).frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.search))
      .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.rim.opacity(0.8), lineWidth: 1))
      Text(unit).foregroundStyle(p.secondary).font(.system(size: 13))
    }
  }
}

/// A row of colour dots (the accent), the chosen one ringed.
struct Swatches: View {
  let p: SettingsPalette
  let options: [(key: String, color: Color, name: String)]
  @Binding var value: String
  var body: some View {
    HStack(spacing: 9) {
      ForEach(options, id: \.key) { o in
        Circle().fill(o.color).frame(width: 18, height: 18)
          .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
          .padding(3)
          .overlay(Circle().strokeBorder(p.text.opacity(value == o.key ? 0.9 : 0), lineWidth: 2))
          .onTapGesture { value = o.key }
          .help(o.name)
      }
    }
  }
}

// MARK: - Appearance

struct AppearancePage: View {
  @ObservedObject var model: SettingsModel
  let p: SettingsPalette
  var body: some View {
    let look = model.bind({ $0.appearance }, { $0.appearance = $1 })
    let accent = model.bind({ $0.accent }, { $0.accent = $1 })
    Heading(title: "Look")
    Card(p: p) {
      HStack(spacing: 14) {
        ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { k, name in
          VStack(spacing: 6) {
            LookThumb(kind: k).frame(width: 120, height: 76)
              .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(look.wrappedValue == k ? p.accent : p.previewStroke, lineWidth: look.wrappedValue == k ? 2.5 : 1))
            Text(name).font(.system(size: 12, weight: look.wrappedValue == k ? .semibold : .regular))
          }
          .contentShape(Rectangle())
          .onTapGesture { look.wrappedValue = k }
        }
        Spacer()
      }
      .padding(.vertical, 14)
      Rectangle().fill(p.separator).frame(height: 1)
      Row(p: p, label: "Accent", note: "Selections and highlights in the app. The editor's colours are under Editor.", last: true) {
        Swatches(p: p, options: [("system", Color(nsColor: .controlAccentColor), "System")]
                   + TaudotSettings.accents.map { ($0.hex, Color(nsColor: MarkColor.color(hex: $0.hex)!), $0.name) },
                 value: accent)
      }
    }
  }
}

/// A tiny window in light, dark, or (System) the same window split down the middle: light on the left, dark on the
/// right, both clipped to the thumbnail's rounded rect.
struct LookThumb: View {
  let kind: String
  var body: some View {
    ZStack {
      pane(light: kind != "dark")
      if kind == "system" {
        pane(light: false).mask(HStack(spacing: 0) { Color.clear; Color.black })
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
  func pane(light: Bool) -> some View {
    ZStack(alignment: .topLeading) {
      (light ? Color(taudot: 0xf3f8f6) : Color(taudot: 0x0a2a30))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 3) { ForEach([0xff5f57, 0xfebc2e, 0x28c840], id: \.self) { Circle().fill(Color(taudot: UInt32($0))).frame(width: 5, height: 5) } }
        RoundedRectangle(cornerRadius: 2).fill(light ? Color(taudot: 0x0b2a30, 0.25) : Color.white.opacity(0.3)).frame(width: 46, height: 5)
        RoundedRectangle(cornerRadius: 2).fill(light ? Color(taudot: 0x0b2a30, 0.15) : Color.white.opacity(0.18)).frame(width: 70, height: 5)
        RoundedRectangle(cornerRadius: 2).fill(Color(taudot: 0x2fbf9f)).frame(width: 30, height: 5)
      }
      .padding(8)
    }
  }
}

// MARK: - Editor

struct EditorPage: View {
  @ObservedObject var model: SettingsModel
  let p: SettingsPalette

  var body: some View {
    let theme = model.bind({ $0.editorTheme }, { $0.editorTheme = $1 })
    let family = model.bind({ $0.fontFamily }, { $0.fontFamily = $1 })
    let size = model.bind({ $0.fontSize }, { $0.fontSize = $1 })
    let ls = model.bind({ $0.lineSpace }, { $0.lineSpace = $1 })
    let width = model.bind({ $0.maxTextWidth }, { $0.maxTextWidth = $1 })
    let mode = model.bind({ $0.editorMode }, { $0.editorMode = $1 })
    let current = Theme.named(theme.wrappedValue)
    Heading(title: "Typography")
    Card(p: p) {
      LaTeXPreview(theme: current, family: family.wrappedValue.isEmpty ? "Menlo" : family.wrappedValue,
                   size: size.wrappedValue > 0 ? size.wrappedValue : 13, lineSpace: max(ls.wrappedValue, 0), stroke: p.previewStroke)
        .padding(.top, 12).padding(.bottom, 6)
      Row(p: p, label: "Font") {
        HStack(spacing: 12) {
          Text(family.wrappedValue.isEmpty ? "From your Neovim config" : family.wrappedValue)
            .font(.system(size: 13.5, design: family.wrappedValue.isEmpty ? .default : .monospaced))
            .foregroundStyle(family.wrappedValue.isEmpty ? p.secondary : p.text)
          GlassMenuButton(p: p, title: "Choose…") {
            Button("From your Neovim config") { family.wrappedValue = "" }
            Divider()
            ForEach(SettingsModel.monoFamilies, id: \.self) { f in Button(f) { family.wrappedValue = f } }
          }
        }
      }
      Row(p: p, label: "Font size", note: size.wrappedValue > 0 ? nil : "From your Neovim config") {
        NumberField(p: p, text: size.wrappedValue > 0 ? String(format: "%g", size.wrappedValue) : "auto", unit: "pt",
                    up: { size.wrappedValue = min(28, (size.wrappedValue > 0 ? size.wrappedValue : 13) + 1) },
                    down: { size.wrappedValue = size.wrappedValue <= 9 ? 0 : max(9, (size.wrappedValue > 0 ? size.wrappedValue : 13) - 1) })
      }
      Row(p: p, label: "Line height", note: "Extra space between lines.") {
        NumberField(p: p, text: ls.wrappedValue >= 0 ? "+\(ls.wrappedValue)" : "auto", unit: "px",
                    up: { ls.wrappedValue = min(16, max(ls.wrappedValue, -1) + 1) },
                    down: { ls.wrappedValue = ls.wrappedValue <= 0 ? -1 : ls.wrappedValue - 1 })
      }
      Row(p: p, label: "Max text width", note: "Soft wrap at this many columns.", last: true) {
        Popup(p: p, value: width.wrappedValue == 0 ? "Window width" : "\(width.wrappedValue) columns") {
          Button("Window width") { width.wrappedValue = 0 }
          ForEach([72, 80, 100, 120], id: \.self) { w in Button("\(w) columns") { width.wrappedValue = w } }
        }
      }
    }
    Heading(title: "Colours")
    Card(p: p) {
      Row(p: p, label: "Theme", note: "The editor's colours. The app and the PDF follow Appearance.") {
        Popup(p: p, value: current?.name ?? "Your Neovim colours") {
          Button("Your Neovim colours") { theme.wrappedValue = Theme.neovimID }
          ForEach(model.themeGroups) { g in
            Section(g.name) { ForEach(g.themes) { t in Button(t.name) { theme.wrappedValue = t.id } } }
          }
        }
      }
      let imported = model.themeGroups.first { $0.name == "Imported" }?.themes.contains { $0.id == theme.wrappedValue } ?? false
      Row(p: p, label: "Import a theme", note: "A Ghostty theme or an iTerm2 .itermcolors file.", last: true) {
        HStack(spacing: 8) {
          if imported, let t = current { GlassButton(p: p, title: "Remove") { model.removeTheme(t) } }
          GlassButton(p: p, title: "Import…") { model.importTheme() }
        }
      }
    }
    Heading(title: "Editing")
    Card(p: p) {
      Row(p: p, label: "Editor", note: "Neovim runs your own config; Native is Taudot's built-in editor. For windows opened from now on.") {
        Popup(p: p, value: mode.wrappedValue == "native" ? "Native" : "Neovim") {
          Button("Neovim") { mode.wrappedValue = "neovim" }
          Button("Native") { mode.wrappedValue = "native" }
        }
      }
      Row(p: p, label: "Vim keys", note: "Normal, insert and visual modes in the native editor.") {
        Switch(p: p, on: model.bind({ $0.vimKeys }, { $0.vimKeys = $1 }))
      }
      Row(p: p, label: "Open windows", note: "Reopen them in the editor chosen above.", last: true) {
        GlassButton(p: p, title: "Reopen") { NSApp.sendAction(#selector(AppDelegate.reopenInEditorMode), to: nil, from: nil) }
      }
    }
  }
}

/// The live preview: a few LaTeX lines in the chosen font, size, line height and theme, on the theme's own
/// background (solid, so it reads the same on glass).
struct LaTeXPreview: View {
  let theme: Theme?
  let family: String
  let size: Double
  var lineSpace = 0
  let stroke: Color
  func c(_ v: UInt32) -> Color { Color(taudot: v) }
  var body: some View {
    let t = theme ?? SettingsModel.neovimTheme
    VStack(alignment: .leading, spacing: 4 + CGFloat(lineSpace)) {
      (Text("\\section").foregroundColor(c(t.command)) + Text("{").foregroundColor(c(t.bracket))
        + Text("Results").foregroundColor(c(t.env)).bold() + Text("}").foregroundColor(c(t.bracket)))
      (Text("We prove ").foregroundColor(c(t.fg)) + Text("$e^{i\\pi} + 1 = 0$").foregroundColor(c(t.math))
        + Text(" in ").foregroundColor(c(t.fg)) + Text("\\cref").foregroundColor(c(t.command))
        + Text("{thm:euler}").foregroundColor(c(t.env)) + Text(".").foregroundColor(c(t.fg)))
      Text("% TODO: tighten the bound").foregroundColor(c(t.comment)).italic()
    }
    .font(.custom(family, size: size + 2))
    .lineLimit(1)
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(c(t.bg)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(stroke, lineWidth: 1))
  }
}

// MARK: - PDF

struct PDFPage: View {
  @ObservedObject var model: SettingsModel
  @AppStorage(EngineChoice.defaultsKey) private var pdfEngine = "auto"
  let p: SettingsPalette
  var body: some View {
    let mark = model.bind({ $0.pdfMarkColor }, { $0.pdfMarkColor = $1 })
    let page = model.bind({ $0.pdfPage }, { $0.pdfPage = $1 })
    let markColor = mark.wrappedValue == "accent" ? Color(nsColor: .controlAccentColor) : Color(nsColor: MarkColor.color(hex: mark.wrappedValue) ?? .controlAccentColor)
    Heading(title: "Highlight")
    Card(p: p) {
      PagePreview(page: page.wrappedValue, mark: markColor, stroke: p.previewStroke).padding(.top, 12).padding(.bottom, 6)
      Row(p: p, label: "Highlight colour", note: "The word and line you jump to (⌘⌥J, a click in the PDF, ]r, a reference).") {
        Popup(p: p, value: MarkColor.presets.first { $0.key == mark.wrappedValue }?.name ?? "Custom") {
          ForEach(MarkColor.presets, id: \.key) { pr in Button(pr.name) { mark.wrappedValue = pr.key } }
        }
      }
      Row(p: p, label: "Highlight follows the cursor", note: "Off: only the coral dot follows you; the highlight shows on jumps until you change line.", last: true) {
        Switch(p: p, on: model.bind({ $0.pdfHighlightFollows }, { $0.pdfHighlightFollows = $1 }))
      }
    }
    Heading(title: "Page")
    Card(p: p) {
      Row(p: p, label: "Page colour") {
        Popup(p: p, value: ["white": "White", "sepia": "Sepia", "dark": "Dark"][page.wrappedValue] ?? "White") {
          Button("White") { page.wrappedValue = "white" }
          Button("Sepia") { page.wrappedValue = "sepia" }
          Button("Dark") { page.wrappedValue = "dark" }
        }
      }
      Row(p: p, label: "Comments on the PDF", note: "Your project's comments as marks on the page (also ⇧⌘K).", last: true) {
        Switch(p: p, on: model.bind({ $0.pdfComments }, { $0.pdfComments = $1 }))
      }
    }
    Heading(title: "Typesetting")
    Card(p: p) {
      Row(p: p, label: "Typeset live",
          note: "The PDF Overleaf would make, line for line, from TeX Live's own engines. Off: every project on TeXpresso, as before.") {
        Switch(p: p, on: Binding(get: { pdfEngine != "texpresso" }, set: { pdfEngine = $0 ? "auto" : "texpresso"; universalChanged() }))
      }
      Row(p: p, label: "XeLaTeX and LuaLaTeX on universal",
          note: "Stock XeTeX and LuaTeX, run live. Off: those projects on TeXpresso.") {
        Switch(p: p, on: Binding(get: { uniUnicode }, set: { uniUnicode = $0; universalChanged() }))
          .disabled(pdfEngine == "texpresso")
      }
      Row(p: p, label: "pdfLaTeX on universal too",
          note: "Stock pdfTeX instead of Taudot's patched one (the default for pdfLaTeX).", last: true) {
        Switch(p: p, on: Binding(get: { uniPdf }, set: { uniPdf = $0; universalChanged() }))
          .disabled(pdfEngine == "texpresso")
      }
    }
    if let folder = project.folder {
      Heading(title: "This project")
      Card(p: p) {
        Row(p: p, label: "Engine",
            note: "\(folder.lastPathComponent). From Overleaf: the project's Compiler setting. \(project.running.map { "Now: \($0)." } ?? "")",
            last: true) {
          let own = UniversalSettings.engine(for: folder)
          let fromOverleaf = "From Overleaf" + (project.engine.map { " (\($0.title))" } ?? "")
          Popup(p: p, value: own?.title ?? fromOverleaf) {
            Button(fromOverleaf) { setEngine(nil, folder) }
            ForEach(TexEngine.allCases, id: \.self) { e in Button(e.title) { setEngine(e, folder) } }
          }
        }
      }
    }
  }

  @AppStorage(UniversalSettings.unicodeKey) private var uniUnicode = true
  @AppStorage(UniversalSettings.pdflatexKey) private var uniPdf = false
  @StateObject private var project = CurrentProjectModel()

  private func universalChanged() { NotificationCenter.default.post(name: UniversalSettings.changed, object: nil) }
  private func setEngine(_ e: TexEngine?, _ folder: URL) {
    UniversalSettings.setEngine(e, for: folder)
    project.refresh()
    universalChanged()
  }
}

/// `CurrentProject` for SwiftUI: the project Settings ▸ PDF talks about, refreshed when it changes.
@MainActor final class CurrentProjectModel: ObservableObject {
  @Published private(set) var folder: URL?
  @Published private(set) var engine: TexEngine?
  @Published private(set) var running: String?
  @Published private var tick = 0
  private var token: NSObjectProtocol?
  init() {
    refresh()
    token = NotificationCenter.default.addObserver(forName: CurrentProject.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }
  func refresh() {
    folder = CurrentProject.folder
    engine = CurrentProject.projectEngine
    running = CurrentProject.running
    tick += 1
  }
}

/// A strip of a page in the chosen page colour: a heading, lines of text, the highlight on a word and its line band,
/// and the coral dot ("you are here").
struct PagePreview: View {
  let page: String
  let mark: Color
  let stroke: Color
  var body: some View {
    let bg: Color = page == "sepia" ? Color(taudot: 0xf4ecd8) : page == "dark" ? Color(taudot: 0x1d1f21) : .white
    let ink: Color = page == "dark" ? Color(taudot: 0xd0d0d0) : Color(taudot: 0x222222)
    VStack(alignment: .leading, spacing: 6) {
      Text("2  Results").font(.custom("Times New Roman", size: 17).bold()).foregroundColor(ink)
      Text("We prove the bound for every n, and it is tight up to a constant.")
        .font(.custom("Times New Roman", size: 14)).foregroundColor(ink)
      HStack(spacing: 0) {
        Text("The proof follows ").foregroundColor(ink)
        Text("Euler").foregroundColor(ink).padding(.horizontal, 2).background(RoundedRectangle(cornerRadius: 2).fill(mark.opacity(0.35)))
        Text("’s identity, with one more step.").foregroundColor(ink)
        Circle().fill(TaudotMark.coral).frame(width: 7, height: 7).padding(.leading, 6)
      }
      .font(.custom("Times New Roman", size: 14))
      .padding(.vertical, 2)
      .background(Rectangle().fill(mark.opacity(0.10)).padding(.horizontal, -8))
    }
    .padding(.horizontal, 22).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(stroke, lineWidth: 1))
  }
}

// MARK: - Comments

struct CommentsPage: View {
  @ObservedObject var model: SettingsModel
  let p: SettingsPalette
  var body: some View {
    let style = model.bind({ $0.commentStyle }, { $0.commentStyle = $1 })
    let lines = model.bind({ $0.connectorLines }, { $0.connectorLines = $1 })
    Heading(title: "In the text")
    Card(p: p) {
      CommentPreview(style: style.wrappedValue, theme: Theme.named(model.bind({ $0.editorTheme }, { $0.editorTheme = $1 }).wrappedValue),
                     stroke: p.previewStroke)
        .padding(.top, 12).padding(.bottom, 6)
      Row(p: p, label: "Highlight") {
        Popup(p: p, value: ["tint": "Tint", "tint+underline": "Tint and underline", "underline": "Underline", "bar": "Bar in the margin"][style.wrappedValue] ?? "Tint") {
          Button("Tint") { style.wrappedValue = "tint" }
          Button("Tint and underline") { style.wrappedValue = "tint+underline" }
          Button("Underline") { style.wrappedValue = "underline" }
          Button("Bar in the margin") { style.wrappedValue = "bar" }
        }
      }
      Row(p: p, label: "Show resolved comments", note: "Dimmed, after the open ones.", last: true) {
        Switch(p: p, on: model.bind({ $0.showResolved }, { $0.showResolved = $1 }))
      }
    }
    Heading(title: "Cards")
    Card(p: p) {
      Row(p: p, label: "Floating card at the cursor", note: "When the sidebar is hidden, the comment under the cursor floats beside the text.") {
        Switch(p: p, on: model.bind({ $0.floatingCards }, { $0.floatingCards = $1 }))
      }
      Row(p: p, label: "Lines to the text", note: "From cards to the text they're on.", last: true) {
        Popup(p: p, value: ["none": "None", "selected": "Selected only", "all": "All"][lines.wrappedValue] ?? "None") {
          Button("None") { lines.wrappedValue = "none" }
          Button("Selected only") { lines.wrappedValue = "selected" }
          Button("All") { lines.wrappedValue = "all" }
        }
      }
    }
  }
}

/// A line of text with a comment highlighted in the chosen style, and the comment's card beside it.
struct CommentPreview: View {
  let style: String
  let theme: Theme?
  let stroke: Color
  var body: some View {
    let t = theme ?? SettingsModel.neovimTheme
    let author = Color(taudot: t.info)
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("The bound holds for every $n$.").foregroundColor(Color(taudot: t.fg))
        HStack(spacing: 0) {
          if style == "bar" { Rectangle().fill(author).frame(width: 3).padding(.trailing, 6) }
          Text("It is ").foregroundColor(Color(taudot: t.fg))
          Text("tight up to a constant").foregroundColor(Color(taudot: t.fg))
            .background(style.hasPrefix("tint") ? author.opacity(0.22) : .clear)
            .underline(style.contains("underline"), color: author)
          Text(".").foregroundColor(Color(taudot: t.fg))
        }
        .fixedSize()
        Text("% see the appendix").foregroundColor(Color(taudot: t.comment)).italic()
      }
      .font(.system(size: 13, design: .monospaced))
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Circle().fill(author).frame(width: 16, height: 16).overlay(Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
          Text("Ada").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(taudot: t.fg))
        }
        Text("Is this tight, or only up to log n?").font(.system(size: 11.5)).foregroundStyle(Color(taudot: t.fg).opacity(0.85))
      }
      .padding(10).frame(width: 190, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color(taudot: t.panel)))
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(taudot: t.bg)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(stroke, lineWidth: 1))
  }
}

// MARK: - Account

struct AccountPage: View {
  let p: SettingsPalette
  var body: some View {
    Heading(title: "Overleaf")
    Card(p: p) {
      HStack(spacing: 14) {
        TaudotMark(dot: TaudotMark.coral).foregroundStyle(p.text).frame(width: 40, height: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text("Your projects").font(.system(size: 13.5, weight: .medium))
          Text("Sign-in and your Overleaf projects live in the Projects window.").font(.system(size: 11.5)).foregroundStyle(p.secondary)
        }
        Spacer()
        GlassButton(p: p, title: "Open Projects…") { NSApp.sendAction(#selector(AppDelegate.showHome), to: nil, from: nil) }
      }
      .padding(.vertical, 14)
    }
  }
}
