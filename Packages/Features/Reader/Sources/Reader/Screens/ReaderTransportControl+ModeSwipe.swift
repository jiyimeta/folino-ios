import SwiftUI

/// The transport's swipe-to-switch-mode gesture: how the control tracks the finger, when it flips the card under it,
/// and what it does with the travel on release. Split out of `ReaderTransportControl.swift` to keep that file under
/// SwiftLint's file-length limit; the thresholds and curves themselves live in `TransportModeSwipe`.
extension ReaderTransportControl {
    /// The mode the card is drawn in right now: the swipe's live preview once the finger has passed the commit
    /// threshold, otherwise the persisted preference. Withheld until there is something to seek through.
    var rendersSeekBar: Bool {
        (previewSeekBar ?? showSeekBar) && transportScore != nil
    }

    /// Where the control sits right now: the live rubber-banded finger travel while a swipe is in progress, plus the
    /// released offset that is springing back to zero. Only ever one of the two is non-zero.
    var swipeOffset: CGFloat {
        TransportModeSwipe.followOffset(translation: swipeTranslation.width, isExpanded: showSeekBar)
            + releasedSwipeOffset
    }

    /// Switches modes because the swipe coach mark was tapped, by acting out the swipe rather than just flipping the
    /// mode: the control slides `commitDistance` in the direction the finger would have gone, the card morphs under
    /// it, and the same release spring carries it home. Someone who has never found the gesture sees exactly what it
    /// does — and where their finger has to go to do it again.
    ///
    /// Paced as a DELIBERATE swipe (`swipeSpeed: 0` floors to `deliberateSwipeSpeed`), not a flick: this is a
    /// demonstration, and the slow curves are the legible ones.
    func performHintedModeSwitch() {
        let target = !rendersSeekBar
        // Declined while editing, exactly as a real swipe would be — leave the control alone rather than half-play it.
        guard onSetSeekBarVisible(target) else { return }
        // Expanded collapses on a right swipe, compact expands on a left one (see `followOffset`).
        let travel = TransportModeSwipe.commitDistance * (target ? -1 : 1)

        withAnimation(.easeOut(duration: TransportModeSwipe.hintedSwipeOutDuration)) {
            releasedSwipeOffset = travel
        }
        withAnimation(TransportModeSwipe.modeSwapAnimation(swipeSpeed: 0)) {
            previewSeekBar = target
        }
        Task {
            try? await Task.sleep(for: .seconds(TransportModeSwipe.hintedSwipeOutDuration))
            withAnimation(TransportModeSwipe.releaseAnimation(from: travel, releaseVelocity: 0)) {
                releasedSwipeOffset = 0
            }
        }
    }

    /// Drag that switches the transport between the expanded seek card and the compact pill.
    ///
    /// GLOBAL coordinate space, deliberately: in the default `.local` space the translation is measured against the
    /// control's own frame — which this very gesture is moving via `.offset` — so each frame's offset feeds into the
    /// next frame's translation and the control judders instead of tracking the finger.
    var modeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($swipeTranslation) { value, state, _ in state = value.translation }
            .onChanged { value in
                // Flip the card UNDER the finger the moment the swipe passes the commit threshold, so the resize is
                // part of the gesture rather than a surprise at the end. One way for the rest of the gesture: the
                // morph is a half-second of motion, and letting the finger flip it back and forth across the
                // threshold would restart it from a new size every time. A finger that wanders back under the
                // threshold is answered at release instead, where `outcome` sends the card home.
                //
                // The fling projection is deliberately left out here (`predictedEndTranslation` is fed the plain
                // translation): a preview should follow the finger, not guess where it is headed.
                guard previewSeekBar == nil else { return }
                let preview: Bool? = switch TransportModeSwipe.outcome(
                    translation: value.translation,
                    predictedEndTranslation: value.translation,
                ) {
                case .collapse: showSeekBar ? false : nil
                case .expand: showSeekBar ? nil : true
                case .ignore: nil
                }
                // Inside an explicit transaction: an implicit `.animation(_:value:)` is ignored during a gesture's
                // continuous updates. Paced by how fast the finger was travelling when it crossed — a flick gets a
                // morph that keeps up with it, a deliberate drag gets the long one.
                guard let preview else { return }
                withAnimation(TransportModeSwipe.modeSwapAnimation(swipeSpeed: value.velocity.width)) {
                    previewSeekBar = preview
                }
            }
            .onEnded { value in
                // Freeze the damped travel into state for one frame so the control doesn't blink back to its edge as
                // the gesture state evaporates; the spring below then unwinds it.
                let released = TransportModeSwipe.followOffset(
                    translation: value.translation.width,
                    isExpanded: showSeekBar,
                )
                releasedSwipeOffset = released

                // The mode the card holds from here on. It stays local rather than deferring to the preference the
                // line below writes: the preference is `@AppStorage`, and its new value round-trips through
                // `UserDefaults` to arrive outside this transaction — unanimated (the trap `EditorChromeView`
                // documents for the pad's persisted placement). Holding it locally is what glides a *flicked* swipe
                // into its new size, where the travel never reached the threshold and no preview ever fired.
                //
                // `nil` when the swipe changes nothing, or when the owner declines it (it does while editing): the
                // card then animates back to whatever the preference says.
                var settled: Bool? = switch TransportModeSwipe.outcome(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                ) {
                case .collapse: onSetSeekBarVisible(false) ? false : nil
                case .expand: onSetSeekBarVisible(true) ? true : nil
                case .ignore: nil
                }
                withAnimation(TransportModeSwipe.modeSwapAnimation(swipeSpeed: value.velocity.width)) {
                    previewSeekBar = settled
                }

                withAnimation(
                    TransportModeSwipe.releaseAnimation(from: released, releaseVelocity: value.velocity.width),
                ) {
                    releasedSwipeOffset = 0
                }
            }
    }
}
