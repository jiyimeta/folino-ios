import Domain
@testable import Editor
import Foundation
import Testing

/// What the strip's single trailing control is showing, which is the session's whole status readout.
///
/// The case that matters most here is the one that is easy to get wrong and invisible when it is: a score opened
/// fresh — a new launch, no edits yet this session — whose file already differs from the original. Nothing about
/// the *session* says so; only the row does. If that lands on a checkmark, the user is offered "done" for work they
/// cannot see and never offered the way back.
@MainActor
@Suite("EditorViewModel session-end mode")
struct EditorSessionEndModeTests {
    private func makeViewModel(item: ScoreItem) -> EditorViewModel {
        EditorViewModel(
            scoreItem: item,
            scoresDirectory: FileManager.default.temporaryDirectory,
            gateway: FakeScoreFileGateway(),
            repository: FakeScoreLibraryRepository(),
            originalStore: FakeScoreOriginalStore(),
            historyStore: NoopScoreEditHistoryStore(),
            playback: nil,
        )
    }

    private func itemWithOriginal() -> ScoreItem {
        var item = EditorFixtures.sampleItem()
        item.originalFileName = "score.original.mscz"
        item.originalContentHash = "orig"
        item.originalProvenance = .importTime
        return item
    }

    @Test
    func `a score with no original, untouched this session, offers a plain commit`() {
        let viewModel = makeViewModel(item: EditorFixtures.sampleItem())
        viewModel.beginSession(score: EditorFixtures.fourQuarterRests())
        #expect(viewModel.sessionEndMode == .commitUnchanged)
    }

    @Test
    func `a score edited in an EARLIER session offers revert as soon as the session opens`() {
        let viewModel = makeViewModel(item: itemWithOriginal())
        viewModel.beginSession(score: EditorFixtures.fourQuarterRests())
        // No edit has been made in this session, and none is needed: the captured original is what says the file on
        // disk is not what was imported.
        #expect(viewModel.sessionHasEdits == false)
        #expect(viewModel.sessionEndMode == .revert)
    }

    @Test
    func `an edit in this session takes precedence over the revert offer`() {
        let viewModel = makeViewModel(item: itemWithOriginal())
        viewModel.beginSession(score: EditorFixtures.fourQuarterRests())
        viewModel.previewSeedSessionEdit()
        #expect(viewModel.sessionEndMode == .commitEdited)
    }

    @Test
    func `undoing back to nothing hands the revert offer back`() {
        let viewModel = makeViewModel(item: itemWithOriginal())
        viewModel.beginSession(score: EditorFixtures.fourQuarterRests())
        viewModel.previewSeedSessionEdit()
        viewModel.unwindSessionEdits()
        #expect(viewModel.sessionHasEdits == false)
        #expect(viewModel.sessionEndMode == .revert)
    }
}
