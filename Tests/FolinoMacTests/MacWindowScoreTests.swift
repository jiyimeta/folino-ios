import Domain
@testable import folino
import Testing

/// Spec §3: the same score can never open in two windows. `WindowGroup(for:)` dedupes on value equality, so the
/// window value must be the score id and nothing else.
struct MacWindowScoreTests {
    @Test func `two window values for one score are equal`() {
        let id = ScoreItemID()
        // swiftlint:disable:next identical_operands
        #expect(MacWindowScore(scoreID: id) == MacWindowScore(scoreID: id))
    }

    @Test func `window values for different scores differ`() {
        // swiftlint:disable:next identical_operands
        #expect(MacWindowScore(scoreID: ScoreItemID()) != MacWindowScore(scoreID: ScoreItemID()))
    }
}
