import EditorCore
import Foundation
import SheetMusicCore
import SwiftUI
import UtilityUI

/// Full-screen editing chrome. The App injects this into the Reader seam so it floats over the live score.
///
/// What it draws is the editing cluster — the reader's transport plus the `EditorPadView` pad — docked to the top
/// or bottom edge and draggable between the two by its grabber, the way `PKToolPicker` can be moved off whatever it
/// is covering. Dragging it toward a side edge instead tucks it offscreen behind a PiP-style pull tab
/// (`EditorPadTuckHandle`); there is no show / hide toggle anywhere else.
///
/// The fixed controls — voice, undo / redo / 完了 — and the revert confirmation are NOT here: they live in
/// `EditorTopBarView`, drawn into the Reader's own top strip.
///
/// The chrome that stays put carries most of what a per-selection panel would (voice in the header pill, tuplets
/// and tie on the pad), so the score is not covered by something that moves as the selection moves. What is left
/// beside the note is the callout — pitch steps and the next length — which this view mounts and positions via
/// `SelectionCalloutLayer`; see `EditorCalloutView` for why those two jobs belong there.
public struct EditorChromeView: View {
    @Bindable var viewModel: EditorViewModel
    /// Room the reader's bottom transport occupies, so a bottom-docked pad parks above it instead of over it.
    let bottomTransportClearance: CGFloat
    let onClusterInsetsChange: (_ top: CGFloat, _ bottom: CGFloat) -> Void
    /// The pad's WINDOW frame while it is out, `nil` while it is tucked or gone — the anchor the host's coach marks
    /// point at. Window coordinates for the same reason the old toggle's anchor used them: the two sides of the seam
    /// may live in different hosting contexts, and the window is the space they genuinely share.
    let onPadAnchorFrameChange: (CGRect?) -> Void
    /// The pull tab's WINDOW frame while the pad is tucked, `nil` while it is out — the anchor for the "bring it
    /// back" coach mark, which points at the tab the pad left behind.
    let onPadHandleAnchorFrameChange: (CGRect?) -> Void
    /// Fired when a snap lands the pad on the OTHER vertical dock — the "drag it up / down" coach mark retires on it.
    let onPadDockMoved: () -> Void
    /// Fired when a snap tucks the pad past a side edge — the "swipe it away" coach mark retires on it (and the
    /// "bring it back" one is offered off the tab's appearance).
    let onPadTucked: () -> Void
    /// Fired when a snap brings a tucked pad back out — the "bring it back" coach mark retires on it, and the
    /// "drag it up / down" one takes its turn.
    let onPadRestored: () -> Void
    @Environment(\.undoManager) private var undoManager

    /// Remembered across sessions: someone who moves the pad out of the way once means it for every score they open.
    /// PERSISTENCE ONLY — the layout reads `placement` below.
    ///
    /// Driving the layout straight off `@AppStorage` is what made re-docking lurch: the value round-trips through
    /// `UserDefaults`, so the change comes back to the view outside the `withAnimation` transaction that released the
    /// drag offset. The offset unwound with the spring, the dock position moved separately, and the two-stage motion
    /// read as a bounce.
    /// (These pad-state members are internal, not private, because the drag / snap half of this view lives in
    /// `EditorChromeView+PadDrag.swift` — the SwiftLint file-length budget forced the split.)
    @AppStorage("editorPadPlacement") var storedPlacement = EditorPadPlacement.bottom.rawValue
    /// The placement the layout actually uses: local state, so it changes inside the animation transaction.
    @State var placement: EditorPadPlacement = .bottom
    /// Live finger travel while the pad is being dragged. `@GestureState`, NOT `@State`: SwiftUI resets it on its own
    /// when the gesture ends **or is cancelled**, so an interrupted drag can never strand the pad half-way down the
    /// screen — which is exactly what happened when this was plain state and a cancelled drag skipped `onEnded`.
    @GestureState var dragTranslation: CGSize = .zero
    /// The travel captured at the moment the finger lifts, animated back to zero alongside the docking change so the
    /// pad glides from where it was released instead of snapping to its old edge for a frame first. Only ever set
    /// inside `onEnded`, so a cancelled gesture leaves it at zero.
    @State var releasedTranslation: CGSize = .zero
    @State var clusterSize: CGSize = .zero

    /// Whether the pad is out on the score or tucked past a side edge, PiP-style, with only the pull tab showing.
    /// Remembered across sessions the same way the pad's placement is: someone who pushes the keyboard away means it,
    /// and someone who writes with it out wants it out next time.
    ///
    /// Out by default: the tab is a visible, self-explaining affordance, so starting expanded costs a newcomer
    /// nothing to undo — where the old hidden-behind-a-toolbar-button default made edit mode look inert.
    /// PERSISTENCE ONLY, like `storedPlacement` above — the layout reads `isPadExpanded`.
    @AppStorage("editorPadVisible") var storedPadVisible = true
    @State var isPadExpanded = true
    /// Which side edge a tucked pad is parked past. Chosen by the dismissing drag's direction, remembered so the tab
    /// stays where the user put it. Same persistence split as the placement.
    @AppStorage("editorPadTuckSide") var storedTuckSide = EditorPadTuckSide.trailing.rawValue
    @State var tuckSide: EditorPadTuckSide = .trailing
    /// True while a tucked pad's live drag is past the restore threshold — the pad's rest base sits at the
    /// finger-compensated preview position (`restorePreviewRestOffsetX`) so its inner edge rides the handle's.
    ///
    /// Real state flipped with an EXPLICIT `withAnimation` from the drag's `onChanged`, not a value derived from
    /// `dragTranslation` behind an implicit `.animation(value:)`: the implicit animation was cancelled by the very
    /// next drag frame's unanimated update to the same offset, so the swing only survived when the finger was nearly
    /// still. Explicit animations run additively and keep going under continued dragging. Reset by every `snap`, and
    /// by the cancellation guard in `padBranch` (a cancelled drag skips `onEnded` entirely).
    @State var isRestorePreviewActive = false

    /// THE spring for every pad motion that isn't the finger itself: the mid-drag threshold swing, the handle's
    /// fade, the tuck and restore snaps, and the dock moves. One curve on purpose — the choreography reads as one
    /// material. 0.4 / 0.2 was hand-tuned on device against 0.45/0.1 (imperceptible) and 0.5/0.15 (sluggish); it
    /// replaced a velocity-matched, overshoot-free settle — the uniform spring won on feel.
    static let tuckSpring: Animation = .spring(duration: 0.4, bounce: 0.2)

    /// One-time "saved as .mscz" notice (spec §11-2) — shown at most once per install.
    @AppStorage("editorSiblingMSCZNoticeShown") private var siblingMSCZNoticeShown = false
    @State private var showsSiblingNotice = false

    public init(
        viewModel: EditorViewModel,
        bottomTransportClearance: CGFloat,
        onClusterInsetsChange: @escaping (_ top: CGFloat, _ bottom: CGFloat) -> Void = { _, _ in },
        onPadAnchorFrameChange: @escaping (CGRect?) -> Void = { _ in },
        onPadHandleAnchorFrameChange: @escaping (CGRect?) -> Void = { _ in },
        onPadDockMoved: @escaping () -> Void = {},
        onPadTucked: @escaping () -> Void = {},
        onPadRestored: @escaping () -> Void = {},
    ) {
        self.viewModel = viewModel
        self.bottomTransportClearance = bottomTransportClearance
        self.onClusterInsetsChange = onClusterInsetsChange
        self.onPadAnchorFrameChange = onPadAnchorFrameChange
        self.onPadHandleAnchorFrameChange = onPadHandleAnchorFrameChange
        self.onPadDockMoved = onPadDockMoved
        self.onPadTucked = onPadTucked
        self.onPadRestored = onPadRestored
    }

    public var body: some View {
        chromeContent
    }

    private var chromeContent: some View {
        ZStack(alignment: .topTrailing) {
            navigationPill
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 12)

            SelectionCalloutLayer(
                viewModel: viewModel,
                // Only keep clear of the pad while the pad is actually there.
                bottomClearance: bottomTransportClearance + (isPadExpanded ? clusterSize.height : 0),
            )

            editingCluster
        }
        // Bridges ScoreEditSession's undo/redo stacks to the system UndoManager so three-finger swipe
        // gestures work. Triggers off `appliedEditCount` — NOT `generation` — because `generation` also bumps on
        // undo/redo; re-registering here on every undo/redo would double up with `registerSystemUndo`'s own
        // symmetric re-registration and drift the system stack from `ScoreEditSession`'s real depth. Only a
        // genuinely new applied edit should arm a fresh trampoline. Unconfirmed on device: whether the
        // three-finger swipe reaches this view's UndoManager through the glass overlay hierarchy on device — if it
        // doesn't, the on-screen undo/redo buttons remain the primary path.
        .onChange(of: viewModel.appliedEditCount) { _, _ in
            viewModel.registerSystemUndo(with: undoManager)
        }
        // An adopted history is reachable from the strip's undo button the moment the session opens, but the
        // three-finger gesture goes through the system UndoManager, which only learns about edits when a
        // trampoline is registered — and that happens per NEWLY applied edit. Arm one initial trampoline when the
        // session already has history; `registerSystemUndo`'s symmetric re-registration handles everything after.
        .onAppear {
            if viewModel.canUndo {
                viewModel.registerSystemUndo(with: undoManager)
            }
        }
        .onDisappear {
            undoManager?.removeAllActions(withTarget: viewModel)
        }
        .onChange(of: viewModel.didSaveAsSiblingMSCZ) { _, saved in
            guard saved, !siblingMSCZNoticeShown else { return }
            siblingMSCZNoticeShown = true
            showsSiblingNotice = true
        }
        .overlay(alignment: .top) {
            if showsSiblingNotice {
                siblingMSCZNoticeBanner
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        showsSiblingNotice = false
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsSiblingNotice)
    }

    // MARK: One-time sibling-mscz notice

    /// Top-center glass banner (spec §11-2): informs the user their edits are now saved as a sibling `.mscz` copy,
    /// the first time a non-MuseScore source gets rewritten that way. Mirrors `DrainBannerView`'s capsule + auto-
    /// dismiss pattern (`App/DrainBannerView.swift`).
    private var siblingMSCZNoticeBanner: some View {
        Text("editor.notice.savedAsMscz", bundle: .module)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .regularGlassCompat(in: Capsule())
            .padding(.top, 8)
            .padding(.horizontal, 24)
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Selection stepping

    /// ← / → as their own pill at the bottom-left, level with the reader's compact transport.
    ///
    /// Stepping the selection is navigation, not writing — it belongs with the transport rather than among the keys
    /// that change the score. Keeping it out of the pad also means it stays put when the pad is re-docked, and it's
    /// what let the pad come down to two rows.
    private var navigationPill: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.selectPreviousElement()
            } label: {
                PadKeyGlyph.symbol("arrow.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("editor.pad.selectPrevious", bundle: .module))

            Button {
                viewModel.selectNextElement()
            } label: {
                PadKeyGlyph.symbol("arrow.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text("editor.pad.selectNext", bundle: .module))
        }
        .tint(.primary)
        .disabled(viewModel.isPlaybackActive)
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }
}
