import Foundation
import ReaderInteractionCore
import SwiftUI

/// SwiftUI's host for the shared coach-mark engine: the same `ReaderHintEngine` Android's bridge drives, wrapped so
/// the Reader's views can observe it.
///
/// A process-wide singleton on purpose. The "at most one hint per launch" budget has to hold across every Reader the
/// user opens in that launch, and an instance owned by `ReaderRootScreen` would reset its budget on every score they
/// opened.
///
/// Everything about *which* hint is due, *when* it may be offered and *when it retires* lives in the engine, which is
/// platform-neutral (`ReaderInteractionCore`). What this type adds is the three things that cannot cross a JNI
/// boundary: `@Observable` mirroring, `UserDefaults`, and `Task`-based delays.
@MainActor
@Observable
final class ReaderHintCoordinator {
    static let shared = ReaderHintCoordinator()

    /// The single on-screen slot. `nil` == nothing shown. Mirrored out of the engine so SwiftUI has something to
    /// observe; the engine itself is deliberately observation-free so it can also run under Compose.
    private(set) var presentedHint: ReaderFeatureHint?

    /// Bumped when the user taps the transport-swipe coach mark. The transport watches this and performs the same mode
    /// change a swipe would — including the slide — so the bubble teaches the gesture by doing it.
    private(set) var transportModeSwitchRequests: Int32 = 0

    /// Mirrored anchors. Read through `anchor(for:)`, and observed: a control that moves has to move the bubble
    /// pointing at it on the same frame.
    private var anchorRects: [ReaderHintTarget: ReaderHintRect] = [:]

    @ObservationIgnored private let engine: ReaderHintEngine
    @ObservationIgnored private let scheduler: TaskHintScheduler

    init(defaults: UserDefaults = .standard) {
        let scheduler = TaskHintScheduler()
        engine = ReaderHintEngine(persistence: UserDefaultsHintPersistence(defaults: defaults), scheduler: scheduler)
        self.scheduler = scheduler
        scheduler.engine = engine
        // `sync` reads the engine, so it can only be installed once `self` is fully formed. The engine's callback is
        // deliberately un-isolated (it also has to fire under Compose); every call into it comes from the main actor,
        // which is what `assumeIsolated` is asserting here.
        engine.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    private func sync() {
        presentedHint = engine.presentedHint
        transportModeSwitchRequests = engine.transportModeSwitchRequests
        anchorRects = Dictionary(
            uniqueKeysWithValues: ReaderHintTarget.allCases.compactMap { target in
                engine.anchor(for: target).map { (target, $0) }
            },
        )
    }

    func setEditing(_ editing: Bool) {
        engine.setEditing(editing)
    }

    // MARK: - Anchors

    func anchor(for target: ReaderHintTarget) -> CGRect? {
        anchorRects[target].map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    var hasAnyAnchor: Bool {
        !anchorRects.isEmpty
    }

    func setAnchor(_ rect: CGRect, for target: ReaderHintTarget) {
        engine.setAnchor(
            ReaderHintRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
            for: target,
        )
    }

    func clearAnchor(for target: ReaderHintTarget) {
        engine.clearAnchor(for: target)
    }

    func clearAllAnchors() {
        engine.clearAllAnchors()
    }

    // MARK: - Usage tracking

    func hasUsed(_ hint: ReaderFeatureHint) -> Bool {
        engine.hasUsed(hint)
    }

    func markUsed(_ hint: ReaderFeatureHint) {
        engine.markUsed(hint)
    }

    // MARK: - Offering

    func offerRotationHint() {
        engine.offerRotationHint()
    }

    func offerPadGestureHint() {
        engine.offerPadGestureHint()
    }

    func schedulePadMoveHint() {
        engine.schedulePadMoveHint()
    }

    func present(_ hint: ReaderFeatureHint) {
        engine.present(hint)
    }

    func dismiss() {
        engine.dismiss()
    }

    /// Asks the transport to switch modes, as if the coach mark's own swipe had been performed.
    func requestTransportModeSwitch() {
        engine.requestTransportModeSwitch()
    }

    /// QA / Settings reset: forget every "used" flag and the rotation cursor, and re-arm this launch's budget.
    func reset() {
        engine.reset()
    }

    /// See `ReaderHintEngine.ignoresPerLaunchBudget`.
    var ignoresPerLaunchBudget: Bool {
        get { engine.ignoresPerLaunchBudget }
        set { engine.ignoresPerLaunchBudget = newValue }
    }
}

/// `UserDefaults` as the engine's store. Nothing but a spelling change — the keys are the engine's, so an iOS build
/// and an Android build agree on what "this hint has been used" is called.
private final class UserDefaultsHintPersistence: ReaderHintPersistence {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func integer(forKey key: String) -> Int32 {
        Int32(defaults.integer(forKey: key))
    }

    func setInteger(_ value: Int32, forKey key: String) {
        defaults.set(Int(value), forKey: key)
    }

    func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// Deferred offers as cancellable `Task`s on the main actor — the delays the engine asks for, run the way SwiftUI
/// wants them run.
@MainActor
private final class TaskHintScheduler: ReaderHintScheduler {
    /// Set once, right after the engine is built. Weak because the engine owns the scheduler.
    weak var engine: ReaderHintEngine?

    private var tasks: [ReaderHintDeferredOffer: Task<Void, Never>] = [:]

    nonisolated func schedule(_ offer: ReaderHintDeferredOffer, after delay: Double) {
        MainActor.assumeIsolated {
            tasks[offer]?.cancel()
            tasks[offer] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                tasks[offer] = nil
                engine?.fireDeferredOffer(offer)
            }
        }
    }

    nonisolated func cancel(_ offer: ReaderHintDeferredOffer) {
        MainActor.assumeIsolated {
            tasks[offer]?.cancel()
            tasks[offer] = nil
        }
    }
}

/// The one thing outside this feature is allowed to do to the coach marks: start them over. Kept as a two-line facade
/// so the coordinator itself — which the Reader's own views drive through `ReaderHintCoordinator.shared` — stays
/// internal rather than becoming public API for the sake of one QA button.
public enum ReaderHints {
    /// Forgets every "already used" flag and the rotation cursor, and re-arms this launch's budget, so the next Reader
    /// opened offers a hint again. Wired to the app's DEBUG menu.
    @MainActor
    public static func resetAll() {
        ReaderHintCoordinator.shared.reset()
    }

    /// See `ReaderHintEngine.ignoresPerLaunchBudget` — with this on, every Reader opened offers the next hint,
    /// which is what makes checking each one's placement a matter of going back and in again rather than relaunching.
    @MainActor
    public static var ignoresPerLaunchBudget: Bool {
        get { ReaderHintCoordinator.shared.ignoresPerLaunchBudget }
        set { ReaderHintCoordinator.shared.ignoresPerLaunchBudget = newValue }
    }
}
