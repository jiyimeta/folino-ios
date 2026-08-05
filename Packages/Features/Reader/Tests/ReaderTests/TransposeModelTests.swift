import Domain
import Foundation
@testable import Reader
import Testing

@MainActor
struct TransposeModelTests {
    // MARK: - Helpers

    private static func makeModel(
        controller: FakePlaybackController = FakePlaybackController(),
    ) -> (TransposeModel, FakePlaybackController) {
        let model = TransposeModel()
        model.controllerProvider = { controller }
        return (model, controller)
    }

    // MARK: - Defaults

    @Test func `semitones defaults to zero`() {
        let model = TransposeModel()
        #expect(model.semitones == nil) // untouched
        #expect(model.effectiveSemitones == 0)
    }

    // MARK: - setSemitones clamping

    @Test func `setSemitones clamps positive values above 7 to 7`() async {
        let (model, controller) = Self.makeModel()
        await model.setSemitones(9)
        #expect(model.semitones == 7)
        #expect(controller.transposeSemitoneCalls == [7])
    }

    @Test func `setSemitones clamps negative values below -7 to -7`() async {
        let (model, controller) = Self.makeModel()
        await model.setSemitones(-9)
        #expect(model.semitones == -7)
        #expect(controller.transposeSemitoneCalls == [-7])
    }

    @Test func `setSemitones accepts exact boundary values`() async {
        let (model, _) = Self.makeModel()
        await model.setSemitones(7)
        #expect(model.semitones == 7)
        await model.setSemitones(-7)
        #expect(model.semitones == -7)
    }

    @Test func `setSemitones does not forward when value is unchanged`() async {
        let (model, controller) = Self.makeModel()
        await model.setSemitones(3)
        let countAfterFirst = controller.transposeSemitoneCalls.count
        await model.setSemitones(3)
        #expect(controller.transposeSemitoneCalls.count == countAfterFirst)
    }

    // MARK: - setSemitones forwards to controller

    @Test func `setSemitones forwards clamped value to controller`() async {
        let (model, controller) = Self.makeModel()
        await model.setSemitones(5)
        #expect(controller.transposeSemitoneCalls == [5])
    }

    // MARK: - onChange fires

    @Test func `setSemitones fires onChange`() async {
        let (model, _) = Self.makeModel()
        var fired = false
        model.onChange = { fired = true }
        await model.setSemitones(2)
        #expect(fired)
    }

    @Test func `setSemitones does not fire onChange when value is unchanged`() async {
        let (model, _) = Self.makeModel()
        await model.setSemitones(3)
        var firedCount = 0
        model.onChange = { firedCount += 1 }
        await model.setSemitones(3)
        #expect(firedCount == 0)
    }

    // MARK: - sync(from:)

    @Test func `sync reads transposeSemitones from preferences`() {
        let model = TransposeModel()
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
            transposeSemitones: 4,
        )
        model.sync(from: prefs)
        #expect(model.semitones == 4)
    }

    @Test func `sync with default preferences yields zero`() {
        let model = TransposeModel()
        let prefs = ReaderPreferences(
            scoreItemID: ScoreItemID(),
            staffSize: 14,
            hiddenStaves: [],
        )
        model.sync(from: prefs)
        #expect(model.semitones == nil)
        #expect(model.effectiveSemitones == 0)
    }

    // MARK: - reset

    @Test func `reset returns semitones to untouched`() async {
        let (model, controller) = Self.makeModel()
        await model.setSemitones(5)
        await model.reset()
        // Back to "untouched", not an explicit 0 — the engine still gets the resolved default.
        #expect(model.semitones == nil)
        #expect(model.effectiveSemitones == 0)
        #expect(controller.transposeSemitoneCalls.last == 0)
    }

    @Test func `reset on an untouched model does nothing`() async {
        let (model, controller) = Self.makeModel()
        var fired = false
        model.onChange = { fired = true }

        await model.reset()

        #expect(!fired)
        #expect(controller.transposeSemitoneCalls.isEmpty)
    }

    @Test func `reset fires onChange`() async {
        let (model, _) = Self.makeModel()
        await model.setSemitones(3)
        var fired = false
        model.onChange = { fired = true }
        await model.reset()
        #expect(fired)
    }
}
