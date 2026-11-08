// Review comments on the PDF as sticky notes: where each goes (pure, testable without a window).
//
// A comment's start (line, column) goes through SyncTeX to its typeset line, the same way forward search picks one
// (the cursor's place among the source line's words). The note sits in the page margin beside that line, the wider
// margin of the page (right on a tie: left margins often hold line numbers); notes on one line stack outward. The
// quoted words get a faint tint once they have been read off the page (`span`).
import CoreGraphics
import Foundation

/// One message of a comment's thread: the first is the comment itself, the rest replies.
public struct PDFCommentMessage: Sendable, Equatable {
  public var author: String
  /// "#rrggbb": the author's colour (nil: one picked from the name).
  public var color: String?
  public var text: String
  public var time: Date?
  /// Written by the user of this app.
  public var mine: Bool
  public init(author: String, color: String? = nil, text: String, time: Date? = nil, mine: Bool = false) {
    self.author = author; self.color = color; self.text = text; self.time = time; self.mine = mine
  }
}

/// A review comment as the app hands it to the PDF pane: the same items the review margin shows.
public struct PDFComment: Sendable, Equatable, Identifiable {
  public var id: String
  /// The source file (as Neovim names it, or relative to the project).
  public var path: String
  /// 1-based lines; columns are UTF-8 byte offsets (Neovim's), the end exclusive.
  public var line: Int
  public var column: Int?
  public var endLine: Int
  public var endColumn: Int?
  public var quote: String
  public var author: String
  /// "#rrggbb": the author's colour. Nil: one is picked from the author's name.
  public var color: String?
  public var firstMessage: String
  public var replies: Int
  public var resolved: Bool
  /// The whole thread, oldest first (the comment, then its replies). When given, `firstMessage` and `replies` follow
  /// from it.
  public var messages: [PDFCommentMessage]
  public init(
    id: String, path: String, line: Int, column: Int? = nil, endLine: Int? = nil, endColumn: Int? = nil, quote: String = "",
    author: String, color: String? = nil, firstMessage: String = "", replies: Int = 0, resolved: Bool = false,
    messages: [PDFCommentMessage] = []
  ) {
    self.id = id; self.path = path; self.line = line; self.column = column; self.endLine = endLine ?? line
    self.endColumn = endColumn; self.quote = quote; self.author = author; self.color = color
    self.firstMessage = messages.first?.text ?? firstMessage
    self.replies = messages.isEmpty ? replies : messages.count - 1
    self.resolved = resolved; self.messages = messages
  }

  /// "just now", "5 min. ago", "2 days ago", then "3 Nov": as the margin's cards.
  public static func ago(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "" }
    let s = now.timeIntervalSince(d)
    if s < 60 { return "just now" }
    if s < 7 * 86400 {
      let f = RelativeDateTimeFormatter()
      f.unitsStyle = .short
      return f.localizedString(for: d, relativeTo: now)
    }
    let df = DateFormatter()
    df.setLocalizedDateFormatFromTemplate("d MMM")
    return df.string(from: d)
  }
}

public enum NoteSide: Sendable, Equatable { case left, right }

/// A comment placed on a page (points from the page's top-left).
public struct PlacedNote: Sendable, Equatable {
  public var id: String
  public var page: Int
  /// The typeset line the comment starts on.
  public var line: CGRect
  /// The quoted words, one rect per typeset line they cover; empty until read off the page.
  public var words: [CGRect] = []
  public var side: NoteSide
  /// 0 for the first note on its line, 1 for the next…
  public var slot: Int
}

public enum NotePlacement {
  /// Which typeset line of a source line holds the word at `column`: the cursor's place among the line's words,
  /// scaled onto SyncTeX's marks (the row of each of the line's records, in order). Forward search does the same.
  public static func row(marks: [Int], words: [WordMatch.SourceWord], column: Int?) -> Int {
    var k = marks.first ?? 0
    if let column, words.count > 1, marks.count > 1, let t = WordMatch.wordIndex(words, column: column) {
      k = marks[Int((Double(t) / Double(words.count - 1) * Double(marks.count - 1)).rounded())]
    }
    return k
  }

  /// The wider margin of a page whose text block spans `text` (the typeset line's hbox: the text width); right on a
  /// tie, within 4 pt.
  public static func side(text: CGRect, pageWidth: CGFloat) -> NoteSide {
    text.minX > pageWidth - text.maxX + 4 ? .left : .right
  }

  /// Places comments: unresolved only, each on its starting typeset line, stacked per line in the order given.
  /// `rows` is SyncTeX's (forward search's) rows of a source line; `source` a source line's text.
  public static func place(
    _ comments: [PDFComment], rows: (String, Int) -> (rows: [SyncTex.Row], marks: [Int])?, source: (String, Int) -> String?,
    pageWidth: (Int) -> CGFloat
  ) -> [PlacedNote] {
    var out: [PlacedNote] = []
    var perLine: [String: Int] = [:]
    for c in comments where !c.resolved {
      guard let (rs, marks) = rows(c.path, c.line), !rs.isEmpty else { continue }
      let words = source(c.path, c.line).map(WordMatch.sourceWords) ?? []
      var k = row(marks: marks, words: words, column: c.column)
      if k >= rs.count { k = 0 }
      // a row taller than a line (a figure) still gets a note, at its top
      var line = rs[k].rect
      if line.height > LineMark.maxLine { line.size.height = 10 }
      let key = "\(rs[k].page):\(Int(line.minY.rounded()))"
      let slot = perLine[key, default: 0]
      perLine[key] = slot + 1
      out.append(PlacedNote(id: c.id, page: rs[k].page, line: line, side: side(text: line, pageWidth: pageWidth(rs[k].page)), slot: slot))
    }
    return out
  }

  /// Slots again after lines moved: notes on one line numbered in the order given.
  public static func restack(_ notes: [PlacedNote]) -> [PlacedNote] {
    var perLine: [String: Int] = [:]
    return notes.map { n in
      var n = n
      let key = "\(n.page):\(Int(n.line.minY.rounded()))"
      n.slot = perLine[key, default: 0]
      perLine[key] = n.slot + 1
      return n
    }
  }

  /// The note's marker in the margin: a square of `size` points (it grows when zoomed out so it stays visible),
  /// centred on the line, `gap` from the text, each later note on the line one marker further out (not overlapping,
  /// so each can be hovered and clicked).
  public static func marker(_ n: PlacedNote, size: CGFloat, pageWidth: CGFloat) -> CGRect {
    let gap = max(6, size * 0.5), step = size * 1.15
    let y = n.line.midY - size / 2
    switch n.side {
    case .right:
      let x = min(n.line.maxX + gap + CGFloat(n.slot) * step, pageWidth - size - 2)
      return CGRect(x: x, y: y, width: size, height: size)
    case .left:
      let x = max(n.line.minX - gap - size - CGFloat(n.slot) * step, 2)
      return CGRect(x: x, y: y, width: size, height: size)
    }
  }

  /// Every marker of a page set, laid out so none overlap: top to bottom, each takes the first spot outward from its
  /// line (its slot or further) that is free. Zoomed out, markers are taller than a line and would cover their
  /// neighbours' otherwise. Keyed by note id.
  public static func markers(_ notes: [PlacedNote], size: CGFloat, pageWidth: (Int) -> CGFloat) -> [String: CGRect] {
    var out: [String: CGRect] = [:]
    var taken: [Int: [CGRect]] = [:]
    let order = notes.indices.sorted { (notes[$0].page, notes[$0].line.minY, notes[$0].slot) < (notes[$1].page, notes[$1].line.minY, notes[$1].slot) }
    for i in order {
      var n = notes[i]
      let w = pageWidth(n.page)
      // the spots across the margin (until one would be pushed against the page's edge), then the same a little lower
      var across: [CGRect] = []
      for k in n.slot..<(n.slot + 20) {
        n.slot = k
        let r = marker(n, size: size, pageWidth: w)
        if let last = across.last, abs(last.minX - r.minX) < size { break }
        across.append(r)
      }
      if across.isEmpty { n.slot = 0; across = [marker(n, size: size, pageWidth: w)] }
      var r = across[0]
      search: for d in 0..<40 {
        for c in across {
          let cand = c.offsetBy(dx: 0, dy: CGFloat(d) * size * 0.6)
          if !(taken[n.page] ?? []).contains(where: { $0.insetBy(dx: 0.5, dy: 0.5).intersects(cand) }) { r = cand; break search }
        }
      }
      taken[n.page, default: []].append(r)
      out[n.id] = r
    }
    return out
  }

  /// The tint over a quote: page words `from`…`to` (indices into `page`, in reading order), one rect per typeset line.
  public static func span(page: [WordMatch.PageWord], from: Int, to: Int) -> [CGRect] {
    guard from >= 0, to < page.count, from <= to else { return [] }
    var out: [CGRect] = []
    for w in page[from...to] {
      for r in w.rects {
        if let i = out.indices.last, abs(out[i].midY - r.midY) < max(out[i].height, r.height) / 2 {
          out[i] = out[i].union(r)
        } else {
          out.append(r)
        }
      }
    }
    return out
  }
}
