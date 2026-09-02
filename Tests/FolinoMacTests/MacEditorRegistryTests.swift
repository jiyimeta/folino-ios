import Domain
import Editor
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
        registry.register(makeEditor(), for: id)
        #expect(registry.editors.count == 1)
        registry.unregister(for: id)
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
}
