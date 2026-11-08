import AppKit
import Testing
@testable import TaudotEditor

// The native editor's end-of-line comment notes match gui.lua's draw_inline (clients/nvim/lua/taudot/ui.lua).
@MainActor struct LineNotesTests {
  let text = Array("first line\nsecond line here\nthird\n".utf8)
  func range(_ id: String, _ a: Int, _ b: Int, thread: String? = nil, resolved: Bool = false, quote: String = "q") -> DocRange {
    DocRange(id: id, kind: "comment", start: a, end: b, text: quote, author: ["user_id": "u-r", "name": "Ranger"], ts: nil, threadID: thread, resolved: resolved)
  }
  func msg(_ text: String, _ name: String = "Bob", id: String = "u-bob") -> [String: Any] { ["text": text, "user": ["user_id": id, "name": name]] }
  func notes(_ r: [DocRange], _ t: [String: [String: Any]] = [:]) -> [LineNote] {
    LineNote.make(text: text, ranges: r, threads: t, color: { $0 == "u-bob" ? .systemBlue : .systemGreen })
  }

  @Test func firstMessageAuthorAndCount() {
    let n = notes([range("c1", 13, 17, thread: "t1")], ["t1": ["messages": [msg("Tighten  this\nbound."), msg("ok", "Ann", id: "u-ann")]]])
    #expect(n == [LineNote(line: 1, id: "c1", barColor: .systemBlue, text: "Bob: Tighten this bound.", more: " (+1)")])
    #expect(n[0].string == "  \u{258D} Bob: Tighten this bound. (+1)")
  }

  @Test func noThreadQuotesTheRange() {
    let n = notes([range("c1", 0, 5, quote: "first")])
    #expect(n.map(\.text) == ["Ranger: \u{201C}first\u{201D}"])
    #expect(n[0].barColor == .systemGreen && n[0].more == "")
  }

  @Test func truncatesPast40Characters() {
    let long = String(repeating: "a", count: 41)
    #expect(notes([range("c", 0, 2, thread: "t")], ["t": ["messages": [msg(long)]]])[0].text == "Bob: " + String(repeating: "a", count: 39) + "\u{2026}")
    let exact = String(repeating: "b", count: 40)
    #expect(notes([range("c", 0, 2, thread: "t")], ["t": ["messages": [msg(exact)]]])[0].text == "Bob: " + exact)
  }

  @Test func oneNotePerLineTheFirstStartingComment() {
    let n = notes([range("late", 18, 20, thread: "a"), range("early", 12, 14, thread: "b"), range("other", 28, 30, thread: "c")],
                  ["a": ["messages": [msg("late")]], "b": ["messages": [msg("early")]], "c": ["messages": [msg("x")]]])
    #expect(n.map(\.id) == ["early", "other"])
    #expect(n.map(\.line) == [1, 2])
  }

  @Test func resolvedAndChangesHaveNone() {
    var change = range("ch", 0, 3)
    change.kind = "insert"
    #expect(notes([range("r", 0, 3, resolved: true), change]).isEmpty)
    #expect(notes([range("t", 0, 3, thread: "t")], ["t": ["resolved": true, "messages": [msg("x")]]]).isEmpty)
  }
}
