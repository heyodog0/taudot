// The end-of-line comment notes, as Neovim mode draws them (clients/nvim/lua/taudot/ui.lua draw_inline): on each line
// where an open comment starts, "  ▍ Bob: first words… (+2)" after the line's text, the bar in the author's colour,
// the rest in the theme's comment colour. They show while the comments margin is hidden (gui.lua margin_shown) and
// not hidden by View ▸ Hide Comments in Text. This file is the model side (which notes, on which lines, saying what);
// NativeEditorView draws them (`lineNotes`, both the TextKit and the Metal paths).
import AppKit

/// One line's note. `line` is 0-based; `text` is "Author: first words…"; `more` is " (+2)" or "".
public struct LineNote: Equatable {
  public var line: Int
  /// The thread's comment range (the first one starting on this line).
  public var id: String
  /// "  ▍ ": drawn in `barColor`, bold.
  public var bar: String
  public var barColor: NSColor
  /// Drawn in the theme's comment colour.
  public var text: String
  public var more: String
  public init(line: Int, id: String, bar: String = LineNote.bar, barColor: NSColor, text: String, more: String = "") {
    self.line = line; self.id = id; self.bar = bar; self.barColor = barColor; self.text = text; self.more = more
  }
  /// gui.lua's `signs.comment`, with its spacing.
  public static let bar = "  \u{258D} "
  /// Characters of the message before "…" (draw_inline: over 40, the first 39 and "…").
  public static let maxChars = 40

  /// The whole note as drawn (for checks and accessibility).
  public var string: String { bar + text + more }

  /// The notes for a doc: per line, the open comment that starts first on it (the extmark order Neovim walks).
  /// `color` gives an author's colour from their key (user id, else name), as the native tints pick it.
  public static func make(text: [UInt8], ranges: [DocRange], threads: [String: [String: Any]],
                          color: (String) -> NSColor) -> [LineNote] {
    let starts = Utf.lineStarts(text)
    var out: [Int: LineNote] = [:]
    var firstAt: [Int: Int] = [:]
    for r in ranges where r.kind == "comment" {
      let t = r.threadID.flatMap { threads[$0] }
      if (t?["resolved"] as? Bool) ?? r.resolved { continue }
      let (line, _) = Utf.lineCol(starts, min(max(r.start, 0), text.count))
      if let s = firstAt[line], s <= r.start { continue }
      let msgs = t?["messages"] as? [[String: Any]] ?? []
      let user = msgs.first?["user"] as? [String: Any]
      let name = user.map { $0["name"] as? String ?? "?" } ?? r.author["name"] ?? "?"
      let key = user?["user_id"] as? String ?? r.author["user_id"] ?? r.author["name"] ?? "?"
      let body = msgs.first.map { $0["text"] as? String ?? "" } ?? "\u{201C}\(r.text)\u{201D}"
      firstAt[line] = r.start
      out[line] = LineNote(line: line, id: r.id, barColor: color(key), text: "\(name.isEmpty ? "?" : name): \(squeeze(body))",
                           more: msgs.count > 1 ? " (+\(msgs.count - 1))" : "")
    }
    return out.keys.sorted().map { out[$0]! }
  }

  /// Runs of whitespace as one space, then at most `maxChars` characters (39 and "…" past it).
  static func squeeze(_ s: String) -> String {
    let one = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let lead = s.first?.isWhitespace == true ? " " : "", trail = s.last?.isWhitespace == true && !one.isEmpty ? " " : ""
    let t = lead + one + trail
    return t.count > maxChars ? String(t.prefix(maxChars - 1)) + "\u{2026}" : t
  }
}
