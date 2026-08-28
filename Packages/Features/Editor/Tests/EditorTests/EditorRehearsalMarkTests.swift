import Domain
@testable import Editor
import Foundation
import SheetMusicCore
import Testing

/// The rehearsal-mark surface: what the sheet reads to open on, the letter it suggests, and the two writes —
/// including the quiet no-op ssm reports as `.nothingToApply`, which must not look like a failure to the caller.
@MainActor
@Suite("Editor rehearsal marks")
struct EditorRehearsalMarkTests {
    private func makeViewModel() -> EditorViewModel {
        EditorViewModel(
            scoreItem: EditorFixtures.sampleItem(),
            scoresDirectory: URL(filePath: "/tmp"),
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    /// A session on `threeMeasuresOfQuarterRests` with a rest picked in `measure` — the selection is what supplies
    /// `targetMeasureIndex`.
    private func session(targeting measure: Int) -> EditorViewModel {
        let vm = makeViewModel()
        vm.beginSession(score: EditorFixtures.threeMeasuresOfQuarterRests())
        vm.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measure, voiceIndex: 0, elementIndex: 0,
        )))
        return vm
    }

    @Test func `a bar with no mark reads nil and suggests A`() {
        let vm = session(targeting: 0)
        #expect(vm.targetRehearsalMarkText == nil)
        #expect(vm.suggestedRehearsalMarkText == "A")
    }

    @Test func `setting a mark lands and the bar then reads it back`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.targetRehearsalMarkText == "A")
    }

    @Test func `the suggestion counts the marks in earlier bars`() {
        let vm = session(targeting: 0)
        #expect(vm.setRehearsalMark(text: "A"))
        vm.select(.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 2, voiceIndex: 0, elementIndex: 0,
        )))
        #expect(vm.suggestedRehearsalMarkText == "B")
    }

    /// The doc's own example, and the case that separates "the marks BEFORE this bar" from "the marks in the score":
    /// with A at bar 0 and B at bar 2, a mark going into bar 1 is suggested "B" — counting every mark would suggest
    /// "C". Nothing renumbers the existing B either way; the suggestion is only ever a suggestion.
    @Test func `a mark inserted between A and B is suggested B`() {
        let vm = session(targeting: 0)
        #expect(vm.setRehearsalMark(text: "A"))
        vm.select(.rest(EditorFixtures.restID(measure: 2, element: 0)))
        #expect(vm.setRehearsalMark(text: "B"))
        vm.select(.rest(EditorFixtures.restID(measure: 1, element: 0)))
        #expect(vm.targetRehearsalMarkText == nil)
        #expect(vm.suggestedRehearsalMarkText == "B")
    }

    @Test func `a bar that already has a mark suggests its own text`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "Bridge"))
        #expect(vm.suggestedRehearsalMarkText == "Bridge")
    }

    @Test func `removing drops the mark`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.removeRehearsalMark())
        #expect(vm.targetRehearsalMarkText == nil)
    }

    @Test func `restating the same text reports false without a refusal`() {
        let vm = session(targeting: 1)
        #expect(vm.setRehearsalMark(text: "A"))
        var reported: [String] = []
        vm.onRehearsalMarkEdited = { reported.append($0) }
        #expect(!vm.setRehearsalMark(text: "A"))
        #expect(vm.session?.lastRefusal?.reason == .nothingToApply)
        #expect(reported.isEmpty) // a write that changed nothing is not an edit to count
    }

    @Test func `both writes report through the analytics hook`() {
        let vm = session(targeting: 1)
        var reported: [String] = []
        vm.onRehearsalMarkEdited = { reported.append($0) }
        #expect(vm.setRehearsalMark(text: "A"))
        #expect(vm.removeRehearsalMark())
        #expect(reported == ["set", "remove"])
    }

    /// No session at all — `targetMeasureIndex` is `selectedItem?.measureIndex ?? caretItem?.measureIndex`, and
    /// both are nil before one begins. There is no `clearSelection()` to reach for; this is the shape that makes
    /// "no target" certain rather than dependent on where a fresh session parks its caret.
    @Test func `without a target both writes are a no-op`() {
        let vm = makeViewModel()
        #expect(vm.targetMeasureIndex == nil)
        #expect(!vm.setRehearsalMark(text: "A"))
        #expect(!vm.removeRehearsalMark())
    }

    @Test(arguments: [(0, "A"), (1, "B"), (25, "Z"), (26, "AA"), (27, "AB")])
    func `letters run A to Z then AA`(index: Int, expected: String) {
        #expect(EditorViewModel.rehearsalMarkLetter(at: index) == expected)
    }
}
