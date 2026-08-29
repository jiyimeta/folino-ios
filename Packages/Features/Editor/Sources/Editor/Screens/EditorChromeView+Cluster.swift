import EditorCore
import SwiftUI
import UtilityUI

/// The editing cluster's layout half: the pad and its pull tab as two ZStack branches sharing one set of offsets, the
/// coach-mark anchor reporting, and the scroll-inset publishing. Split from `EditorChromeView.swift` for the SwiftLint
/// file-length budget, alongside `EditorChromeView+PadDrag.swift` — the state both files drive is declared there.
extension EditorChromeView {
    /// The pad, docked to `placement` and draggable to the other edge by its grabber, the way `PKToolPicker` can be
    /// moved off whatever it is covering. The reader's transport stays anchored to the bottom edge and is NOT part of
    /// this cluster — when the pad is docked at the bottom it simply parks above it.
    ///
    /// Dismissal is PiP's, not a toolbar toggle's: dragging the pad far enough toward a side edge tucks it past that
    /// edge, leaving only `EditorPadTuckHandle` showing, and the handle drags (or taps) it back out. The handle is a
    /// SIBLING of the pad, positioned by the same offsets — NOT an overlay hanging outside the pad's bounds. It was
    /// an overlay first, and on device it drew but took no touches: the glass surfaces are platform-backed, and UIKit
    /// clips hit-testing (not drawing) to the parent's bounds — with the pad parked offscreen, the tab was outside
    /// every parent that could have claimed its touches. As a sibling its own frame IS where it renders, so the tab
    /// wins its touches and everything around it still falls through to the score.
    ///
    /// The cluster floats over the score — it never re-engraves it. What it does instead is report its height, which
    /// the scrolling layouts turn into scroll padding so the last (or first) system can still be brought into view.
    var editingCluster: some View {
        GeometryReader { proxy in
            // The handle draws BEHIND the pad: while the two overlap mid-drag it is the pad's card sliding over the
            // tab, not the tab floating on the keys. Hit-testing is unaffected — whenever the tab is visible the pad
            // is off past the edge (or fading in over it with hit-testing already claimed by its keys).
            ZStack {
                handleBranch(in: proxy.size)
                padBranch(in: proxy.size)
            }
        }
        .onAppear {
            placement = EditorPadPlacement(rawValue: storedPlacement) ?? .bottom
            isPadExpanded = storedPadVisible
            tuckSide = EditorPadTuckSide(rawValue: storedTuckSide) ?? .trailing
        }
    }

    private func padBranch(in viewport: CGSize) -> some View {
        EditorPadView(viewModel: viewModel)
            // The coach-mark anchor. Attached to the pad content itself, inside the offsets, so the probe rides
            // every move the pad makes and reports where it actually sits.
                .onWindowFrameChange { frame in
                    onPadAnchorFrameChange(isPadExpanded ? frame : nil)
                }
                .onChange(of: isPadExpanded) { _, expanded in
                    if !expanded {
                        onPadAnchorFrameChange(nil)
                    }
                }
                .onDisappear { onPadAnchorFrameChange(nil) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    clusterSize = size
                    publishInsets(height: size.height)
                }
                // The measurement only fires when the pad's own size changes, so tucking it — and re-docking, which
                // moves the reserved room to the other edge — have to re-publish too, or the score keeps scroll padding
                // for a pad that isn't there.
                .onChange(of: isPadExpanded) { _, _ in publishInsets(height: clusterSize.height) }
                .onChange(of: placement) { _, _ in publishInsets(height: clusterSize.height) }
                // Before the first measurement a tucked pad's offscreen offset can't be computed yet — hold it
                // invisible for that frame rather than flashing it across the score.
                .opacity(clusterSize == .zero && !isPadExpanded ? 0 : 1)
                // The rest base rides its OWN geometry effect — a distinct type, not a second `.offset` — while the
                // finger's travel streams through the plain offset below. The distinction is load-bearing: as two
                // `.offset`s (and worse, as one summed offset) the values shared one animatable storage, so every
                // unanimated drag frame retargeted it and killed the base's in-flight threshold swing — the pad jumped
                // unless the finger was nearly still, while the handle's opacity fade (its own attribute) survived
                // happily. A separate effect type gets separate storage, and the swing (driven by an explicit
                // `withAnimation` in the drag's `onChanged` — see `isRestorePreviewActive`) keeps running under the
                // stream.
                .modifier(PadRestShift(x: padRestOffsetX(in: viewport)))
                .offset(
                    x: dragTranslation.width + releasedTranslation.width,
                    y: dragTranslation.height + releasedTranslation.height,
                )
                // A cancelled drag skips `onEnded`, so no snap runs and the preview flag would strand the base at the
                // popped-out position. The gesture's translation springing back to zero with no release in flight is
                // that case.
                .onChange(of: dragTranslation) { _, translation in
                    guard translation == .zero, isRestorePreviewActive, releasedTranslation == .zero else { return }
                    withAnimation(Self.tuckSpring) { isRestorePreviewActive = false }
                }
                // Anywhere on the pad moves it — no grabber to aim at. `highPriorityGesture` is what makes that
                // possible without stealing the keys: a plain tap never travels the minimum distance, so the drag
                // stays unrecognized and the control underneath gets it; once the finger does travel, the drag wins
                // outright and the control it started on is cancelled rather than fired on release.
                .highPriorityGesture(dragGesture(viewport: viewport))
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
                    dock(to: placement == .bottom ? .top : .bottom, animation: Self.tuckSpring)
                }
                .accessibilityAction(named: Text(
                    isPadExpanded ? "editor.chrome.hidePad" : "editor.chrome.showPad", bundle: .module,
                )) {
                    snap(expanded: !isPadExpanded, animation: Self.tuckSpring)
                }
    }

    /// The pull tab, at rest flush against `tuckSide`'s edge at the tucked pad's vertical center, and carried by the
    /// same drag translation the pad is — so the two still move as one piece even though they are separate branches.
    /// The tab tap-restores via its own `Button`; the shared drag gesture is attached here too, so pulling the tab is
    /// the same gesture as pulling the pad.
    private func handleBranch(in viewport: CGSize) -> some View {
        // While a tucked pad is being pulled, the handle previews the release the way the PiP tab does: it stays up
        // while letting go would snap back, and fades once the drag has travelled far enough to stick — the same
        // crossing that sucks the pad's inner edge onto it. While the pad is out it is gone entirely; it fades in
        // with the tuck snap.
        let handleVisible = !isPadExpanded && clusterSize != .zero && EditorPadTuckGeometry.handleVisible(
            side: tuckSide,
            translationX: dragTranslation.width,
            threshold: EditorPadTuckGeometry.threshold(in: viewport),
        )
        let rest = handleRestPosition(in: viewport)
        return EditorPadTuckHandle(side: tuckSide) {
            snap(expanded: true, animation: Self.tuckSpring)
        }
        // The "bring it back" coach mark's anchor — reported only while the tab is actually the thing on screen.
        .onWindowFrameChange { frame in
            onPadHandleAnchorFrameChange(isPadExpanded ? nil : frame)
        }
        .onChange(of: isPadExpanded) { _, expanded in
            if expanded {
                onPadHandleAnchorFrameChange(nil)
            }
        }
        .onDisappear { onPadHandleAnchorFrameChange(nil) }
        .highPriorityGesture(dragGesture(viewport: viewport))
        .position(
            x: rest.x + dragTranslation.width + releasedTranslation.width,
            y: rest.y + dragTranslation.height + releasedTranslation.height,
        )
        .opacity(handleVisible ? 1 : 0)
        // Opacity 0 alone still hit-tests — and while the pad is out this sits invisibly over the score.
        .allowsHitTesting(handleVisible)
        // The mid-drag fade runs on the same curve as the pad's threshold swing, so the tab's exit and the card's
        // arrival read as one event; the snap transactions carry their own spring for everything else.
        .animation(Self.tuckSpring, value: handleVisible)
    }

    /// Where the tab rests while the pad is tucked: flush against the tuck side's edge, centered on the height the
    /// pad occupies at its dock — the same clearances `padBranch` gets from its alignment frame and paddings.
    private func handleRestPosition(in viewport: CGSize) -> CGPoint {
        let x = tuckSide == .trailing
            ? viewport.width - EditorPadTuckHandle.width / 2
            : EditorPadTuckHandle.width / 2
        let y = placement == .bottom
            ? viewport.height - bottomTransportClearance - 4 - clusterSize.height / 2
            : 4 + clusterSize.height / 2
        return CGPoint(x: x, y: y)
    }

    /// The cluster's resting horizontal offset: centered while the pad is out, parked past `tuckSide`'s edge while it
    /// is tucked — and, mid-drag past the restore threshold, shifted inward by the handle's width so the pad's inner
    /// edge sits exactly where the handle's is (see `restorePreviewRestOffsetX`).
    private func padRestOffsetX(in viewport: CGSize) -> CGFloat {
        guard !isPadExpanded else { return 0 }
        if isRestorePreviewActive {
            return EditorPadTuckGeometry.restorePreviewRestOffsetX(
                side: tuckSide,
                viewportWidth: viewport.width,
                padWidth: clusterSize.width,
                handleWidth: EditorPadTuckHandle.width,
                margin: EditorPadView.horizontalMargin,
            )
        }
        return EditorPadTuckGeometry.restOffsetX(
            side: tuckSide,
            viewportWidth: viewport.width,
            padWidth: clusterSize.width,
            margin: EditorPadView.horizontalMargin,
        )
    }

    /// Reports the cluster's footprint to the Reader (via the App) so the scrolling layouts can pad their scroll
    /// content by it — bottom dock only. A top-docked pad reserves nothing: a top inset shoved the whole score down
    /// the moment the pad docked up, which read as a layout glitch rather than reserved room, so up there the pad is
    /// a plain overlay. The bottom inset stays because it only pads the scroll END — the last system can be brought
    /// clear of the pad, and nothing visibly moves when it changes.
    private func publishInsets(height: CGFloat) {
        // A tucked pad reserves nothing: that room goes back to the score.
        let height = isPadExpanded ? height : 0
        switch placement {
        case .top: onClusterInsetsChange(0, 0)
        case .bottom: onClusterInsetsChange(0, height)
        }
    }
}

/// The pad's rest-base shift, as its own `GeometryEffect` so its animatable storage is distinct from the `.offset`
/// streaming the drag translation — see the comment at its use site in `padBranch`.
private struct PadRestShift: GeometryEffect {
    var x: CGFloat

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func effectValue(size _: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}
