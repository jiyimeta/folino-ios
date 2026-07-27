import SheetMusicCore
import SwiftUI
import UtilityUI

/// Full-screen editing chrome. The App injects this into the Reader seam (Task 15) so it floats over the live score.
/// Layout:
///  - top-right: a voice pill and an undo / redo / 完了 glass cluster, mirroring `ReaderTopOverlay`'s 44 pt buttons;
///  - the editing cluster — the reader's transport plus the `EditorPadView` pad — docked to the top or bottom edge
///    and draggable between the two by its grabber, the way `PKToolPicker` can be moved off whatever it's covering;
///  - regular width: `EditorPaletteView` docked to the trailing edge, vertically centered.
///
/// The floating per-selection callout that used to hover beside the note is gone: everything it carried now lives in
/// chrome that stays put (voice in the header pill, tuplets under the pad's ⋯ key, tie on the pad's third row), so
/// the score is never covered by a panel that moves as the selection moves.
public struct EditorChromeView: View {
    @Bindable private var viewModel: EditorViewModel
    /// Room the reader's bottom transport occupies, so a bottom-docked pad parks above it instead of over it.
    private let bottomTransportClearance: CGFloat
    private let onDone: () -> Void
    private let onClusterInsetsChange: (_ top: CGFloat, _ bottom: CGFloat) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager

    /// Remembered across sessions: someone who moves the pad out of the way once means it for every score they open.
    /// PERSISTENCE ONLY — the layout reads `placement` below.
    ///
    /// Driving the layout straight off `@AppStorage` is what made re-docking lurch: the value round-trips through
    /// `UserDefaults`, so the change comes back to the view outside the `withAnimation` transaction that released the
    /// drag offset. The offset unwound with the spring, the dock position moved separately, and the two-stage motion
    /// read as a bounce.
    @AppStorage("editorPadPlacement") private var storedPlacement = EditorPadPlacement.bottom.rawValue
    /// The placement the layout actually uses: local state, so it changes inside the animation transaction.
    @State private var placement: EditorPadPlacement = .bottom
    /// Live finger travel while the pad is being dragged. `@GestureState`, NOT `@State`: SwiftUI resets it on its own
    /// when the gesture ends **or is cancelled**, so an interrupted drag can never strand the pad half-way down the
    /// screen — which is exactly what happened when this was plain state and a cancelled drag skipped `onEnded`.
    @GestureState private var dragTranslation: CGFloat = 0
    /// The travel captured at the moment the finger lifts, animated back to zero alongside the docking change so the
    /// pad glides from where it was released instead of snapping to its old edge for a frame first. Only ever set
    /// inside `onEnded`, so a cancelled gesture leaves it at zero.
    @State private var releasedTranslation: CGFloat = 0
    @State private var clusterHeight: CGFloat = 0
    /// Height of the header row, so a top-docked pad can park below it.
    @State private var headerHeight: CGFloat = 0

    /// One-time "saved as .mscz" notice (Task 16, spec §11-2) — shown at most once per install.
    @AppStorage("editorSiblingMSCZNoticeShown") private var siblingMSCZNoticeShown = false
    @State private var showsSiblingNotice = false

    public init(
        viewModel: EditorViewModel,
        bottomTransportClearance: CGFloat,
        onDone: @escaping () -> Void,
        onClusterInsetsChange: @escaping (_ top: CGFloat, _ bottom: CGFloat) -> Void = { _, _ in },
    ) {
        self.viewModel = viewModel
        self.bottomTransportClearance = bottomTransportClearance
        self.onDone = onDone
        self.onClusterInsetsChange = onClusterInsetsChange
    }

    /// Moves the pad, animating the dock change and the drag offset's release together, then persists the choice.
    private func dock(to destination: EditorPadPlacement, animation: Animation) {
        withAnimation(animation) {
            placement = destination
            releasedTranslation = 0
        }
        storedPlacement = destination.rawValue
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if horizontalSizeClass == .regular {
                EditorPaletteView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing)
            }

            topCluster
                // Measured so a top-docked pad can park BELOW the header rather than over (or above) it: 完了 and the
                // voice picker have to stay reachable wherever the pad is.
                //
                // The measurement goes BEFORE the expanding frame, deliberately. Attached after it, this read the
                // full-screen frame instead of the header — 778 pt rather than ~50 — and a top-docked pad was padded
                // clean off the bottom of the screen, where the transport then covered what little showed.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        headerHeight = height
                        publishInsets(height: clusterHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            navigationPill
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 12)

            editingCluster
        }
        // Task 16: bridges ScoreEditor's undo/redo stacks to the system UndoManager so three-finger swipe gestures
        // work. Triggers off `appliedEditCount` — NOT `generation` — because `generation` also bumps on undo/redo;
        // re-registering here on every undo/redo would double up with `registerSystemUndo`'s own symmetric
        // re-registration and drift the system stack from `ScoreEditor`'s real depth (Task 16 review fix). Only a
        // genuinely new applied edit should arm a fresh trampoline. [Task 17 verify] confirm the three-finger swipe
        // reaches this view's UndoManager through the glass overlay hierarchy on device — if it doesn't, the
        // on-screen undo/redo buttons remain the primary path.
        .onChange(of: viewModel.appliedEditCount) { _, _ in
            viewModel.registerSystemUndo(with: undoManager)
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

    // MARK: Top cluster

    // MARK: The editing cluster (transport + pad)

    /// The pad, docked to `placement` and draggable to the other edge by its grabber, the way `PKToolPicker` can be
    /// moved off whatever it is covering. The reader's transport stays anchored to the bottom edge and is NOT part of
    /// this cluster — when the pad is docked at the bottom it simply parks above it.
    ///
    /// The cluster floats over the score — it never re-engraves it. What it does instead is report its height, which
    /// the scrolling layouts turn into scroll padding so the last (or first) system can still be brought into view.
    private var editingCluster: some View {
        GeometryReader { proxy in
            EditorPadView(viewModel: viewModel)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    clusterHeight = height
                    publishInsets(height: height)
                }
                .offset(y: dragTranslation + releasedTranslation)
                // Anywhere on the pad moves it — no grabber to aim at. `highPriorityGesture` is what makes that
                // possible without stealing the keys: a plain tap never travels the minimum distance, so the drag
                // stays unrecognized and the key underneath gets it; once the finger does travel, the drag wins
                // outright and the key it started on is cancelled rather than fired on release.
                .highPriorityGesture(dragGesture(viewportHeight: proxy.size.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement.alignment)
                // The chrome is already laid out inside the safe area, so the transport's content height is the whole
                // clearance a bottom-docked pad needs.
                .padding(.bottom, placement == .bottom ? bottomTransportClearance + 4 : 0)
                // Docked at the top, the pad sits under the header — the same way it sits above the transport when
                // docked at the bottom. It parks next to the fixed chrome, never on top of it.
                .padding(.top, placement == .top ? headerHeight + 4 : 0)
                .accessibilityAction(named: Text("editor.pad.move", bundle: .module)) {
                    // No finger to take a velocity from, so this one is a plain, calm move.
                    dock(to: placement == .bottom ? .top : .bottom, animation: .smooth(duration: 0.35))
                }
        }
        .onAppear { placement = EditorPadPlacement(rawValue: storedPlacement) ?? .bottom }
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

    private func dragGesture(viewportHeight: CGFloat) -> some Gesture {
        // GLOBAL coordinate space, deliberately. In the default `.local` space the translation is measured against
        // the pad's own frame — which this very gesture is moving via `.offset`, so each frame's offset fed back into
        // the next frame's translation and the pad juddered instead of tracking the finger.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                // Hand the finger's travel over to state for one frame so the pad doesn't blink back to its old edge
                // as the gesture state evaporates; the animation below then unwinds it.
                releasedTranslation = value.translation.height
                // Re-dock by where the pad ENDED UP, not by how far the finger moved: a short flick near an edge
                // shouldn't launch it across the screen.
                let parkedCenter = placement == .bottom
                    ? viewportHeight - clusterHeight / 2
                    : clusterHeight / 2
                let releasedCenter = parkedCenter + value.translation.height
                let landedCenter = parkedCenter + value.predictedEndTranslation.height
                let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewportHeight)
                let destinationCenter = destination == .bottom
                    ? viewportHeight - clusterHeight / 2
                    : clusterHeight / 2
                // Dock and release the offset in ONE transaction (see `dock(to:animation:)`): unwinding the offset
                // separately snapped the pad back to its old edge for a frame before the docking animation started.
                dock(to: destination, animation: Self.dockAnimation(
                    from: releasedCenter, to: destinationCenter, releaseVelocity: value.velocity.height,
                ))
            }
    }

    /// The settle animation for a released pad, scaled to the job it has to do.
    ///
    /// A single fixed spring can't serve both cases: the same curve that feels crisp nudging the pad 20 pt back to
    /// the edge it already sat on overshoots wildly when it has to carry it the ~700 pt from one end of the screen to
    /// the other. So the duration grows with the distance left to travel, and the finger's release velocity is handed
    /// to the spring as its initial velocity — a flick continues at the speed it was thrown instead of stopping dead
    /// and restarting.
    ///
    /// `bounce: 0` (critically damped) is deliberate: the pad is a slab of controls settling against an edge, not a
    /// playful element, and any overshoot at all read as wobble on device.
    private static func dockAnimation(
        from releasedCenter: CGFloat, to destinationCenter: CGFloat, releaseVelocity: CGFloat,
    ) -> Animation {
        let travel = destinationCenter - releasedCenter
        let distance = abs(travel)
        let duration = min(0.42, max(0.18, 0.16 + distance / 2400))
        return .interpolatingSpring(
            duration: duration, bounce: 0,
            initialVelocity: normalizedVelocity(releaseVelocity, travel: travel),
        )
    }

    /// A spring's initial velocity is expressed in fractions of the REMAINING DISTANCE per second, so raw pt/s has to
    /// be divided by that distance — which is what made a gentle release bounce: let go a few points from the target
    /// and even a slow drift becomes a huge multiple of what little travel is left, catapulting the pad past it.
    /// Hence the dead band (a release this slow is a release, not a throw) and the tight ceiling.
    private static func normalizedVelocity(_ velocity: CGFloat, travel: CGFloat) -> CGFloat {
        let deadBand: CGFloat = 80 // pt/s
        guard abs(travel) >= 1, abs(velocity) > deadBand else { return 0 }
        return min(3, max(-1, velocity / travel))
    }

    /// Reports the cluster's footprint to the Reader (via the App) so the scrolling layouts can pad their scroll
    /// content by it. Only the docked edge reserves room; the other end is clear.
    private func publishInsets(height: CGFloat) {
        switch placement {
        // Docked at the top the pad hangs below the header, so the score has to clear both.
        case .top: onClusterInsetsChange(headerHeight + height + 4, 0)
        case .bottom: onClusterInsetsChange(0, height)
        }
    }

    /// The header row: a standalone voice pill, then the undo / redo / 完了 cluster. The voice picker used to hide
    /// behind the callout's `⋯`; as its own pill it stays reachable with nothing selected, which is when you most
    /// often need to switch the voice you're about to input into.
    private var topCluster: some View {
        HStack(spacing: 8) {
            voicePill
            actionCluster
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var voicePill: some View {
        Menu {
            EditorVoicePicker(viewModel: viewModel)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 15, weight: .medium))
                Text(verbatim: "\(viewModel.activeVoice + 1)")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .tint(.primary)
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .accessibilityLabel(Text("editor.voice.label", bundle: .module))
    }

    private var actionCluster: some View {
        HStack(spacing: 0) {
            clusterIconButton(system: "arrow.uturn.backward", label: "editor.chrome.undo", enabled: viewModel.canUndo) {
                viewModel.undo()
            }
            clusterIconButton(system: "arrow.uturn.forward", label: "editor.chrome.redo", enabled: viewModel.canRedo) {
                viewModel.redo()
            }
            Button {
                onDone()
            } label: {
                Text("editor.chrome.done", bundle: .module)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .tint(.primary)
        }
        .interactiveGlassCompat()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    private func clusterIconButton(
        system: String,
        label: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .tint(.primary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label, bundle: .module))
    }
}
