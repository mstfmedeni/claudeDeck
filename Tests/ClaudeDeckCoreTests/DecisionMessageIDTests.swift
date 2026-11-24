import ClaudeDeckCore
import Testing

@Suite struct DecisionMessageIDTests {
    @Test func idFromATypedAnswer() {
        #expect(Decisions.decisionID(inMessage: "[ClaudeDeck decision d_04cd3c6ef1] The owner answered your question “x”: y") == "d_04cd3c6ef1")
        #expect(Decisions.decisionID(inMessage: "Lead note: hi") == nil)
        #expect(Decisions.decisionID(inMessage: "[ClaudeDeck approval a_1] …") == nil)
    }
}
