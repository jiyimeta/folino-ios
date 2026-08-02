import Domain
import SheetMusicCore
import SwiftUI
import UtilityUI

/// Bottom transport control. When `showSeekBar` is true it renders a full-width glass card (seek bar over a transport
/// row); when false it keeps the compact right-aligned pill. Rendered inside `ReaderRootScreen`'s `ZStack` so it sits
/// over the score and keeps the transport within thumb reach at the bottom of the screen.
struct ReaderTransportControl: View {
    @Bindable var viewModel: ReaderViewModel
    /// When true, render the full-width seek-bar card; when false, the compact transport pill.
    let showSeekBar: Bool
    /// Called when a horizontal swipe over the transport asks for the other mode — `false` to collapse to the compact
    /// pill, `true` to bring the seek card back. The owner holds the (persisted) preference this mirrors, and returns
    /// whether it took the change: it declines while editing, and the card then animates back instead of holding a
    /// mode the owner is not going to render.
    var onSetSeekBarVisible: (Bool) -> Bool = { _ in false }

    /// The three swipe properties below are internal, not private: the gesture that drives them lives in
    /// `ReaderTransportControl+ModeSwipe.swift`, and Swift's `private` doesn't span files.
    ///
    /// Live finger travel while the transport is being swiped. `@GestureState`, NOT `@State`: SwiftUI resets it on its
    /// own when the gesture ends **or is cancelled**, so an interrupted swipe can never strand the control half-way
    /// off its edge.
    @GestureState var swipeTranslation: CGSize = .zero
    /// The (already rubber-banded) offset captured at the moment the finger lifts, sprung back to zero from there so
    /// the control glides out of where it was released instead of blinking back as the gesture state evaporates.
    /// Stored post-damping so the mode flipping underneath it can't retroactively change what the same travel means.
    @State var releasedSwipeOffset: CGFloat = 0
    /// The mode the card previews mid-swipe, once the finger has passed the commit threshold. `nil` means "follow the
    /// preference" — outside a swipe, and inside one until it has travelled far enough to commit.
    @State var previewSeekBar: Bool?
    /// Room the control has to lay out in, measured because the card's width has to be an explicit, animatable number
    /// rather than a flexible frame. Starts at 0, which reads as "not measured yet" (see `cardWidth`).
    @State private var availableWidth: CGFloat = 0
    /// The expanded card's own content height, measured for the same reason (see `cardHeight`). `nil` until the card
    /// has been laid out expanded at least once.
    @State private var expandedCardHeight: CGFloat?

    /// Content height (above the bottom safe area) of the compact control — just the transport pill (44); no top or
    /// bottom padding, so it hugs the top of the bottom safe area. Used by `ReaderRootScreen` to inset the horizontal /
    /// page viewport so the score never renders under it.
    static let collapsedContentHeight = TransportCardMetrics.collapsedHeight
    /// Height the expanded card's content reserves above the bottom safe area — top 6 + rehearsal-mark bar (32, with an
    /// -8 overlap onto the seek bar) + seek ~28 + time/title row (~17, pulled up -6) + transport row 44 ≈ 114. Reserved
    /// unconditionally (even for scores without rehearsal marks, which omit the mark bar) so the inset stays constant.
    /// The glass background additionally bleeds down into the safe area (stopping `cardMargin` from the physical edge),
    /// but that region sits below the safe area where the score never renders, so the inset only needs the content
    /// height. The A/B pill that floats above the card is intentionally excluded — it overlays the score bottom-right.
    static let expandedContentHeight: CGFloat = 114

    private var loadedScore: Score? {
        if case let .loaded(score) = viewModel.loadState { return score }
        return nil
    }

    /// The score the transport drives: the natively loaded score, or — for a PDF whose background parse
    /// succeeded — its parsed-for-playback score. `nil` until something is playable, so the transport
    /// stays collapsed (and the expanded seek card is withheld) until then. Internal so `rendersSeekBar` can gate on
    /// it from `ReaderTransportControl+ModeSwipe.swift`.
    var transportScore: Score? {
        if let loadedScore { return loadedScore }
        return viewModel.isPDFPlaybackReady ? viewModel.playbackScore : nil
    }

    var body: some View {
        // Every measurement the card is built from is interpolated between the two modes rather than switched (see
        // `TransportCardMetrics`), and `MorphReader` is what puts that interpolation on the animation clock — out of
        // reach of the per-frame layout passes a moving finger causes.
        MorphReader(morph: rendersSeekBar ? 1 : 0) { morph in
            layout(TransportCardMetrics(
                morph: morph,
                availableWidth: availableWidth,
                isInPlaylist: viewModel.isInPlaylist,
                measuredExpandedHeight: expandedCardHeight,
            ))
        }
        // Once the preference has caught up with what a swipe settled on, the local hold is redundant — drop it so
        // the preference is the single source of truth again. Both say the same thing at that point, so nothing
        // moves. Guarded on agreement because the owner writes the preference a beat AFTER the swipe (it holds the
        // write until the release animations finish — see `ReaderRootScreen.setSeekBarVisible`): inside that window
        // a write that DISAGREES with the hold can land (an earlier swipe's write racing a re-swipe, a Settings
        // toggle), and dropping the hold on one of those would visibly flip the card to a mode nobody just asked
        // for.
        .onChange(of: showSeekBar) { _, newValue in
            if previewSeekBar == newValue { previewSeekBar = nil }
        }
        // The swipe coach mark has no button to press, so tapping it asks the transport to perform the gesture itself.
        .onChange(of: ReaderHintCoordinator.shared.transportModeSwitchRequests) { _, _ in
            performHintedModeSwitch()
        }
        // The offset carries the finger frame by frame and is deliberately left un-animated: smoothing it would leave
        // the card lagging behind the finger. Horizontal only — the transport is docked to the bottom edge, so
        // vertical travel has nowhere to go.
        .offset(x: swipeOffset)
    }

    private func layout(_ metrics: TransportCardMetrics) -> some View {
        VStack(spacing: 8) {
            // In the expanded layout the A/B endpoint pill floats above the card, pinned to the score area's
            // bottom-right — pushed out of the card so the transport row reads cleanly.
            if rendersSeekBar, showsEndpointPill {
                HStack {
                    Spacer()
                    endpointButtons(flat: false)
                }
                .frame(maxWidth: TransportCardMetrics.maxCardWidth)
                .padding(.horizontal, TransportCardMetrics.cardMargin)
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                // Compact has no card above to hang the endpoints off, so they sit inline, to the pill's left.
                if !rendersSeekBar, showsEndpointPill {
                    endpointButtons(flat: false)
                        .transition(.opacity)
                }
                if showsTransportCard {
                    card(metrics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, metrics.trailingInset)
            // No bottom padding: the control sits as low as possible, flush against the top of the bottom safe area
            // (just above the home indicator) without invading it.
        }
        // The card's width is an explicit number so it can be interpolated, which means the room it has to work with
        // must be measured rather than inferred from a flexible frame.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    /// Score name shown under the seek bar — the same text Library lists (title plus subtitle when present).
    private var scoreDisplayTitle: String {
        let title = viewModel.scoreItem.title
        if let subtitle = viewModel.scoreItem.subtitle, !subtitle.isEmpty {
            return "\(title) \(subtitle)"
        }
        return title
    }

    // MARK: The card

    /// Playback affordances render for a loaded score, and — once a PDF's background OMR parse succeeds — for a
    /// playable PDF too. A PDF whose parse hasn't landed (or failed) keeps `canPlay` and `isPDFPlaybackReady` false,
    /// so the transport stays away entirely. Zoom and page-navigation gestures live in the reader containers and
    /// remain available regardless.
    private var showsTransportCard: Bool {
        if viewModel.capabilities.canPlay, case .loaded = viewModel.loadState { return true }
        return viewModel.isPDFPlaybackReady
    }

    /// A playable PDF gets the full playback inspector, so AB-loop is selectable there and its endpoints belong here
    /// too — they snap against the parsed score like any other transport action.
    private var showsEndpointPill: Bool {
        viewModel.repeatModel.mode == .abLoop
            && (viewModel.capabilities.canPlay || viewModel.isPDFPlaybackReady)
    }

    /// The transport card. One view in both modes — every difference between them is a number `metrics` interpolates —
    /// so the buttons both modes share *move* into their new places instead of crossfading, while the card resizes
    /// around them and the expanded-only seek region fades.
    private func card(_ metrics: TransportCardMetrics) -> some View {
        VStack(spacing: 0) {
            if metrics.showsSeekRegion, transportScore != nil {
                // Marks and duration come from the view model's cached `seekTimeline`, NOT from the score here:
                // deriving them walks the whole score (quadratic in measures — see `ReaderSeekTimeline`), and this
                // body runs on every frame of the morph and on every finger movement of a swipe. Recomputing them
                // per frame is what made a fast swipe visibly drop frames.
                SeekRegion(
                    playbackSession: viewModel.playbackSession,
                    marks: viewModel.seekTimeline.marks,
                    durationSeconds: viewModel.seekTimeline.durationSeconds,
                    title: scoreDisplayTitle,
                    onScrubCommit: { viewModel.logSeekCommitted() },
                )
                // Expanded-only, so it fades with the same value that resizes the card around it.
                .opacity(metrics.seekRegionOpacity)
            }
            transportRow(metrics)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, metrics.topPadding)
        // Measured before the frame below is imposed, so this reads the content's own height rather than the box the
        // morph is currently drawing — and only while fully open, so a half-closed card can't write a short height
        // back over the real one.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard metrics.isFullyExpanded, height > 0 else { return }
            expandedCardHeight = height
        }
        // Bottom-aligned: the transport row is the part both modes share, so it stays put against the bottom edge
        // while the box grows and shrinks above it. `clipped` then turns the seek region's fade into a reveal from
        // behind the card's top edge instead of letting it spill outside the shrinking box.
        .frame(width: metrics.width, height: metrics.height, alignment: .bottom)
        .clipped()
        .background { cardBackground(metrics) }
        .compositingGroup()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        // Attached to the card rather than to the control: the control is always mounted (it fades for annotation and
        // stays put), but the card is only built when there is something to transport.
        //
        // Two mutually exclusive anchors, because each state teaches the opposite swipe and each coach mark's copy
        // names a direction. Which one is anchored is also what decides which hint is eligible, so the pill can never
        // be told to "swipe right to shrink it".
        .readerHintAnchor(.transportExpanded, isActive: rendersSeekBar)
        .readerHintAnchor(.transportCompact, isActive: !rendersSeekBar)
    }

    /// Transport row. The prev / play / next triad is centered as one tight group, so play/pause sits at the card's
    /// horizontal center. The jump-to-start (or previous-score) button is pinned to the leading edge and, in a
    /// playlist, the next-score button to the trailing edge; equal flexible side groups keep the triad centered whether
    /// or not the trailing button is present.
    ///
    /// The compact pill is the same row with the slack taken out: the card narrows to the buttons' own width, the
    /// flexible side frames collapse, and the triad closes up — so the buttons slide into the pill rather than being
    /// replaced by a second copy of themselves.
    private func transportRow(_ metrics: TransportCardMetrics) -> some View {
        HStack(spacing: 0) {
            jumpBackButton
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: metrics.triadSpacing) {
                stepBackwardButton
                playPauseButton(metrics)
                stepForwardButton
            }

            trailingNavGroup(metrics)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Only this row carries the mode swipe — deliberately NOT the seek bar or the rehearsal-mark bar above it,
        // whose own horizontal drags (scrub, mark jump) own those pixels. In the compact pill the row IS the card, so
        // the same attachment covers it.
        .transportModeSwipe(modeSwipeGesture)
    }

    /// Trailing side of the transport row: the next-score button in a playlist, otherwise a clear placeholder that
    /// shrinks away with the rest of the card (see `TransportCardMetrics.trailingPlaceholderWidth` for why the
    /// expanded card needs it at all).
    @ViewBuilder private func trailingNavGroup(_ metrics: TransportCardMetrics) -> some View {
        if viewModel.isInPlaylist {
            nextScoreButton
        } else {
            Color.clear.frame(width: metrics.trailingPlaceholderWidth, height: TransportCardMetrics.buttonWidth)
        }
    }

    // MARK: Shared pieces

    /// A / B repeat-endpoint pill, shown only in AB-loop mode. `flat` selects the expanded card's quiet material look
    /// over the floating interactive glass + shadow.
    @ViewBuilder private func endpointButtons(flat: Bool) -> some View {
        if viewModel.repeatModel.mode == .abLoop {
            ABEndpointPill(
                aSet: viewModel.repeatModel.pendingRepeatA != nil,
                bSet: viewModel.repeatModel.pendingRepeatB != nil,
                flat: flat,
                onSetA: { Task { await viewModel.repeatModel.setA() } },
                onSetB: { Task { await viewModel.repeatModel.setB() } },
            )
        }
    }

    /// Leading transport button. Normally rewinds to the first measure; in a playlist, pressing it while already parked
    /// at measure 1 jumps to the previous score instead (falling back to rewind at the head of the playlist, so it is
    /// never disabled).
    private var jumpBackButton: some View {
        transportButton(
            label: Text("reader.toolbar.jumpToStart", bundle: .module),
        ) {
            let atStart = (viewModel.playbackSession.playbackCursor?.measureIndex ?? 0) == 0
            if viewModel.isInPlaylist, atStart, viewModel.hasPreviousPlaylistScore {
                Task { await viewModel.goToPreviousScore() }
            } else {
                viewModel.seekToStart()
            }
        } glyph: {
            Image(systemName: "backward.fill")
                .font(.system(size: 20, weight: .medium))
        }
    }

    private var nextScoreButton: some View {
        transportButton(
            label: Text("reader.toolbar.nextScore", bundle: .module),
        ) {
            Task { await viewModel.goToNextScore() }
        } glyph: {
            Image(systemName: "forward.fill")
                .font(.system(size: 20, weight: .medium))
        }
        .disabled(!viewModel.hasNextPlaylistScore)
    }

    private var stepBackwardButton: some View {
        transportButton(
            label: Text("reader.toolbar.stepBackward", bundle: .module),
        ) {
            viewModel.stepMeasureBackward()
        } glyph: {
            MeasureSkipSymbol(direction: .backward)
        }
    }

    private var stepForwardButton: some View {
        transportButton(
            label: Text("reader.toolbar.stepForward", bundle: .module),
        ) {
            viewModel.stepMeasureForward()
        } glyph: {
            MeasureSkipSymbol(direction: .forward)
        }
    }

    /// Play/pause. The expanded card gives it a wider hit area and a bigger glyph so it reads as the primary control,
    /// while keeping the row's 44pt height; the compact pill takes both back. The glyph is drawn at the expanded size
    /// and scaled, never re-fonted, so the two sizes interpolate instead of snapping halfway through the morph.
    private func playPauseButton(_ metrics: TransportCardMetrics) -> some View {
        transportButton(
            label: Text(
                viewModel.playbackSession.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                bundle: .module,
            ),
            width: metrics.playWidth,
        ) {
            Task { await viewModel.togglePlayback() }
        } glyph: {
            Image(systemName: viewModel.playbackSession.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: TransportCardMetrics.expandedPlayGlyphSize, weight: .medium))
                .scaleEffect(metrics.playGlyphScale)
        }
    }

    private func transportButton(
        label: Text,
        width: CGFloat = 44,
        height: CGFloat = 44,
        action: @escaping () -> Void,
        @ViewBuilder glyph: () -> some View,
    ) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: width, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .tint(.primary)
        .accessibilityLabel(label)
    }
}
