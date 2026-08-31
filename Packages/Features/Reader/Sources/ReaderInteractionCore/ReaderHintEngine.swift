import Foundation

/// Where the coach marks' persisted state lives — the per-feature "already used" flags, the rotation cursor, and the
/// QA override. Sync on purpose: every read happens inside a decision the engine has to answer in one go, and an
/// `async` read would make "is this hint eligible" a suspension point in the middle of a round-robin.
///
/// iOS backs this with `UserDefaults`; Android with the same key-value store its other Reader preferences use. The
/// key strings themselves are the engine's (`ReaderFeatureHint.usedKey`, `ReaderHintEngineKeys`), so the two
/// platforms cannot drift into spelling them differently.
public protocol ReaderHintPersistence: AnyObject {
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
    func integer(forKey key: String) -> Int32
    func setInteger(_ value: Int32, forKey key: String)
    func removeObject(forKey key: String)
}

/// The three offers that ride a control's *appearance* rather than a user action, and therefore have to be deferred
/// and cancellable.
public enum ReaderHintDeferredOffer: String, Sendable {
    case transportExpand
    case padRestore
    case padMove
}

/// Runs a deferred offer, and forgets one that is no longer wanted.
///
/// The engine never sleeps: it says *what* should be offered and *how long from now*, and the host runs it on
/// whatever its own idea of a cancellable delayed task is (a `Task` on iOS, a coroutine on Android), then calls
/// `ReaderHintEngine.fireDeferredOffer(_:)` back. Keeping Swift Concurrency out of the engine is deliberate — the
/// bridge's synchronous witnesses across the JNI boundary are the one place where a `MainActor` requirement has
/// bitten before.
///
/// No closure crosses this seam, only the offer's name: a callback would have to be `Sendable` to be handed to a
/// `Task`, which the engine's own closures cannot be, and nothing that has to survive a JNI boundary should be a
/// function value in the first place.
///
/// Scheduling the same `offer` again replaces the pending one.
public protocol ReaderHintScheduler: AnyObject {
    func schedule(_ offer: ReaderHintDeferredOffer, after delay: Double)
    func cancel(_ offer: ReaderHintDeferredOffer)
}

/// Owns the Reader's single on-screen hint slot: which hint is showing, where its control is, and the round-robin that
/// decides what to offer next.
///
/// One instance per process on purpose. The "at most one hint per launch" budget has to hold across every Reader the
/// user opens in that launch, and an instance owned by the Reader screen would reset its budget on every score they
/// opened. The persisted parts (per-feature "used" flags, the rotation cursor) go through `ReaderHintPersistence`;
/// the slot itself and the two per-launch guards are deliberately in-memory only.
///
/// **Platform-neutral, and that is the point.** What makes this one feature on two platforms is not the bubble — it
/// is the sequencing: one slot, a round-robin filtered by what is actually on screen, two per-launch budgets, two
/// unbudgeted offers that ride a consequence, and permanent retirement the first time the feature is used for real.
/// Re-deriving that in Kotlin would produce coach marks that resemble iOS's rather than being them. The hosts own
/// only their observation idiom (`@Observable` / `@WireletObservable`), their persistence and their drawing.
///
/// Not thread-safe and not actor-isolated: drive it from the UI thread on both platforms.
public final class ReaderHintEngine {
    /// The single on-screen slot. `nil` == nothing shown. Session-only, never persisted.
    ///
    /// No timeout: a bubble stays until the screen is tapped (anywhere). A coach mark that expires on its own can
    /// vanish mid-read, and the tap that dismisses it is never wasted, since it still reaches whatever it landed on.
    public private(set) var presentedHint: ReaderFeatureHint?

    /// Bumped when the user taps the transport-swipe coach mark. The transport watches this and performs the same mode
    /// change a swipe would — including the slide — so the bubble teaches the gesture by doing it.
    public private(set) var transportModeSwitchRequests: Int32 = 0

    /// Called after any change a host would want to re-render for: the slot, the anchors, or the switch request
    /// counter.
    public var onChange: (() -> Void)?

    /// How long to wait after a hintable control appears before offering the hint that rides its appearance. Long
    /// enough for the animation that brought the control on screen to land: arriving mid-morph, the caret would point
    /// at something still moving.
    public static let appearanceOfferDelay = 0.6

    /// Window-coordinate frames of the controls hints point at.
    private var anchors: [ReaderHintTarget: ReaderHintRect] = [:]

    private let persistence: ReaderHintPersistence
    private let scheduler: ReaderHintScheduler

    /// The per-launch budget: one rotation hint, plus (independently) one pad-gesture hint.
    private var didOfferRotationHintThisLaunch = false
    private var didOfferPadGestureHintThisLaunch = false

    /// Mirrored from the editing seam. Edit mode forces the transport compact and declines mode swipes, so the
    /// expand hint has to stay away for the duration — it would be teaching a gesture that currently does nothing.
    private var isEditing = false

    public init(persistence: ReaderHintPersistence, scheduler: ReaderHintScheduler) {
        self.persistence = persistence
        self.scheduler = scheduler
    }

    public func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            scheduler.cancel(.transportExpand)
            if presentedHint == .transportExpand {
                dismiss()
            }
        } else {
            // The pad chain only makes sense inside an edit session; a pending offer must not land on the Reader.
            scheduler.cancel(.padRestore)
            scheduler.cancel(.padMove)
        }
    }

    // MARK: - Anchors

    public func anchor(for target: ReaderHintTarget) -> ReaderHintRect? {
        anchors[target]
    }

    /// Whether any hintable control has reported itself yet — i.e. whether the Reader's chrome has laid out. The cue
    /// callers wait on before offering, since selection is driven entirely by which anchors exist.
    public var hasAnyAnchor: Bool {
        !anchors.isEmpty
    }

    /// Records where a hintable control is. Guarded on change so the geometry callbacks a scroll or a morph fires
    /// don't invalidate the overlay on every frame.
    public func setAnchor(_ rect: ReaderHintRect, for target: ReaderHintTarget) {
        let isFirstReport = anchors[target] == nil
        guard anchors[target] != rect else { return }
        anchors[target] = rect
        // The compact transport appearing IS the trigger for its own hint — on opening a Reader that is already
        // compact, and on the swipe (or bubble tap) that just shrank it.
        if isFirstReport, target == .transportCompact {
            scheduleTransportExpandHint()
        }
        // Same shape for the pad's pull tab: its appearance is the consequence of the tuck the previous hint taught,
        // and the moment to say how to undo it.
        if isFirstReport, target == .noteInputPadHandle {
            schedulePadRestoreHint()
        }
        onChange?()
    }

    /// Forgets a control that has left the screen, and takes any hint pointing at it down with it — a bubble whose
    /// caret points at nothing is worse than no bubble.
    public func clearAnchor(for target: ReaderHintTarget) {
        guard anchors.removeValue(forKey: target) != nil else { return }
        if target == .transportCompact {
            scheduler.cancel(.transportExpand)
        }
        if target == .noteInputPadHandle {
            scheduler.cancel(.padRestore)
        }
        if target == .noteInputPad {
            scheduler.cancel(.padMove)
        }
        if presentedHint?.target == target {
            dismiss()
        }
        onChange?()
    }

    /// Drops every anchor, for when the Reader itself goes away. Anchors are reported by the controls that draw them,
    /// so a Reader that never re-renders a control would otherwise leave a stale frame behind for the next one.
    public func clearAllAnchors() {
        scheduler.cancel(.transportExpand)
        guard !anchors.isEmpty else { return }
        anchors.removeAll()
        dismiss()
        onChange?()
    }

    // MARK: - Usage tracking

    public func hasUsed(_ hint: ReaderFeatureHint) -> Bool {
        persistence.bool(forKey: hint.usedKey)
    }

    /// Records that the user has actually used the feature — the hint retires permanently — and takes its bubble down
    /// if it happens to be the one showing (they clearly didn't need it).
    public func markUsed(_ hint: ReaderFeatureHint) {
        if !hasUsed(hint) {
            persistence.setBool(true, forKey: hint.usedKey)
        }
        if presentedHint == hint {
            dismiss()
        }
    }

    // MARK: - Offering

    /// Offer the next due rotation hint, if this launch hasn't spent its one already and the control it points at is
    /// currently on screen.
    ///
    /// "On screen" is answered by the anchors themselves rather than by re-deriving the Reader's state: a control that
    /// isn't rendered never reports a frame, so a PDF (no note-editing button) or a still-loading score (no
    /// inspectors) simply has no anchor for it. A hint whose control is missing is skipped WITHOUT advancing the
    /// cursor past it, so it comes up again in a Reader that does show it.
    public func offerRotationHint() {
        guard ignoresPerLaunchBudget || !didOfferRotationHintThisLaunch, presentedHint == nil else { return }
        guard let hint = Self.selectHint(
            order: ReaderFeatureHint.rotationOrder,
            cursor: Int(cursor),
            isEligible: { [self] in !hasUsed($0) && anchors[$0.target] != nil },
        ) else { return }
        didOfferRotationHintThisLaunch = true
        advanceCursor(past: hint)
        present(hint)
    }

    /// Offer the compact transport's "swipe left to bring it back" hint, shortly after the pill appears.
    ///
    /// Deliberately unbudgeted: not the rotation's one-per-launch, not one-per-launch of its own. A compact pill
    /// advertises nothing about the card it replaced, and the single best moment to say so is the beat right after
    /// the user shrank it — which is precisely the moment a spent per-launch budget would suppress. It still retires
    /// for good the first time the expand gesture is actually used, so it cannot become noise.
    ///
    /// It also outranks whatever else is showing: a hint about some other control is stale the instant the transport
    /// changes shape under it.
    private func scheduleTransportExpandHint() {
        guard !hasUsed(.transportExpand), !isEditing else { return }
        scheduler.schedule(.transportExpand, after: Self.appearanceOfferDelay)
    }

    /// Offer the pad chain's next unspent step on entering an edit session — the chain's SAFETY NET. The in-the-
    /// moment offers ride the gestures' own consequences (`schedulePadRestoreHint` off the tab's appearance,
    /// `schedulePadMoveHint` off a restore), but a chain abandoned mid-way — a bubble dismissed, a session left with
    /// the pad tucked — must not be lost forever, so every entry re-derives where the chain stands and offers that:
    /// pad out and never tucked → `padHide`; pad out, tuck taught, move never performed → `padMove` (the pad being
    /// out again means a restore has happened); pad currently tucked and the tab never used → `padRestore`.
    /// Independent of the rotation and of its per-launch budget (the user has just walked into the pad), but still
    /// at most one per launch, and each step retires for good once its gesture has actually been performed.
    public func offerPadGestureHint() {
        guard ignoresPerLaunchBudget || !didOfferPadGestureHintThisLaunch else { return }
        let hint: ReaderFeatureHint? = if anchors[.noteInputPad] != nil {
            if !hasUsed(.padHide) {
                .padHide
            } else if !hasUsed(.padMove) {
                .padMove
            } else {
                nil
            }
        } else if anchors[.noteInputPadHandle] != nil, !hasUsed(.padRestore) {
            .padRestore
        } else {
            nil
        }
        guard let hint else { return }
        didOfferPadGestureHintThisLaunch = true
        present(hint)
    }

    /// Offer "tap or pull the tab to bring it back", shortly after the tab appears — the beat after the tuck the
    /// previous hint taught. Unbudgeted for the same reason `scheduleTransportExpandHint` is: the single best moment
    /// is right after the pad vanished, which is precisely the moment a spent budget would suppress. Retires for
    /// good the first time a restore is actually performed.
    private func schedulePadRestoreHint() {
        guard !hasUsed(.padRestore), isEditing else { return }
        scheduler.schedule(.padRestore, after: Self.appearanceOfferDelay)
    }

    /// Offer "drag it up / down", shortly after a restore has landed the pad back on the score — the chain's last
    /// step. Skipped forever once the user has actually moved the pad between docks, taught or not.
    public func schedulePadMoveHint() {
        guard !hasUsed(.padMove), isEditing else { return }
        scheduler.schedule(.padMove, after: Self.appearanceOfferDelay)
    }

    /// The host's delay for `offer` has elapsed. Re-checks everything that could have changed while it ran — the
    /// feature may have been used, an edit session may have started or ended, the control may have left the screen —
    /// because a coach mark is only ever worth showing for the state it describes.
    ///
    /// Safe to call for an offer that was cancelled: every case re-derives its own preconditions, so a late callback
    /// from a timer the host failed to cancel is a no-op rather than a stray bubble.
    public func fireDeferredOffer(_ offer: ReaderHintDeferredOffer) {
        switch offer {
        case .transportExpand:
            guard !hasUsed(.transportExpand), !isEditing, anchors[.transportCompact] != nil else { return }
            present(.transportExpand)
        case .padRestore:
            guard !hasUsed(.padRestore), isEditing, anchors[.noteInputPadHandle] != nil else { return }
            present(.padRestore)
        case .padMove:
            guard !hasUsed(.padMove), isEditing, anchors[.noteInputPad] != nil else { return }
            present(.padMove)
        }
    }

    /// Fill the slot. Replaces whatever was showing — a rotation hint pointing at the toolbar has no business staying
    /// up over an edit session that just began.
    public func present(_ hint: ReaderFeatureHint) {
        presentedHint = hint
        onChange?()
    }

    public func dismiss() {
        guard presentedHint != nil else { return }
        presentedHint = nil
        onChange?()
    }

    /// Asks the transport to switch modes, as if the coach mark's own swipe had been performed.
    public func requestTransportModeSwitch() {
        transportModeSwitchRequests += 1
        onChange?()
    }

    /// QA / Settings reset: forget every "used" flag and the rotation cursor, and re-arm this launch's budget.
    public func reset() {
        dismiss()
        for hint in ReaderFeatureHint.allCases {
            persistence.removeObject(forKey: hint.usedKey)
        }
        persistence.removeObject(forKey: ReaderHintEngineKeys.cursor)
        didOfferRotationHintThisLaunch = false
        didOfferPadGestureHintThisLaunch = false
    }

    // MARK: - Rotation

    /// Pure round-robin pick: the first eligible hint at/after `cursor` (wrapping), or `nil` when none is. Static and
    /// side-effect free so it unit-tests without a host.
    public static func selectHint(
        order: [ReaderFeatureHint],
        cursor: Int,
        isEligible: (ReaderFeatureHint) -> Bool,
    ) -> ReaderFeatureHint? {
        guard !order.isEmpty else { return nil }
        let start = ((cursor % order.count) + order.count) % order.count
        for offset in 0 ..< order.count {
            let hint = order[(start + offset) % order.count]
            if isEligible(hint) {
                return hint
            }
        }
        return nil
    }

    private var cursor: Int32 {
        get { persistence.integer(forKey: ReaderHintEngineKeys.cursor) }
        set { persistence.setInteger(newValue, forKey: ReaderHintEngineKeys.cursor) }
    }

    // MARK: - QA

    /// Stops enforcing the one-hint-per-launch budgets, so EVERY Reader opened offers the next hint in the rotation.
    ///
    /// Checking a coach mark's placement otherwise costs a relaunch per hint: the rotation spends its single offer on
    /// whichever hint the cursor lands on, and the reset that re-arms it also rewinds the cursor to the transport —
    /// which is why "reset, then look at the toolbar hints" shows the transport one and nothing else. Persisted, so it
    /// survives the relaunch that installing a new build forces. Driven from the app's debug menu; nothing in a
    /// shipping build can turn it on.
    public var ignoresPerLaunchBudget: Bool {
        get { persistence.bool(forKey: ReaderHintEngineKeys.ignoresPerLaunchBudget) }
        set { persistence.setBool(newValue, forKey: ReaderHintEngineKeys.ignoresPerLaunchBudget) }
    }

    private func advanceCursor(past hint: ReaderFeatureHint) {
        guard let index = ReaderFeatureHint.rotationOrder.firstIndex(of: hint) else { return }
        cursor = Int32((index + 1) % ReaderFeatureHint.rotationOrder.count)
    }
}

/// The non-per-hint persistence keys. Shared so neither platform has to restate them — see
/// `ReaderFeatureHint.usedKey` for the per-hint half.
public enum ReaderHintEngineKeys {
    public static let cursor = "readerHint.cursor"
    public static let ignoresPerLaunchBudget = "readerHint.debug.ignoresPerLaunchBudget"
}
