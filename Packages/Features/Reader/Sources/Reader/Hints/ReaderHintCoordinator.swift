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
    /// The per-launch budget: one rotation hint, plus (independently) one note-pad hint.
    @ObservationIgnored private var didOfferRotationHintThisLaunch = false
    @ObservationIgnored private var didOfferNotePadHintThisLaunch = false
    /// Pending "the transport just went compact" offer (see `scheduleTransportExpandHint`).
    @ObservationIgnored private var transportExpandOfferTask: Task<Void, Never>?
    /// Pending re-measure of the navigation bar (see `scheduleBarRefresh`).
    @ObservationIgnored private var barRefreshTask: Task<Void, Never>?
    /// Mirrored from the editing seam. Edit mode forces the transport compact and declines mode swipes, so the
    /// expand hint has to stay away for the duration — it would be teaching a gesture that currently does nothing.
    @ObservationIgnored private var isEditing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func setEditing(_ editing: Bool) {
        isEditing = editing
        guard editing else { return }
        transportExpandOfferTask?.cancel()
        if presentedHint == .transportExpand { dismiss() }
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
        if isFirstReport, target == .transportCompact { scheduleTransportExpandHint() }
    }

    // MARK: - Bar-hosted controls

    /// The bar-hosted controls currently on screen. They report their PRESENCE rather than their position, because a
    /// navigation-bar item cannot measure itself (see `ReaderBarItemLocator`); the position comes from matching this
    /// set against the bar's measured items.
    private var barTargets: [ReaderHintTarget: ReaderBarSlot] = [:]
    /// The Reader's own area in the window, which is how the right bar gets picked on iPad. Reported by the hint
    /// overlay, which is the one part of this feature that lives in the Reader's own view tree.
    private var readerRegion: CGRect = .zero

    /// `slot: nil` withdraws the control — it has left the bar, so its hint goes with it.
    func registerBarTarget(_ target: ReaderHintTarget, slot: ReaderBarSlot?) {
        guard barTargets[target] != slot else { return }
        barTargets[target] = slot
        if slot == nil { clearAnchor(for: target) }
        scheduleBarRefresh()
    }

    func setReaderRegion(_ region: CGRect) {
        guard readerRegion != region else { return }
        readerRegion = region
        scheduleBarRefresh()
    }

    /// Matches the bar's measured items to the registered controls by counting in from each end.
    ///
    /// A control whose ordinal is past the end of what was measured — or one that would have to be the same item as a
    /// control counted in from the other end — is left WITHOUT an anchor, which drops its hint entirely. Refusing to
    /// answer is the right failure here: a caret pointing at the wrong button is worse than no bubble at all.
    func refreshBarAnchors() {
        guard !barTargets.isEmpty else { return }
        guard let measured = ReaderBarItemLocator.itemFrames(servingRegionInWindow: readerRegion) else {
            for target in barTargets.keys {
                clearAnchor(for: target)
            }
            return
        }

        // Each end is walked outward-in from its own edge, nearest item first.
        let leading = barTargets.compactMap { target, slot -> (ReaderHintTarget, Int)? in
            if case let .leading(order) = slot { (target, order) } else { nil }
        }.sorted { $0.1 < $1.1 }
        let trailing = barTargets.compactMap { target, slot -> (ReaderHintTarget, Int)? in
            if case let .trailing(order) = slot { (target, order) } else { nil }
        }.sorted { $0.1 > $1.1 }

        let items = measured.items
        for (offset, entry) in leading.enumerated() {
            assign(items, index: offset, reservedFromOtherEnd: trailing.count, to: entry.0)
        }
        for (offset, entry) in trailing.enumerated() {
            assign(items, index: items.count - 1 - offset, reservedFromOtherEnd: leading.count, to: entry.0)
        }
    }

    private func assign(_ items: [CGRect], index: Int, reservedFromOtherEnd: Int, to target: ReaderHintTarget) {
        guard items.indices.contains(index), items.count > reservedFromOtherEnd else {
            clearAnchor(for: target)
            return
        }
        setAnchor(items[index], for: target)
    }

    /// Re-measures shortly after being asked, and again a few times after that.
    ///
    /// The cue to refresh is always something SwiftUI did — an item appearing, the Reader resizing — and the bar lays
    /// itself out after that, sometimes over several frames while a glass platter settles or a push transition runs.
    /// Rather than guess one delay, this samples a handful; the anchors are change-guarded, so a sample that finds
    /// nothing new costs nothing.
    private func scheduleBarRefresh() {
        barRefreshTask?.cancel()
        barRefreshTask = Task { [weak self] in
            for delay in [0, 120, 320, 700, 1400] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                refreshBarAnchors()
            }
        }
    }

    /// Forgets a control that has left the screen, and takes any hint pointing at it down with it — a bubble whose
    /// caret points at nothing is worse than no bubble.
    func clearAnchor(for target: ReaderHintTarget) {
        guard anchors.removeValue(forKey: target) != nil else { return }
        if target == .transportCompact { transportExpandOfferTask?.cancel() }
        if presentedHint?.target == target { dismiss() }
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
        if !hasUsed(hint) { defaults.set(true, forKey: Self.usedKey(hint)) }
        if presentedHint == hint { dismiss() }
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

    /// Offer the note-input pad hint. Independent of the rotation and of its per-launch budget (the pad is the one
    /// affordance that is useless until explained, and the user has just walked into it), but still at most once per
    /// launch and never once the pad has been used.
    func offerNotePadHint() {
        guard ignoresPerLaunchBudget || !didOfferNotePadHintThisLaunch, !hasUsed(.notePad) else { return }
        guard anchors[ReaderFeatureHint.notePad.target] != nil else { return }
        didOfferNotePadHintThisLaunch = true
        present(.notePad)
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
        didOfferNotePadHintThisLaunch = false
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
            if isEligible(hint) { return hint }
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
