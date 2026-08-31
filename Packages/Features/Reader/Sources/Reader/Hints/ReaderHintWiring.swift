import ReaderInteractionCore
import SwiftUI

/// Everything the Reader's coach marks need attached to its root, folded into one modifier: the bubble overlay, what
/// tapping a bubble does, and when a hint is offered.
///
/// One modifier rather than six on `ReaderRootScreen.body` for a concrete reason: that body is a single expression
/// long enough that adding modifiers to it directly tipped the type-checker into "unable to type-check this expression
/// in reasonable time". Keeping the wiring behind one opaque `ViewModifier` keeps that chain where it was.
struct ReaderHintWiring: ViewModifier {
    let hints: ReaderHintCoordinator
    let viewModel: ReaderViewModel
    let editingHost: ReaderEditingHost?
    /// Screenshot-capture mode draws no chrome and must draw no coach marks either.
    let isCaptureMode: Bool
    /// Whether the PDF-source notice is up. A coach mark must not compete with an alert the Reader raised on its own —
    /// the offer waits for it to close (see `attemptOffer`).
    ///
    /// A `Binding`, not a `Bool`, and that distinction is the whole bug it fixes: `scheduleRotationHint` runs inside a
    /// `.task` that captured this modifier at the render it started on — where the notice had not been raised yet — so
    /// a plain copied value read `false` a second later and the bubble went up right alongside the alert. A binding
    /// reads through to the owner's state, so the deferred check sees what is actually on screen.
    @Binding var isPDFNoticePresented: Bool
    /// Enters note editing, the way the toolbar button does. `nil` in a Reader with no editing seam.
    let onStartEditing: (() -> Void)?

    /// Set once the offer is due, cleared when it is spent. Lets an offer that arrived at a bad moment (a dialog was
    /// up) be retried the moment the blocker clears, instead of being dropped on the floor.
    @State private var isOfferPending = false

    /// The overlay goes above everything the Reader draws, including the editing chrome — a coach mark the thing it
    /// explains can cover is worse than none.
    func body(content: Content) -> some View {
        content
            .readerHintOverlay(coordinator: hints, onActivate: activate)
            .task { await scheduleRotationHint() }
            // A blocker clearing is the cue to retry: the PDF notice dismissed, an inspector closed. Reading
            // `blocksOffer` here rather than inside the task is what makes the retry see current state — this closure
            // is rebuilt along with the modifier on every render.
            .onChange(of: blocksOffer) { _, _ in attemptOffer() }
            .modifier(PadHintWiring(hints: hints, editingHost: editingHost))
    }

    // MARK: - Activation

    /// Tapping a bubble does the thing it describes. For the controls that open something that means opening it; for
    /// the transport swipe — which has no button to press — it means performing the gesture, animation and all, so the
    /// bubble demonstrates the move instead of only naming it.
    private func activate(_ hint: ReaderFeatureHint) {
        hints.dismiss()
        switch hint {
        case .transportCollapse, .transportExpand:
            hints.requestTransportModeSwitch()
        case .noteEditing:
            onStartEditing?()
        case .annotation:
            hints.markUsed(.annotation)
            viewModel.toggleAnnotation()
        case .staffVisibility:
            viewModel.isVisualInspectorPresented = true
        case .metronome, .repeatPlayback, .mixer:
            viewModel.isPlaybackInspectorPresented = true
        case .padHide, .padRestore, .padMove:
            // Gesture hints have no button to press for the user; the tap just acknowledges (the dismiss above).
            break
        }
    }

    // MARK: - Offering

    /// Waits until the Reader has settled, then marks the offer due and tries to spend it.
    ///
    /// The wait is not cosmetic: hint selection asks the anchors which controls are on screen, and the top bar only
    /// reports those after the score has loaded and the bar has laid out. Offering earlier would see an empty anchor
    /// set and silently pick nothing — so this waits for the first anchor (bounded, so a score that never loads
    /// doesn't spin), then lets the scene settle so the bubble doesn't land on the score's first paint.
    private func scheduleRotationHint() async {
        guard !isCaptureMode else { return }
        for _ in 0 ..< 40 where !hints.hasAnyAnchor {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        isOfferPending = true
        attemptOffer()
    }

    /// Spends the pending offer, unless something is in the way — in which case it stays pending and the `onChange`
    /// above brings it back once the way is clear.
    ///
    /// Even when the way IS clear, it waits a beat first. The event that cleared it is usually a tap on an alert
    /// button, and that same tap reaches the window recognizer that dismisses coach marks — so a bubble raised in the
    /// same runloop turn would be torn down by the tap that let it appear. The pending flag is put back if the wait
    /// ends with something else in the way.
    private func attemptOffer() {
        guard isOfferPending, !blocksOffer else { return }
        isOfferPending = false
        Task {
            try? await Task.sleep(for: .seconds(Self.blockerSettleDelay))
            guard !blocksOffer else {
                isOfferPending = true
                return
            }
            hints.offerRotationHint()
        }
    }

    /// How long to let the screen settle after the last blocker clears (see `attemptOffer`).
    private static let blockerSettleDelay = 0.5

    /// Anything that makes now the wrong moment for a coach mark: a dialog or inspector the user is already looking
    /// at, or a mode where the hinted chrome isn't what's on screen.
    private var blocksOffer: Bool {
        isPDFNoticePresented
            || viewModel.isScoreInfoPresented
            || viewModel.isPlaybackInspectorPresented
            || viewModel.isVisualInspectorPresented
            || viewModel.isAnnotating
            || editingHost?.isEditing == true
    }
}

/// The pad-gesture coach marks' wiring, split out of `ReaderHintWiring.body` — that chain was already at the
/// type-checker's limit (see its own doc comment), and these four modifiers pushed it over.
private struct PadHintWiring: ViewModifier {
    let hints: ReaderHintCoordinator
    let editingHost: ReaderEditingHost?

    func body(content: Content) -> some View {
        anchors(content)
            // Entering edit mode offers the chain's opener (once per launch, until a tuck has been performed).
            // Deferred a beat so the chrome has laid out and reported the anchor this hangs off.
                .onChange(of: editingHost?.isEditing ?? false, initial: true) { _, isEditing in
                    hints.setEditing(isEditing)
                    guard isEditing else { return }
                    Task {
                        try? await Task.sleep(for: .seconds(0.5))
                        guard editingHost?.isEditing == true else { return }
                        hints.offerPadGestureHint()
                    }
                }
                // The gestures themselves retire their hints: an actual dock move, an actual tuck, an actual restore —
                // and the restore chains the last hint (skipped inside if the move was already performed).
                .onChange(of: editingHost?.padDockMoveUses ?? 0) { _, _ in
                    hints.markUsed(.padMove)
                }
                .onChange(of: editingHost?.padTuckUses ?? 0) { _, _ in
                    hints.markUsed(.padHide)
                }
                .onChange(of: editingHost?.padRestoreUses ?? 0) { _, _ in
                    hints.markUsed(.padRestore)
                    hints.schedulePadMoveHint()
                }
    }

    /// The pad-chain coach marks point at surfaces the Editor draws, so their frames arrive through the seam rather
    /// than from a `readerHintAnchor` this feature could attach itself. (The `padRestore` offer itself rides the
    /// handle anchor's first report — see `ReaderHintCoordinator.setAnchor`.)
    private func anchors(_ content: Content) -> some View {
        content
            .onChange(of: editingHost?.noteInputPadFrame, initial: true) { _, frame in
                if let frame {
                    hints.setAnchor(frame, for: .noteInputPad)
                } else {
                    hints.clearAnchor(for: .noteInputPad)
                }
            }
            .onChange(of: editingHost?.noteInputPadHandleFrame, initial: true) { _, frame in
                if let frame {
                    hints.setAnchor(frame, for: .noteInputPadHandle)
                } else {
                    hints.clearAnchor(for: .noteInputPadHandle)
                }
            }
    }
}
