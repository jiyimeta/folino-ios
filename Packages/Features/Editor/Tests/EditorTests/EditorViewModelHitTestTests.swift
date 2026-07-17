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
}
