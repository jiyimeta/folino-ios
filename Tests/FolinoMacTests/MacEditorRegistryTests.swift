import Domain

// `@testable` for `PreviewEditorFactory`, which is internal to the Editor package: the repo rule is never to widen
// access for a test.
@testable import Editor
@testable import folino
import Testing

@MainActor
struct MacEditorRegistryTests {
    private func makeEditor() -> EditorViewModel {
        // The registry only holds references; an editor with no session is enough.
        PreviewEditorFactory.makeViewModel()
    }

    @Test func `register then unregister leaves nothing`() {
        let registry = MacEditorRegistry()
        let id = ScoreItemID()
        let editor = makeEditor()
        registry.register(editor, for: id)
        #expect(registry.editors.count == 1)
        registry.unregister(editor, for: id)
        #expect(registry.editors.isEmpty)
    }

    @Test func `one entry per score, the latest wins`() {
        let registry = MacEditorRegistry()
        let id = ScoreItemID()
        let second = makeEditor()
        registry.register(makeEditor(), for: id)
        registry.register(second, for: id)
        #expect(registry.editors.count == 1)
        #expect(registry.editors.first === second)
    }

    /// The whole reason `unregister` is identity-checked. A window's entry comes off only once its `endSession`
    /// flush has landed, and by then the same score may already have been reopened in a new window: the late
    /// unregister must not take the live editor down with it, or ⌘Q would skip its pending autosave.
    @Test func `unregistering a superseded editor leaves the live entry standing`() {
        let registry = MacEditorRegistry()
        let id = ScoreItemID()
        let closing = makeEditor()
        let reopened = makeEditor()
        registry.register(closing, for: id)
        registry.register(reopened, for: id)
        registry.unregister(closing, for: id)
        #expect(registry.editors.count == 1)
        #expect(registry.editors.first === reopened)
    }

    /// The brief's third test ("flushAll returns even when an editor never finishes") needs an editor whose flush
    /// hangs, which `PreviewEditorFactory` cannot produce (its gateway/repository are no-ops that return immediately).
    /// Replaced per the controller ruling with two prompt-return checks instead: an empty registry, and a registry
    /// holding one idle editor — both must return well under the timeout, since neither has anything to flush.
    @Test func `flushAll on an empty registry returns immediately`() async {
        let registry = MacEditorRegistry()
        let clock = ContinuousClock()
        let start = clock.now
        await registry.flushAll(timeout: .milliseconds(200))
        #expect(clock.now - start < .seconds(2))
    }

    @Test func `flushAll with one idle editor returns promptly`() async {
        let registry = MacEditorRegistry()
        registry.register(makeEditor(), for: ScoreItemID())
        let clock = ContinuousClock()
        let start = clock.now
        await registry.flushAll(timeout: .milliseconds(200))
        #expect(clock.now - start < .seconds(2))
    }

    /// `raceAgainstTimeout` is the primitive `flushAll` builds on, and it is what actually exercises the "operation
    /// never finishes" case the brief's third test wanted — directly, without needing a hang-producing editor.
    @Test func `raceAgainstTimeout returns on the timeout when the operation never finishes`() async {
        let clock = ContinuousClock()
        let start = clock.now
        await MacEditorRegistry.raceAgainstTimeout(.milliseconds(200)) {
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func `raceAgainstTimeout returns promptly when the operation finishes immediately`() async {
        let clock = ContinuousClock()
        let start = clock.now
        await MacEditorRegistry.raceAgainstTimeout(.seconds(5)) {}
        #expect(clock.now - start < .seconds(1))
    }
}
