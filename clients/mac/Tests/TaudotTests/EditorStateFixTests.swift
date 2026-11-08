// statefix items in TaudotEditor: E9's twin in the native editor (sm-sync's request).
import Testing
@testable import TaudotEditor

/// A doc.state the engine took before our edit's result (seq 0, nothing unconfirmed), arriving after that result,
/// must not clear `unflushed`: Overleaf may not have the edit yet, and a rebase after an engine kill needs it. One
/// taken at or after our seq does clear it; one without a seq (an older engine) never does.
@MainActor @Test func e9StaleDocStateKeepsUnflushed() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "hello\n", seq: 0, conn: nil)
  d.local(Edit(pos: 5, del: 0, ins: " world"))
  #expect(d.takeSend() != nil)
  d.ack(1)
  #expect(d.unflushed.count == 1)
  d.engineState(["doc_id": "d", "unconfirmed": 0, "seq": 0])
  #expect(d.unflushed.count == 1, "a state from before the edit's result keeps it")
  d.engineState(["doc_id": "d", "unconfirmed": 0])
  #expect(d.unflushed.count == 1, "a state without a seq keeps it")
  d.engineState(["doc_id": "d", "unconfirmed": 1, "seq": 1])
  #expect(d.unflushed.count == 1, "the engine still has it unconfirmed")
  d.engineState(["doc_id": "d", "unconfirmed": 0, "seq": 1])
  #expect(d.unflushed.isEmpty, "Overleaf has it")
}
