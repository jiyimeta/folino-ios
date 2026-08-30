import EditorCore
import SwiftUI

/// The drag half of the editing cluster: the one gesture that repositions the pad between its docks AND tucks /
/// restores it past a side edge, plus the snap that settles every release. Split from `EditorChromeView.swift` for the
/// SwiftLint file-length budget — the pad-state properties it drives are declared there (internal for this reason).
extension EditorChromeView {
    func dragGesture(viewport: CGSize) -> some Gesture {
        // GLOBAL coordinate space, deliberately. In the default `.local` space the translation is measured against
        // the pad's own frame — which this very gesture is moving via `.offset`, so each frame's offset fed back into
        // the next frame's translation and the pad juddered instead of tracking the finger.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            // The restore-preview swing (see `isRestorePreviewActive`) is driven from here with an explicit
            // `withAnimation`, so it keeps animating while the drag continues to stream unanimated frames.
            .onChanged { value in
                guard !isPadExpanded else { return }
                let crossed = !EditorPadTuckGeometry.handleVisible(
                    side: tuckSide,
                    translationX: value.translation.width,
                    threshold: EditorPadTuckGeometry.threshold(in: viewport),
                )
                if crossed != isRestorePreviewActive {
                    withAnimation(Self.tuckSpring) { isRestorePreviewActive = crossed }
                }
            }
            .onEnded { value in
                // Hand the finger's travel over to state for one frame so the pad doesn't blink back to its old edge
                // as the gesture state evaporates; the animation below then unwinds it.
                releasedTranslation = value.translation
                endDrag(value: value, viewport: viewport)
            }
    }

    /// Moves the pad, animating the dock change and the drag offset's release together, then persists the choice.
    func dock(to destination: EditorPadPlacement, animation: Animation) {
        snap(expanded: isPadExpanded, placement: destination, animation: animation)
    }

    /// The one place the pad's resting state changes: expanded / tucked, the tuck side, and the dock. Everything
    /// moves in ONE transaction — the state change relocates the rest position while `releasedTranslation` unwinds
    /// the finger's travel, so the pad glides from wherever it was released straight to the new rest (unwinding the
    /// offset separately snapped the pad back to its old edge for a frame before the docking animation started).
    /// Persistence happens outside the animation.
    func snap(
        expanded: Bool,
        side: EditorPadTuckSide? = nil,
        placement: EditorPadPlacement? = nil,
        animation: Animation,
    ) {
        // Captured before the mutations: the gesture coach marks retire on the TRANSITIONS (a dock actually
        // changing, the pad actually going from out to tucked and back), not on every release.
        let didTuck = isPadExpanded && !expanded
        let didRestore = !isPadExpanded && expanded
        let didMoveDock = placement.map { $0 != self.placement } ?? false
        // The side flips BEFORE the transaction, unanimated: it only ever changes while the pad is out — when the
        // tab is parked offscreen past the OLD side's edge — and animating the flip would sail the tab across the
        // whole screen. Teleporting it to the new side's park first means the transaction below only ever slides it
        // in from the edge it belongs to.
        if let side {
            tuckSide = side
        }
        withAnimation(animation) {
            isPadExpanded = expanded
            if let placement {
                self.placement = placement
            }
            releasedTranslation = .zero
            // Every release resolves the preview: expanded makes it moot, tucked re-parks the base — either way the
            // return to rest has to ride this same transaction.
            isRestorePreviewActive = false
        }
        storedPadVisible = expanded
        if let side {
            storedTuckSide = side.rawValue
        }
        if let placement {
            storedPlacement = placement.rawValue
        }
        if didTuck {
            onPadTucked()
        }
        if didRestore {
            onPadRestored()
        }
        if didMoveDock {
            onPadDockMoved()
        }
    }

    /// The release decision. Both directions are judged on the drag's PROJECTED travel, so a flick commits without
    /// the finger covering the whole distance — the same reason re-docking judges where the pad ended up rather than
    /// raw translation.
    private func endDrag(value: DragGesture.Value, viewport: CGSize) {
        let threshold = EditorPadTuckGeometry.threshold(in: viewport)
        let projectedX = value.predictedEndTranslation.width
        if isPadExpanded {
            if let side = EditorPadTuckGeometry.tuckDestination(
                translationX: value.translation.width,
                projectedTranslationX: projectedX,
                velocity: value.velocity,
                threshold: threshold,
            ) {
                // Far enough toward a side edge: tuck past it. The snap and the handle's fade-in share one
                // transaction, so the tab is arriving exactly as the pad converges onto it. The vertical dock
                // re-derives from where the drag landed — a pull from the bottom toward the top-right corner means
                // "hide it up there", not "hide it at the dock it happened to be visible on".
                let landedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                    + value.predictedEndTranslation.height
                let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewport.height)
                snap(expanded: false, side: side, placement: destination, animation: Self.tuckSpring)
            } else {
                // A reposition, not a dismissal: re-dock top or bottom by where the pad ENDED UP, not by how far the
                // finger moved — a short flick near an edge shouldn't launch it across the screen.
                let landedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                    + value.predictedEndTranslation.height
                let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewport.height)
                dock(to: destination, animation: Self.tuckSpring)
            }
        } else {
            // The tab can be slid along its edge while staying hidden, so the vertical dock re-derives either way.
            let landedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                + value.predictedEndTranslation.height
            let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewport.height)
            let restores = EditorPadTuckGeometry.restoresFromTuck(
                side: tuckSide, projectedTranslationX: projectedX, threshold: threshold,
            )
            snap(expanded: restores, placement: destination, animation: Self.tuckSpring)
        }
    }

    /// The cluster's resting y-center at a dock — the reference both dock decisions measure landings against.
    /// The formula is `EditorPadTuckGeometry`'s, so Android's own dock answers the same gesture the same way.
    private func parkedCenterY(of placement: EditorPadPlacement, viewportHeight: CGFloat) -> CGFloat {
        EditorPadTuckGeometry.parkedCenterY(
            placement: placement, viewportHeight: viewportHeight, padHeight: clusterSize.height,
        )
    }
}
