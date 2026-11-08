import Testing
@testable import TaudotShared

@Test func valueEquality() {
  #expect(Value.array([.int(1), .string("a")]) == .array([.int(1), .string("a")]))
}
