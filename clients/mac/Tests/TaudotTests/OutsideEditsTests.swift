// The app's list of outside edits (editfix item 9): one replacement per batch, its range moving with later edits,
// who made it, undo while its text is untouched.
import Foundation
import Testing
@testable import TaudotEditor

@MainActor private func feed(_ m: OutsideEdits, _ path: String, _ edits: [(Int, Int, String)]) {
  for e in edits { m.changed(path, e.0, e.1, e.2) }
}

@MainActor @Test func outsideEditBecomesOneChange() throws {
  let m = OutsideEdits()
  m.held("main.tex", "Line one.\nLine two here.\nLine three.\n")
  // a disk edit in two steps: an insert on line 2, a delete on line 3
  let batch = [(15, 0, "really "), (37, 5, "")]
  feed(m, "main.tex", batch)
  m.outside("main.tex", edits: batch.map { ($0.0, $0.1, $0.2) }, author: ["user_id": "me", "name": "You"], origin: "local", source: "disk")
  let c = try #require(m.list.first)
  #expect(c.who == "on disk" && c.disk)
  #expect(String(decoding: c.new, as: UTF8.self) == "really two here.\nLine ")
  #expect(String(decoding: c.old, as: UTF8.self) == "two here.\nLine three")
  #expect(m.line(of: c)?.line == 2)
  #expect(m.lines(of: c) == 2...3)
  #expect(m.canUndo(c))
  // with Claude busy it's Claude's; a coauthor's carries their name
  m.claudeBusy = { true }
  feed(m, "main.tex", [(0, 0, "A ")])
  m.outside("main.tex", edits: [(0, 0, "A ")], author: nil, origin: "local", source: "disk")
  #expect(m.list.first?.who == "Claude")
  feed(m, "main.tex", [(0, 0, "B ")])
  m.outside("main.tex", edits: [(0, 0, "B ")], author: ["user_id": "u2", "name": "Bo"], origin: "remote", source: nil)
  #expect(m.list.first?.who == "Bo" && m.list.first?.disk == false)
  #expect(OutsideEdits.summary(m.list.first!) == "+ B")
}

@MainActor @Test func outsideChangeMovesAndUndoes() throws {
  let m = OutsideEdits()
  m.held("a.tex", "hello world\n")
  feed(m, "a.tex", [(6, 0, "brave ")])
  m.outside("a.tex", edits: [(6, 0, "brave ")], author: nil, origin: "local", source: "disk")
  var c = try #require(m.list.first)
  #expect(c.pos == 6 && c.len == 6)
  // typing before it moves it; after it, nothing
  feed(m, "a.tex", [(0, 0, "Oh, ")])
  c = try #require(m.list.first)
  #expect(c.pos == 10 && m.canUndo(c))
  feed(m, "a.tex", [(22, 0, "!")])
  c = try #require(m.list.first)
  #expect(c.pos == 10 && c.len == 6 && m.canUndo(c))
  let u = try #require(m.undoEdit(c))
  #expect(u.pos == 10 && u.del == 6 && u.ins == "")
  // an edit inside it: no undo
  feed(m, "a.tex", [(12, 1, "A")])
  c = try #require(m.list.first)
  #expect(!m.canUndo(c) && m.undoEdit(c) == nil)
}

@MainActor @Test func outsideChangeIsWholeWords() throws {
  let m = OutsideEdits()
  m.held("a.tex", "Line 50 words here\n")
  feed(m, "a.tex", [(9, 0, "aited w")])  // what a minimal diff of "words" → "waited words" gives
  m.outside("a.tex", edits: [(9, 0, "aited w")], author: nil, origin: "local", source: "disk")
  let c = try #require(m.list.first)
  #expect(OutsideEdits.summary(c) == "words → waited words", "\(OutsideEdits.summary(c))")
  #expect(m.canUndo(c))
}
