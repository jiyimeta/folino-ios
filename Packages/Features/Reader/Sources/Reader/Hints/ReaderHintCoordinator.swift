import Foundation
import SwiftUI

/// Owns the Reader's single on-screen hint slot: which hint is showing, where its control is, and the round-robin that
/// decides what to offer next.
///
/// A process-wide singleton on purpose. The "at most one hint per launch" budget has to hold across every Reader the
/// user opens in that launch, and an instance owned by `ReaderRootScreen` would reset its budget on every score they
/// opened. The persisted parts (per-feature "used" flags, the rotation cursor) live in `UserDefaults`; the slot itself
/// and the two per-launch guards are deliberately in-memory only.
@MainActor
@Observable
final class ReaderHintCoordinator {
    static let shared = ReaderHintCoordinator()

    /// The single on-screen slot. `nil` == nothing shown. Session-only, never persisted.
    ///
    /// No timeout: a bubble stays until the screen is tapped (anywhere — see `TapThroughObserver`). A coach mark that
    /// expires on its own can vanish mid-read, and the tap that dismisses it is never wasted, since it still reaches
    /// whatever it landed on.
    private(set) var presentedHint: ReaderFeatureHint?

    /// Bumped when the user taps the transport-swipe coach mark. The transport watches this and performs the same mode
    /// change a swipe would — including the slide — so the bubble teaches the gesture by doing it.
    private(set) var transportModeSwitchRequests = 0

    /// Global-coordinate frames of the controls hints point at, reported by `readerHintAnchor(_:)`.
    private var anchors: [ReaderHintTarget: CGRect] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    /// The per-launch budget: one rotation hint, plus (independently) one pad-gesture hint.
    @ObservationIgnored private var didOfferRotationHintThisLaunch = false
    @ObservationIgnored private var didOfferPadGestureHintThisLaunch = false
    /// Pending "the transport just went compact" offer (see `scheduleTransportExpandHint`).
    @ObservationIgnored private var transportExpandOfferTask: Task<Void, Never>?
    /// Pending pad-chain offers: "bring it back" after a tuck, "move it" after a restore.
    @ObservationIgnored private var padRestoreOfferTask: Task<Void, Never>?
    @ObservationIgnored private var padMoveOfferTask: Task<Void, Never>?
    /// Mirrored from the editing seam. Edit mode forces the transport compact and declines mode swipes, so the
    /// expand hint has to stay away for the duration — it would be teaching a gesture that currently does nothing.
    @ObservationIgnored private var isEditing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        if editing {
            transportExpandOfferTask?.cancel()
            if presentedHint == .transportExpand {
                dismiss()
            }
        } else {
            // The pad chain only makes sense inside an edit session; a pending offer must not land on the Reader.
            padRestoreOfferTask?.cancel()
            padMoveOfferTask?.cancel()
        }
    }

    // MARK: - Anchors

    func anchor(for target: ReaderHintTarget) -> CGRect? {
        anchors[target]
    }

    /// Whether any hintable control has reported itself yet — i.e. whether the Reader's chrome has laid out. The cue
    /// callers wait on before offering, since selection is driven entirely by which anchors exist.
    var hasAnyAnchor: Bool {
        !anchors.isEmpty
    }

    /// Records where a hintable control is. Guarded on change so the geometry callbacks a scroll or a morph fires
    /// don't invalidate the overlay on every frame.
    func setAnchor(_ rect: CGRect, for target: ReaderHintTarget) {
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
    }

    /// Forgets a control that has left the screen, and takes any hint pointing at it down with it — a bubble whose
    /// caret points at nothing is worse than no bubble.
    func clearAnchor(for target: ReaderHintTarget) {
        guard anchors.removeValue(forKey: target) != nil else { return }
        if target == .transportCompact {
            transportExpandOfferTask?.cancel()
        }
        if target == .noteInputPadHandle {
            padRestoreOfferTask?.cancel()
        }
        if target == .noteInputPad {
            padMoveOfferTask?.cancel()
        }
        if presentedHint?.target == target {
            dismiss()
        }
    }

    /// Drops every anchor, for when the Reader itself goes away. Anchors are reported by the controls that draw them,
    /// so a Reader that never re-renders a control would otherwise leave a stale frame behind for the next one.
    func clearAllAnchors() {
        transportExpandOfferTask?.cancel()
        guard !anchors.isEmpty else { return }
        anchors.removeAll()
        dismiss()
    }

    // MARK: - Usage tracking

    func hasUsed(_ hint: ReaderFeatureHint) -> Bool {
        defaults.bool(forKey: Self.usedKey(hint))
    }

    /// Records that the user has actually used the feature — the hint retires permanently — and takes its bubble down
    /// if it happens to be the one showing (they clearly didn't need it).
    func markUsed(_ hint: ReaderFeatureHint) {
        if !hasUsed(hint) {
            defaults.set(true, forKey: Self.usedKey(hint))
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
    func offerRotationHint() {
        guard ignoresPerLaunchBudget || !didOfferRotationHintThisLaunch, presentedHint == nil else { return }
        guard let hint = Self.selectHint(
            order: ReaderFeatureHint.rotationOrder,
            cursor: cursor,
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
    ///
    /// The delay lets the collapse animation land first — arriving mid-morph, the caret would point at a pill that is
    /// still moving.
    private func scheduleTransportExpandHint() {
        guard !hasUsed(.transportExpand), !isEditing else { return }
        transportExpandOfferTask?.cancel()
        transportExpandOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self, !hasUsed(.transportExpand), !isEditing else { return }
            guard anchors[.transportCompact] != nil else { return }
            present(.transportExpand)
        }
    }

    /// Offer the pad chain's next unspent step on entering an edit session — the chain's SAFETY NET. The in-the-
    /// moment offers ride the gestures' own consequences (`schedulePadRestoreHint` off the tab's appearance,
    /// `schedulePadMoveHint` off a restore), but a chain abandoned mid-way — a bubble dismissed, a session left with
    /// the pad tucked — must not be lost forever, so every entry re-derives where the chain stands and offers that:
    /// pad out and never tucked → `padHide`; pad out, tuck taught, move never performed → `padMove` (the pad being
    /// out again means a restore has happened); pad currently tucked and the tab never used → `padRestore`.
    /// Independent of the rotation and of its per-launch budget (the user has just walked into the pad), but still
    /// at most one per launch, and each step retires for good once its gesture has actually been performed.
    func offerPadGestureHint() {
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
        padRestoreOfferTask?.cancel()
        padRestoreOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self, !hasUsed(.padRestore), isEditing else { return }
            guard anchors[.noteInputPadHandle] != nil else { return }
            present(.padRestore)
        }
    }

    /// Offer "drag it up / down", shortly after a restore has landed the pad back on the score — the chain's last
    /// step. Skipped forever once the user has actually moved the pad between docks, taught or not.
    func schedulePadMoveHint() {
        guard !hasUsed(.padMove), isEditing else { return }
        padMoveOfferTask?.cancel()
        padMoveOfferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, let self, !hasUsed(.padMove), isEditing else { return }
            guard anchors[.noteInputPad] != nil else { return }
            present(.padMove)
        }
    }

    /// Fill the slot. Replaces whatever was showing — a rotation hint pointing at the toolbar has no business staying
    /// up over an edit session that just began.
    func present(_ hint: ReaderFeatureHint) {
        presentedHint = hint
    }

    func dismiss() {
        presentedHint = nil
    }

    /// Asks the transport to switch modes, as if the coach mark's own swipe had been performed.
    func requestTransportModeSwitch() {
        transportModeSwitchRequests += 1
    }

    /// QA / Settings reset: forget every "used" flag and the rotation cursor, and re-arm this launch's budget.
    func reset() {
        dismiss()
        for hint in ReaderFeatureHint.allCases {
            defaults.removeObject(forKey: Self.usedKey(hint))
        }
        defaults.removeObject(forKey: Keys.cursor)
        didOfferRotationHintThisLaunch = false
        didOfferPadGestureHintThisLaunch = false
    }

    // MARK: - Rotation

    /// Pure round-robin pick: the first eligible hint at/after `cursor` (wrapping), or `nil` when none is. Static and
    /// side-effect free so it unit-tests without the singleton.
    static func selectHint(
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

    private var cursor: Int {
        get { defaults.integer(forKey: Keys.cursor) }
        set { defaults.set(newValue, forKey: Keys.cursor) }
    }

    // MARK: - QA

    /// Stops enforcing the one-hint-per-launch budgets, so EVERY Reader opened offers the next hint in the rotation.
    ///
    /// Checking a coach mark's placement otherwise costs a relaunch per hint: the rotation spends its single offer on
    /// whichever hint the cursor lands on, and the reset that re-arms it also rewinds the cursor to the transport —
    /// which is why "reset, then look at the toolbar hints" shows the transport one and nothing else. Persisted, so it
    /// survives the relaunch that installing a new build forces. Driven from the app's DEBUG menu; nothing in a
    /// shipping build can turn it on.
    var ignoresPerLaunchBudget: Bool {
        get { defaults.bool(forKey: Keys.ignoresPerLaunchBudget) }
        set { defaults.set(newValue, forKey: Keys.ignoresPerLaunchBudget) }
    }

    private func advanceCursor(past hint: ReaderFeatureHint) {
        guard let index = ReaderFeatureHint.rotationOrder.firstIndex(of: hint) else { return }
        cursor = (index + 1) % ReaderFeatureHint.rotationOrder.count
    }

    /// Internal rather than private so the screenshot harness can retire every hint up front without duplicating the
    /// key format — a marketing shot must never carry a coach mark.
    nonisolated static func usedKey(_ hint: ReaderFeatureHint) -> String {
        "readerHint.used.\(hint.rawValue)"
    }

    private enum Keys {
        static let cursor = "readerHint.cursor"
        static let ignoresPerLaunchBudget = "readerHint.debug.ignoresPerLaunchBudget"
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

    /// See `ReaderHintCoordinator.ignoresPerLaunchBudget` — with this on, every Reader opened offers the next hint,
    /// which is what makes checking each one's placement a matter of going back and in again rather than relaunching.
    @MainActor
    public static var ignoresPerLaunchBudget: Bool {
        get { ReaderHintCoordinator.shared.ignoresPerLaunchBudget }
        set { ReaderHintCoordinator.shared.ignoresPerLaunchBudget = newValue }
    }
}
