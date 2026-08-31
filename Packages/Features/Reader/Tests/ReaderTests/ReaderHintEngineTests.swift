import Foundation
import ReaderInteractionCore
import Testing

/// The coach-mark engine is what makes the two platforms' hints one feature rather than two that look alike, so its
/// sequencing is pinned here rather than left to whichever host is being looked at.
struct ReaderHintEngineTests {
    // MARK: - Doubles

    private final class MemoryStore: ReaderHintPersistence {
        var bools: [String: Bool] = [:]
        var ints: [String: Int32] = [:]

        func bool(forKey key: String) -> Bool {
            bools[key] ?? false
        }

        func setBool(_ value: Bool, forKey key: String) {
            bools[key] = value
        }

        func integer(forKey key: String) -> Int32 {
            ints[key] ?? 0
        }

        func setInteger(_ value: Int32, forKey key: String) {
            ints[key] = value
        }

        func removeObject(forKey key: String) {
            bools[key] = nil
            ints[key] = nil
        }
    }

    /// Records what the engine asked for instead of sleeping, so the delayed offers are testable without waiting.
    private final class ManualScheduler: ReaderHintScheduler {
        private(set) var scheduled: [ReaderHintDeferredOffer] = []
        private(set) var cancelled: [ReaderHintDeferredOffer] = []

        var pending: Set<ReaderHintDeferredOffer> {
            Set(scheduled).subtracting(cancelled)
        }

        func schedule(_ offer: ReaderHintDeferredOffer, after _: Double) {
            scheduled.append(offer)
        }

        func cancel(_ offer: ReaderHintDeferredOffer) {
            cancelled.append(offer)
        }
    }

    private func makeEngine() -> (ReaderHintEngine, MemoryStore, ManualScheduler) {
        let store = MemoryStore()
        let scheduler = ManualScheduler()
        let engine = ReaderHintEngine(persistence: store, scheduler: scheduler)
        return (engine, store, scheduler)
    }

    private let unitRect = ReaderHintRect(x: 0, y: 0, width: 10, height: 10)

    // MARK: - Rotation

    @Test func `the rotation leads with the transport swipe`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .transportExpanded)
        engine.setAnchor(unitRect, for: .annotationButton)

        engine.offerRotationHint()

        #expect(engine.presentedHint == .transportCollapse)
    }

    @Test func `a hint whose control is off screen is skipped without spending the cursor`() {
        let (engine, store, _) = makeEngine()
        // Only the annotation button is on screen, so the transport and note-editing hints are not eligible.
        engine.setAnchor(unitRect, for: .annotationButton)

        engine.offerRotationHint()
        #expect(engine.presentedHint == .annotation)

        // The cursor advanced past `annotation` only — the two it skipped are still ahead of it in a Reader that
        // does show them.
        let next = ReaderHintEngine.selectHint(
            order: ReaderFeatureHint.rotationOrder,
            cursor: Int(store.ints[ReaderHintEngineKeys.cursor] ?? 0),
            isEligible: { _ in true },
        )
        #expect(next == .staffVisibility)
    }

    @Test func `the rotation offers at most one hint per launch`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .transportExpanded)
        engine.setAnchor(unitRect, for: .annotationButton)

        engine.offerRotationHint()
        engine.dismiss()
        engine.offerRotationHint()

        #expect(engine.presentedHint == nil)
    }

    @Test func `the QA override spends the budget every time`() {
        let (engine, _, _) = makeEngine()
        engine.ignoresPerLaunchBudget = true
        engine.setAnchor(unitRect, for: .transportExpanded)
        engine.setAnchor(unitRect, for: .annotationButton)

        engine.offerRotationHint()
        #expect(engine.presentedHint == .transportCollapse)
        engine.dismiss()
        engine.offerRotationHint()
        #expect(engine.presentedHint == .annotation)
    }

    @Test func `a used hint never comes back`() {
        let (engine, _, _) = makeEngine()
        engine.markUsed(.transportCollapse)
        engine.setAnchor(unitRect, for: .transportExpanded)
        engine.setAnchor(unitRect, for: .annotationButton)

        engine.offerRotationHint()

        #expect(engine.presentedHint == .annotation)
    }

    @Test func `using the showing feature takes its bubble down`() {
        let (engine, _, _) = makeEngine()
        engine.present(.annotation)

        engine.markUsed(.annotation)

        #expect(engine.presentedHint == nil)
    }

    // MARK: - The unbudgeted transport-expand offer

    @Test func `the compact transport appearing schedules its own hint`() {
        let (engine, _, scheduler) = makeEngine()

        engine.setAnchor(unitRect, for: .transportCompact)

        #expect(scheduler.pending.contains(.transportExpand))
        engine.fireDeferredOffer(.transportExpand)
        #expect(engine.presentedHint == .transportExpand)
    }

    @Test func `the transport-expand hint is not budgeted against the rotation`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .annotationButton)
        engine.offerRotationHint()
        #expect(engine.presentedHint == .annotation)

        // The rotation has spent its one offer for this launch; the transport's still outranks it.
        engine.setAnchor(unitRect, for: .transportCompact)
        engine.fireDeferredOffer(.transportExpand)

        #expect(engine.presentedHint == .transportExpand)
    }

    @Test func `a fired offer whose control has gone is a no-op`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .transportCompact)
        engine.clearAnchor(for: .transportCompact)

        engine.fireDeferredOffer(.transportExpand)

        #expect(engine.presentedHint == nil)
    }

    @Test func `edit mode keeps the transport-expand hint away`() {
        let (engine, _, _) = makeEngine()
        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .transportCompact)

        engine.fireDeferredOffer(.transportExpand)

        #expect(engine.presentedHint == nil)
    }

    @Test func `entering edit mode takes a showing transport-expand hint down`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .transportCompact)
        engine.fireDeferredOffer(.transportExpand)
        #expect(engine.presentedHint == .transportExpand)

        engine.setEditing(true)

        #expect(engine.presentedHint == nil)
    }

    // MARK: - Anchors

    @Test func `losing the anchor takes the bubble pointing at it down`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .annotationButton)
        engine.present(.annotation)

        engine.clearAnchor(for: .annotationButton)

        #expect(engine.presentedHint == nil)
    }

    @Test func `a bubble pointing elsewhere survives an unrelated anchor going away`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .annotationButton)
        engine.setAnchor(unitRect, for: .noteEditingButton)
        engine.present(.annotation)

        engine.clearAnchor(for: .noteEditingButton)

        #expect(engine.presentedHint == .annotation)
    }

    @Test func `leaving the reader drops every anchor`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .annotationButton)
        engine.present(.annotation)

        engine.clearAllAnchors()

        #expect(engine.presentedHint == nil)
        #expect(!engine.hasAnyAnchor)
    }

    // MARK: - The pad chain

    @Test func `entering edit mode with the pad out teaches the tuck first`() {
        let (engine, _, _) = makeEngine()
        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .noteInputPad)

        engine.offerPadGestureHint()

        #expect(engine.presentedHint == .padHide)
    }

    @Test func `once the tuck is known the pad offers the move`() {
        let (engine, _, _) = makeEngine()
        engine.markUsed(.padHide)
        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .noteInputPad)

        engine.offerPadGestureHint()

        #expect(engine.presentedHint == .padMove)
    }

    @Test func `a session entered with the pad tucked teaches the restore`() {
        let (engine, _, _) = makeEngine()
        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .noteInputPadHandle)

        engine.offerPadGestureHint()

        #expect(engine.presentedHint == .padRestore)
    }

    @Test func `the pad budget is independent of the rotation's`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .annotationButton)
        engine.offerRotationHint()
        #expect(engine.presentedHint == .annotation)

        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .noteInputPad)
        engine.offerPadGestureHint()

        #expect(engine.presentedHint == .padHide)
    }

    @Test func `leaving edit mode drops the pending pad offers`() {
        let (engine, _, scheduler) = makeEngine()
        engine.setEditing(true)
        engine.setAnchor(unitRect, for: .noteInputPadHandle)
        #expect(scheduler.pending.contains(.padRestore))

        engine.setEditing(false)

        #expect(!scheduler.pending.contains(.padRestore))
    }

    // MARK: - Reset

    @Test func `reset re-arms every hint and the launch budget`() {
        let (engine, _, _) = makeEngine()
        engine.setAnchor(unitRect, for: .transportExpanded)
        engine.offerRotationHint()
        engine.markUsed(.transportCollapse)

        engine.reset()
        engine.offerRotationHint()

        #expect(engine.presentedHint == .transportCollapse)
    }

    // MARK: - Wire values

    @Test func `every hint and target round-trips through its wire value`() {
        for hint in ReaderFeatureHint.allCases {
            #expect(ReaderFeatureHint.fromWireValue(hint.wireValue) == hint)
            #expect(hint.wireValue != ReaderFeatureHint.noHintWireValue)
        }
        for target in ReaderHintTarget.allCases {
            #expect(ReaderHintTarget.fromWireValue(target.wireValue) == target)
        }
        #expect(ReaderFeatureHint.fromWireValue(ReaderFeatureHint.noHintWireValue) == nil)
    }

    @Test func `the persistence key format is the one both platforms write`() {
        #expect(ReaderFeatureHint.transportExpand.usedKey == "readerHint.used.transportExpand")
        #expect(ReaderHintEngineKeys.cursor == "readerHint.cursor")
    }
}
