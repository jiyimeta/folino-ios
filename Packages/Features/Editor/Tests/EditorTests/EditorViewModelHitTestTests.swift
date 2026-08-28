import Domain
@testable import Editor
import Foundation
import SheetMusicUI
import Testing

@MainActor
@Suite("EditorViewModel hit-test")
struct EditorViewModelHitTestTests {
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

    @Test func `tap on a notehead selects it`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let target = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: target, in: doc))

        vm.handleTap(at: anchor)

        #expect(vm.selectedItem == target)
        #expect(vm.selection == .single(target))
    }

    @Test func `tap on a rest selects it`() throws {
        let score = EditorFixtures.fourQuarterRests()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let target = SheetMusicCore.ScoreItemID.rest(EditorFixtures.restID(element: 2))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: target, in: doc))

        vm.handleTap(at: anchor)

        #expect(vm.selectedItem == target)
        #expect(vm.selection == .single(target))
    }

    /// Aiming a fingertip at a notehead is hard, and the engine's hit ladder only answers for points actually inside
    /// an element's geometry. A near miss should still select the note the user was clearly going for.
    @Test func `a near miss still selects the nearby note`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let target = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: target, in: doc))
        // Off the notehead itself, but well inside the slop box the pad-sized target should cover.
        let missed = CGPoint(x: anchor.x + 12, y: anchor.y + 12)
        #expect(ScoreHitTester(document: doc).hitTest(at: missed) == nil, "point must miss the engine's own ladder")

        vm.handleTap(at: missed)

        #expect(vm.selectedItem == target)
    }

    /// The widened target must not become a magnet: a tap nowhere near any element still deselects.
    @Test func `a tap far from every element still deselects`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let target = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: target, in: doc))
        vm.handleTap(at: anchor)
        #expect(vm.selectedItem == target)

        vm.handleTap(at: CGPoint(x: anchor.x, y: anchor.y + 200))

        #expect(vm.selectedItem == nil)
    }

    @Test func `tap on empty staff space deselects`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let noteTarget = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: noteTarget, in: doc))
        vm.handleTap(at: anchor)
        #expect(vm.selectedItem == noteTarget)

        // Well below the single system — outside the y-band of every hit zone in the ladder.
        vm.handleTap(at: CGPoint(x: anchor.x, y: anchor.y + 200))

        #expect(vm.selection == .none)
        #expect(vm.selectedItem == nil)
    }

    @Test func `tap near a voice-0 rest prefers the active voice when it falls in the slop rect`() throws {
        // Voice 0: four quarter rests. Voice 1: one measure-filling rest, nudged out of voice 0's way but still
        // horizontally close to voice 0's 3rd quarter rest (verified against the real layout: (421.875, 15.75) vs.
        // (418.375, 26.25) — 10.5 pt apart, inside the 44x44 (±22 pt) slop rect but outside the plain rest hit
        // radius, so the base `hitTest(at:)` resolves to voice 0 and the slop-rect fallback is what picks voice 1).
        var score = EditorFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices.append(
            Voice(elements: [.rest(duration: .measure)]),
        )
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let voice0Rest = SheetMusicCore.ScoreItemID.rest(EditorFixtures.restID(element: 3))
        let voice1Rest = SheetMusicCore.ScoreItemID.rest(
            RestID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 1, elementIndex: 0),
        )
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: voice0Rest, in: doc))

        vm.activeVoice = 1
        vm.handleTap(at: anchor)
        #expect(vm.selectedItem == voice1Rest)
        #expect(vm.selectedItem?.voiceIndex == 1)

        vm.activeVoice = 0
        vm.handleTap(at: anchor)
        #expect(vm.selectedItem == voice0Rest)
        #expect(vm.selectedItem?.voiceIndex == 0)
    }

    // MARK: - hoverItem(at:) — same resolution as handleTap, without mutating selection

    @Test func `hover over a notehead resolves it without mutating selection`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        // Seed an unrelated prior selection so a hover-driven mutation would be visible.
        let restTarget = SheetMusicCore.ScoreItemID.rest(EditorFixtures.restID(element: 2))
        let restAnchor = try #require(LayoutTestSupport.anchorPoint(of: restTarget, in: doc))
        vm.handleTap(at: restAnchor)
        #expect(vm.selectedItem == restTarget)

        let noteTarget = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let noteAnchor = try #require(LayoutTestSupport.anchorPoint(of: noteTarget, in: doc))

        #expect(vm.hoverItem(at: noteAnchor) == noteTarget)
        // Selection is untouched by the hover resolution.
        #expect(vm.selectedItem == restTarget)
        #expect(vm.selection == .single(restTarget))
    }

    @Test func `hover over empty staff space returns nil and leaves the prior selection untouched`() throws {
        let score = EditorFixtures.chordAtIndex1()
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let noteTarget = SheetMusicCore.ScoreItemID.note(EditorFixtures.noteID(element: 1))
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: noteTarget, in: doc))
        vm.handleTap(at: anchor)
        #expect(vm.selectedItem == noteTarget)

        // Well below the single system — outside the y-band of every hit zone in the ladder (same point
        // `handleTap`'s "tap empty staff space deselects" test uses).
        #expect(vm.hoverItem(at: CGPoint(x: anchor.x, y: anchor.y + 200)) == nil)
        #expect(vm.selectedItem == noteTarget)
        #expect(vm.selection == .single(noteTarget))
    }

    @Test func `hover near a voice-0 rest prefers the active voice when it falls in the slop rect`() throws {
        // Mirrors the equivalent `handleTap` slop-rect test above — hover must apply the same active-voice
        // preference so the pre-highlight always shows what a tap at that point would actually select.
        var score = EditorFixtures.fourQuarterRests()
        score.parts[0].staves[0].measures[0].voices.append(
            Voice(elements: [.rest(duration: .measure)]),
        )
        let vm = makeViewModel()
        vm.beginSession(score: score)
        let doc = LayoutTestSupport.document(for: score)
        vm.documentProvider = { doc }

        let voice0Rest = SheetMusicCore.ScoreItemID.rest(EditorFixtures.restID(element: 3))
        let voice1Rest = SheetMusicCore.ScoreItemID.rest(
            RestID(staff: EditorFixtures.staff0, measureIndex: 0, voiceIndex: 1, elementIndex: 0),
        )
        let anchor = try #require(LayoutTestSupport.anchorPoint(of: voice0Rest, in: doc))

        vm.activeVoice = 1
        #expect(vm.hoverItem(at: anchor) == voice1Rest)
        // No selection was ever made — hover must not have created one.
        #expect(vm.selectedItem == nil)

        vm.activeVoice = 0
        #expect(vm.hoverItem(at: anchor) == voice0Rest)
        #expect(vm.selectedItem == nil)
    }
}
