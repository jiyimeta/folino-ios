import Domain
import Foundation
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
    /// Global, sticky repeat mode (shared across every score, like the playlist-continuation mode). SwiftUI bindings
    /// write through `mode` directly; the `didSet` persists to the global key synchronously and defers the controller
    /// push to a Task. The A–B endpoints (`abRange`) stay per-score. Tests use `setMode(_:)` to await the push.
    var mode: RepeatMode = .off {
        didSet {
            guard mode != oldValue, !isSyncing else { return }
            RepeatModeStorage.set(mode)
            Task { [weak self] in
                await self?.forwardLoopRangeToController()
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

    /// Watches `UserDefaults` for external writes to the global repeat-mode key (e.g. from Settings) so an already-open
    /// Reader reflects them live and re-pushes its loop range. Cancelled on deinit.
    @ObservationIgnored private var globalModeObservation: Task<Void, Never>?

    /// Either the user's staged A endpoint (a candidate that hasn't yet formed a complete loop) or the persisted start
    /// of an existing `abRange`. Callers don't care which — they just want "what point represents A right now."
    var pendingRepeatA: ChordPath? {
        pendingA ?? abRange?.start
    }

    var pendingRepeatB: ChordPath? {
        pendingB ?? abRange?.end
    }

    /// Apply persisted state on load: the repeat *mode* comes from the global key (sticky across scores) and the A–B
    /// endpoints from this score's `ReaderPreferences`. Resets the in-flight endpoints — they're UI-transient and don't
    /// survive a fresh load.
    func sync(from prefs: ReaderPreferences) {
        isSyncing = true
        defer { isSyncing = false }
        mode = RepeatModeStorage.current()
        abRange = prefs.abRepeat
        pendingA = nil
        pendingB = nil
    }

    /// Begins watching the global repeat-mode key. Idempotent. Call once after the parent finishes wiring.
    func startObservingGlobalMode() {
        guard globalModeObservation == nil else { return }
        globalModeObservation = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                guard let self else { return }
                let latest = RepeatModeStorage.current()
                guard latest != mode else { continue }
                isSyncing = true
                mode = latest
                isSyncing = false
                await forwardLoopRangeToController()
            }
        }
    }

    deinit {
        globalModeObservation?.cancel()
    }

    /// Awaitable counterpart to the `mode` binding setter. Tests and any async context that needs to observe
    /// persistence + loop-range push before continuing should use this.
    func setMode(_ value: RepeatMode) async {
        guard value != mode else { return }
        isSyncing = true
        mode = value
        isSyncing = false
        RepeatModeStorage.set(value)
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
