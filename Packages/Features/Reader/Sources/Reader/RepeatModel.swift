import Domain
import Observation
import SheetMusicCore

/// Owns the Reader's repeat / A-B loop state. Carved out of `ReaderViewModel` so views that need only the loop surface
/// (`PlaybackInspectorScreen`, the score-area markers, the toolbar's A/B buttons) can receive this model instead of the
/// full view model.
///
/// Persistent fields (`mode`, `abRange`) are mirrored into `ReaderPreferences` via the parent VM's `onChange` callback;
/// transient fields (`pendingA`, `pendingB`) live here only.
@MainActor
@Observable
final class RepeatModel {
    /// SwiftUI bindings write through `mode` directly. Reads are tracked via the macro-generated observation registrar
    /// like any other stored property. The `didSet` defers persistence + controller push to a Task so that picker
    /// writes stay synchronous; tests use `setMode(_:)` to await both side effects.
    var mode: RepeatMode = .off {
        didSet {
            guard mode != oldValue, !isSyncing else { return }
            Task { [weak self] in
                guard let self else { return }
                await onChange?()
                await forwardLoopRangeToController()
            }
        }
    }

    private(set) var abRange: ABRepeatRange?
    private(set) var pendingA: ChordPath?
    private(set) var pendingB: ChordPath?

    @ObservationIgnored var onChange: (() async -> Void)?
    @ObservationIgnored var scoreProvider: () -> Score? = { nil }
    @ObservationIgnored var cursorProvider: () -> ScoreCursor? = { nil }
    @ObservationIgnored var controllerProvider: () -> (any PlaybackController)? = { nil }

    /// Suppresses `mode`'s didSet side effects while the parent reseeds the model from a freshly loaded
    /// `ReaderPreferences`.
    @ObservationIgnored private var isSyncing = false

    /// Either the user's staged A endpoint (a candidate that hasn't yet formed a complete loop) or the persisted start
    /// of an existing `abRange`. Callers don't care which — they just want "what point represents A right now."
    var pendingRepeatA: ChordPath? {
        pendingA ?? abRange?.start
    }

    var pendingRepeatB: ChordPath? {
        pendingB ?? abRange?.end
    }

    /// Apply a persisted slice loaded from disk. Resets the in-flight endpoints — they're UI-transient and don't
    /// survive a fresh load.
    func sync(from prefs: ReaderPreferences) {
        isSyncing = true
        defer { isSyncing = false }
        mode = prefs.repeatMode
        abRange = prefs.abRepeat
        pendingA = nil
        pendingB = nil
    }

    /// Awaitable counterpart to the `mode` binding setter. Tests and any async context that needs to observe
    /// persistence + loop-range push before continuing should use this.
    func setMode(_ value: RepeatMode) async {
        guard value != mode else { return }
        isSyncing = true
        mode = value
        isSyncing = false
        await onChange?()
        await forwardLoopRangeToController()
    }

    func setA() async {
        if let pendingRepeatA, pendingRepeatA.measureIndex == cursorProvider()?.measureIndex {
            await clearA()
            return
        }
        guard let score = scoreProvider(), let cursor = cursorProvider() else { return }
        let measure = measureIndex(of: cursor)
        let head = snapMeasureHead(measureIndex: measure, in: score)
        pendingA = head
        await commitPending()
        await forwardLoopRangeToController()
    }

    func setB() async {
        if let pendingRepeatB, pendingRepeatB.measureIndex == cursorProvider()?.measureIndex {
            await clearB()
            return
        }
        guard let score = scoreProvider(), let cursor = cursorProvider() else { return }
        let measure = measureIndex(of: cursor)
        guard let end = snapMeasureEnd(measureIndex: measure, in: score) else { return }
        pendingB = end
        await commitPending()
        await forwardLoopRangeToController()
    }

    func clearA() async {
        pendingA = nil
        if let existing = abRange {
            pendingB = existing.end
            abRange = nil
            await onChange?()
        }
        // Forwards even when no save fired — keeps the controller's last-call cache aligned with intent (e.g. clearing
        // during .loopAll).
        await forwardLoopRangeToController()
    }

    func clearB() async {
        pendingB = nil
        if let existing = abRange {
            pendingA = existing.start
            abRange = nil
            await onChange?()
        }
        await forwardLoopRangeToController()
    }

    func forwardLoopRangeToController() async {
        guard let controller = controllerProvider(),
              let score = scoreProvider() else { return }
        await controller.setLoopRange(activeLoopRange(in: score))
    }

    private func activeLoopRange(in score: Score) -> ABRepeatRange? {
        switch mode {
        case .off: nil
        case .loopAll: scoreFullRange(in: score)
        case .abLoop: abRange
        }
    }

    private func commitPending() async {
        let candidateStart = pendingA ?? abRange?.start
        let candidateEnd = pendingB ?? abRange?.end
        guard let start = candidateStart, let end = candidateEnd else {
            if abRange != nil {
                abRange = nil
                await onChange?()
            }
            return
        }
        let normalized = normalize(ABRepeatRange(start: start, end: end))
        pendingA = normalized.start
        pendingB = normalized.end
        abRange = normalized
        await onChange?()
    }
}
