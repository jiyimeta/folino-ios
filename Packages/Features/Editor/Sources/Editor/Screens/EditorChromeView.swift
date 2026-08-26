import Foundation
import SheetMusicCore
import SwiftUI
import UtilityUI

/// Full-screen editing chrome. The App injects this into the Reader seam (Task 15) so it floats over the live score.
/// Layout:
///  - the editing cluster — the reader's transport plus the `EditorPadView` pad — docked to the top or bottom edge
///    and draggable between the two by its grabber, the way `PKToolPicker` can be moved off whatever it's covering.
///    Dragging it toward a side edge instead tucks it offscreen behind a PiP-style pull tab (`EditorPadTuckHandle`);
///    the old top-bar show / hide toggle is gone.
///
/// The fixed controls — voice, undo / redo / 完了 — and the revert confirmation used to live here too
/// (as `ToolbarContent` filling the Reader's navigation bar). They now live in `EditorTopBarView`, drawn into the
/// Reader's own top strip (Task 5) — the Reader's navigation bar is gone, so there is no bar left for a `.toolbar`
/// here to fill.
///
/// Regular width used to add a third piece: a palette card docked to the trailing edge, carrying a selection readout,
/// the tie key and the `+3度` / `+8度` shortcuts. It is gone — it sat on the score permanently for keys the pad
/// already has, and the readout was the only thing unique to it. The commands it drove (`addIntervalNote`) still
/// exist on the view model, so bringing any of it back is a view-only change.
///
/// Most of what the per-selection callout used to carry now lives in chrome that stays put (voice in the header
/// pill, tuplets and tie on the pad), so the score isn't covered by a panel that moves as the selection moves. What
/// remains in the callout is ♯ / ♭ — see `EditorCalloutView` for why those two belong beside the note rather than in
/// a row of keys aimed at the caret.
public struct EditorChromeView: View {
    @Bindable private var viewModel: EditorViewModel
    /// Room the reader's bottom transport occupies, so a bottom-docked pad parks above it instead of over it.
    private let bottomTransportClearance: CGFloat
    private let onClusterInsetsChange: (_ top: CGFloat, _ bottom: CGFloat) -> Void
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

    /// One-time "saved as .mscz" notice (Task 16, spec §11-2) — shown at most once per install.
    @AppStorage("editorSiblingMSCZNoticeShown") private var siblingMSCZNoticeShown = false
    @State private var showsSiblingNotice = false

    public init(
        viewModel: EditorViewModel,
        bottomTransportClearance: CGFloat,
        onClusterInsetsChange: @escaping (_ top: CGFloat, _ bottom: CGFloat) -> Void = { _, _ in },
    ) {
        self.viewModel = viewModel
        self.bottomTransportClearance = bottomTransportClearance
        self.onClusterInsetsChange = onClusterInsetsChange
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
        // Task 16: bridges ScoreEditSession's undo/redo stacks to the system UndoManager so three-finger swipe
        // gestures work. Triggers off `appliedEditCount` — NOT `generation` — because `generation` also bumps on
        // undo/redo; re-registering here on every undo/redo would double up with `registerSystemUndo`'s own
        // symmetric re-registration and drift the system stack from `ScoreEditSession`'s real depth (Task 16 review
        // fix). Only a genuinely new applied edit should arm a fresh trampoline. [Task 17 verify] confirm the
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

    // MARK: The editing cluster (transport + pad)

    /// The pad, docked to `placement` and draggable to the other edge by its grabber, the way `PKToolPicker` can be
    /// moved off whatever it is covering. The reader's transport stays anchored to the bottom edge and is NOT part of
    /// this cluster — when the pad is docked at the bottom it simply parks above it.
    ///
    /// Dismissal is PiP's, not a toolbar toggle's: dragging the pad far enough toward a side edge tucks it past that
    /// edge, leaving only `EditorPadTuckHandle` showing, and the handle drags (or taps) it back out. The handle is an
    /// overlay hanging off the pad's inner edge and every motion is one shared offset, so the pad visibly converges
    /// onto — and re-emerges from — its own tab instead of animating somewhere unrelated.
    ///
    /// The cluster floats over the score — it never re-engraves it. What it does instead is report its height, which
    /// the scrolling layouts turn into scroll padding so the last (or first) system can still be brought into view.
    private var editingCluster: some View {
        GeometryReader { proxy in
            // While a tucked pad is being pulled, the handle previews the release the way the PiP tab does: it stays
            // up while letting go would snap back, and vanishes once the drag has travelled far enough to stick.
            // While the pad is out it is gone entirely — including during the dismissing drag itself; it only fades
            // in with the tuck snap.
            let handleVisible = !isPadExpanded && EditorPadTuckGeometry.handleVisible(
                side: tuckSide,
                translationX: dragTranslation.width,
                threshold: EditorPadTuckGeometry.threshold(in: proxy.size),
            )
            EditorPadView(viewModel: viewModel)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    clusterSize = size
                    publishInsets(height: size.height)
                }
                // The measurement only fires when the pad's own size changes, so tucking it has to re-publish too —
                // otherwise the score keeps scroll padding for a pad that isn't there.
                .onChange(of: isPadExpanded) { _, _ in publishInsets(height: clusterSize.height) }
                .overlay(alignment: tuckSide.handleAlignment) {
                    EditorPadTuckHandle(side: tuckSide) {
                        snap(expanded: true, animation: .snappy(duration: 0.3))
                    }
                    // Hung fully outside the pad's inner edge, so the tucked rest position leaves exactly the tab on
                    // screen.
                    .offset(x: tuckSide == .trailing ? -EditorPadTuckHandle.width : EditorPadTuckHandle.width)
                    .opacity(handleVisible ? 1 : 0)
                    // Opacity 0 alone still hit-tests — and while the pad is out this sits invisibly over the score.
                    .allowsHitTesting(handleVisible)
                    // The mid-drag threshold crossings fade on their own quick curve; the snap transactions carry
                    // their own spring for everything else.
                    .animation(.easeOut(duration: 0.15), value: handleVisible)
                }
                // Before the first measurement a tucked pad's offscreen offset can't be computed yet — hold it
                // invisible for that frame rather than flashing it across the score.
                .opacity(clusterSize == .zero && !isPadExpanded ? 0 : 1)
                .offset(
                    x: tuckRestOffsetX(viewportWidth: proxy.size.width)
                        + dragTranslation.width + releasedTranslation.width,
                    y: dragTranslation.height + releasedTranslation.height,
                )
                // Anywhere on the pad moves it — no grabber to aim at. `highPriorityGesture` is what makes that
                // possible without stealing the keys (or the handle's tap): a plain tap never travels the minimum
                // distance, so the drag stays unrecognized and the control underneath gets it; once the finger does
                // travel, the drag wins outright and the control it started on is cancelled rather than fired on
                // release.
                .highPriorityGesture(dragGesture(viewport: proxy.size))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
                // The chrome is already laid out inside the safe area, so the transport's content height is the whole
                // clearance a bottom-docked pad needs.
                .padding(.bottom, placement == .bottom ? bottomTransportClearance + 4 : 0)
                // Docked at the top, the pad hangs just under the navigation bar — the same way it sits above the
                // transport when docked at the bottom. The chrome is laid out inside the safe area and the bar
                // contributes its own inset, so there is no header height left to subtract here.
                .padding(.top, placement == .top ? 4 : 0)
                .accessibilityAction(named: Text("editor.pad.move", bundle: .module)) {
                    // No finger to take a velocity from, so this one is a plain, calm move.
                    dock(to: placement == .bottom ? .top : .bottom, animation: .smooth(duration: 0.35))
                }
                .accessibilityAction(named: Text(
                    isPadExpanded ? "editor.chrome.hidePad" : "editor.chrome.showPad", bundle: .module,
                )) {
                    snap(expanded: !isPadExpanded, animation: .smooth(duration: 0.35))
                }
        }
        .onAppear {
            placement = EditorPadPlacement(rawValue: storedPlacement) ?? .bottom
            isPadExpanded = storedPadVisible
            tuckSide = EditorPadTuckSide(rawValue: storedTuckSide) ?? .trailing
        }
    }

    /// The cluster's resting horizontal offset: centered while the pad is out, parked past `tuckSide`'s edge while it
    /// is tucked.
    private func tuckRestOffsetX(viewportWidth: CGFloat) -> CGFloat {
        guard !isPadExpanded else { return 0 }
        return EditorPadTuckGeometry.restOffsetX(
            side: tuckSide, viewportWidth: viewportWidth, padWidth: clusterSize.width,
        )
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

    /// Reports the cluster's footprint to the Reader (via the App) so the scrolling layouts can pad their scroll
    /// content by it. Only the docked edge reserves room; the other end is clear.
    private func publishInsets(height: CGFloat) {
        // A tucked pad reserves nothing: that room goes back to the score.
        let height = isPadExpanded ? height : 0
        switch placement {
        case .top: onClusterInsetsChange(height > 0 ? height + 4 : 0, 0)
        case .bottom: onClusterInsetsChange(0, height)
        }
    }
}
