import Foundation
import Testing
@testable import TaudotPDF

// The cursor to tau-live (`["cursor", path, line, column]`, docs/live-protocol.md): only once it rests, once per place.
@MainActor @Test func cursorFeedSendsWhenTheCursorRests() async throws {
  var sent: [String] = []
  let f = CursorFeed(delay: 0.1) { p, l, c in sent.append("\(p):\(l):\(c)") }
  f.moved("main.tex", line: 3, column: 1)
  f.moved("main.tex", line: 3, column: 2)
  f.moved("main.tex", line: 9, column: 4)  // three moves in a row: the last one only
  try await Task.sleep(for: .milliseconds(300))
  #expect(sent == ["main.tex:9:4"])
  f.moved("main.tex", line: 9, column: 4)  // the same place again: nothing new
  try await Task.sleep(for: .milliseconds(300))
  #expect(sent == ["main.tex:9:4"])
  f.reset()  // a new typesetter: it hears it again
  f.moved("main.tex", line: 9, column: 4)
  try await Task.sleep(for: .milliseconds(300))
  #expect(sent == ["main.tex:9:4", "main.tex:9:4"])
}
