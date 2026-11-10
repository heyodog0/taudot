// The native editor's text input and accessibility (both TextKit and Metal): IME marked text and dead keys go
// through NSTextInputClient and land in the text; the candidate window and VoiceOver get the right places.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor private func editor(metal: Bool) -> (NSWindow, NativeEditorView) {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  var text = ""
  for i in 0..<60 { text += "line \(i) of the paper\n" }
  v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
  w.makeFirstResponder(v.textView)
  v.layoutSubtreeIfNeeded()
  return (w, v)
}

@MainActor @Test func imeAndDeadKeysInBothEditors() async throws {
  for metal in [false, true] {
    let (w, v) = editor(metal: metal)
    let tv = v.textView, mode = metal ? "metal" : "textkit"
    let at = (tv.string as NSString).range(of: "line 2 of").upperBound
    tv.setSelectedRange(NSRange(location: at, length: 0))
    // a dead key: ´ marked, then é replaces it
    tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(tv.markedRange() == NSRange(location: at, length: 1), "\(mode): dead key marked \(tv.markedRange())")
    w.displayIfNeeded()
    tv.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!tv.hasMarkedText() && (tv.string as NSString).substring(with: NSRange(location: at, length: 1)) == "é", "\(mode): dead key composed")
    // Japanese: marked "かん", the candidate window under it, then committed as "漢"
    tv.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let marked = tv.markedRange()
    #expect(marked.length == 2, "\(mode): marked \(marked)")
    let screen = tv.firstRect(forCharacterRange: marked, actualRange: nil)
    let caret = tv.firstRect(forCharacterRange: NSRange(location: at + 1, length: 0), actualRange: nil)
    #expect(screen.width > 4 && abs(screen.minX - caret.minX) < 2 && abs(screen.minY - caret.minY) < 2, "\(mode): candidate rect \(screen) at the caret \(caret)")
    #expect(w.frame.insetBy(dx: -1, dy: -1).contains(screen), "\(mode): in the window \(w.frame) \(screen)")
    w.displayIfNeeded()
    tv.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(!tv.hasMarkedText() && (tv.string as NSString).substring(with: NSRange(location: at, length: 2)) == "é漢", "\(mode): committed")
    #expect(tv.undoManager?.canUndo == true, "\(mode): undoable")
  }
}

@MainActor @Test func voiceOverGeometryInBothEditors() async throws {
  for metal in [false, true] {
    let (w, v) = editor(metal: metal)
    let tv = v.textView, mode = metal ? "metal" : "textkit"
    #expect(tv.isAccessibilityElement() && tv.accessibilityRole() == .textArea, "\(mode): a text area")
    #expect((tv.accessibilityValue() as? String) == tv.string, "\(mode): its value is the text")
    // the element covers the visible text, not a 0×0 point (TextKit: the whole document)
    let f = tv.accessibilityFrame()
    #expect(f.width > 300 && f.height > 150 && (metal ? w.frame.insetBy(dx: -1, dy: -1).contains(f) : f.intersects(w.frame)), "\(mode): frame \(f) in \(w.frame)")
    // a line's frame where its text is drawn; a point back to its character
    let r = (tv.string as NSString).range(of: "line 4 of")
    let lf = tv.accessibilityFrame(for: r)
    let fr = tv.firstRect(forCharacterRange: r, actualRange: nil)
    #expect(lf.width > 20 && abs(lf.minX - fr.minX) < 1 && abs(lf.minY - fr.minY) < 1, "\(mode): range frame \(lf) vs \(fr)")
    let back = tv.accessibilityRange(for: NSPoint(x: lf.minX + 2, y: lf.midY))
    #expect(abs(back.location - r.location) <= 1, "\(mode): point → \(back.location), want \(r.location)")
    // the line of a character and the visible range (VoiceOver reads by line and what's on screen)
    let line = tv.accessibilityLine(for: r.location)
    #expect(line == 4, "\(mode): line of 'line 4' = \(line)")
    let lr = tv.accessibilityRange(forLine: 4)
    #expect(lr.location == r.location, "\(mode): line 4's range \(lr)")
    let vis = tv.accessibilityVisibleCharacterRange()
    #expect(vis.location == 0 && vis.length > 100 && vis.length < (tv.string as NSString).length, "\(mode): visible \(vis)")
  }
}

/// Edit ▸ Cut/Copy/Paste/Select All/Undo (main.swift) go to the first responder: the native editor (both TextKit and
/// Metal) answers them, so ⌘C ⌘V work there; a view that implements none of them (Neovim's) gets no target, so the
/// menu items stay disabled and the keys reach Neovim as before.
@MainActor private func handler(_ a: Selector, in w: NSWindow) -> NSResponder? {
  var r: NSResponder? = w.firstResponder
  while let x = r { if x.responds(to: a) { return x }; r = x.nextResponder }
  return nil
}

@MainActor @Test func editMenuActionsReachTheNativeEditorOnly() async throws {
  let actions = ["cut:", "copy:", "paste:", "selectAll:"].map { Selector($0) }
  for metal in [false, true] {
    let (w, v) = editor(metal: metal)
    let tv = v.textView, mode = metal ? "metal" : "textkit"
    for a in actions + [Selector(("undo:"))] {
      #expect(handler(a, in: w) != nil, "\(mode): \(a) has a handler")
    }
    for a in actions { #expect(handler(a, in: w) === tv, "\(mode): \(a) reaches the editor") }
    let r = (tv.string as NSString).range(of: "paper")
    tv.setSelectedRange(r)
    NSPasteboard.general.clearContents()
    #expect(w.firstResponder!.tryToPerform(#selector(NSText.copy(_:)), with: nil), "\(mode): copy")
    #expect(NSPasteboard.general.string(forType: .string) == "paper", "\(mode): copied")
    let end = (tv.string as NSString).range(of: "line 3 of").upperBound
    tv.setSelectedRange(NSRange(location: end, length: 0))
    #expect(w.firstResponder!.tryToPerform(#selector(NSText.paste(_:)), with: nil), "\(mode): paste")
    #expect(tv.string.contains("line 3 ofpaper"), "\(mode): pasted")
  }
  final class Plain: NSView { override var acceptsFirstResponder: Bool { true } }
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
  let p = Plain(frame: w.contentView!.bounds)
  w.contentView!.addSubview(p)
  w.makeFirstResponder(p)
  for a in actions { #expect(handler(a, in: w) == nil, "a view without \(a) gets no target") }
}
