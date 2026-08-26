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
        withAnimation(animation) {
            isPadExpanded = expanded
            if let side {
                tuckSide = side
            }
            if let placement {
                self.placement = placement
            }
            releasedTranslation = .zero
        }
        storedPadVisible = expanded
        if let side {
            storedTuckSide = side.rawValue
        }
        if let placement {
            storedPlacement = placement.rawValue
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
                projectedTranslationX: projectedX, threshold: threshold,
            ) {
                // Far enough toward a side edge: tuck past it. The snap and the handle's fade-in share one
                // transaction, so the tab is arriving exactly as the pad converges onto it.
                let restX = EditorPadTuckGeometry.restOffsetX(
                    side: side, viewportWidth: viewport.width, padWidth: clusterSize.width,
                )
                snap(expanded: false, side: side, animation: Self.snapAnimation(
                    from: value.translation.width, to: restX, releaseVelocity: value.velocity.width,
                ))
            } else {
                // A reposition, not a dismissal: re-dock top or bottom by where the pad ENDED UP, not by how far the
                // finger moved — a short flick near an edge shouldn't launch it across the screen.
                let releasedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                    + value.translation.height
                let landedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                    + value.predictedEndTranslation.height
                let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewport.height)
                dock(to: destination, animation: Self.snapAnimation(
                    from: releasedCenter,
                    to: parkedCenterY(of: destination, viewportHeight: viewport.height),
                    releaseVelocity: value.velocity.height,
                ))
            }
        } else {
            // The tab can be slid along its edge while staying hidden, so the vertical dock re-derives either way.
            let landedCenter = parkedCenterY(of: placement, viewportHeight: viewport.height)
                + value.predictedEndTranslation.height
            let destination = EditorPadPlacement.nearest(toCenterY: landedCenter, in: viewport.height)
            let restores = EditorPadTuckGeometry.restoresFromTuck(
                side: tuckSide, projectedTranslationX: projectedX, threshold: threshold,
            )
            snap(expanded: restores, placement: destination, animation: Self.snapAnimation(
                from: value.translation.width,
                to: restores
                    ? -EditorPadTuckGeometry.restOffsetX(
                        side: tuckSide, viewportWidth: viewport.width, padWidth: clusterSize.width,
                    )
                    : 0,
                releaseVelocity: value.velocity.width,
            ))
        }
    }

    /// The cluster's resting y-center at a dock — the reference both dock decisions measure landings against.
    private func parkedCenterY(of placement: EditorPadPlacement, viewportHeight: CGFloat) -> CGFloat {
        placement == .bottom ? viewportHeight - clusterSize.height / 2 : clusterSize.height / 2
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
    ///
    /// Axis-agnostic — the vertical re-dock and the horizontal tuck / restore snaps all come through here; only the
    /// travel and the release velocity on the axis being settled matter.
    private static func snapAnimation(
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
}
