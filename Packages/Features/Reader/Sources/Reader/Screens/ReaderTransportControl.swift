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

    /// Content height (above the bottom safe area) of the compact control — just the transport pill (44); no top or
    /// bottom padding, so it hugs the top of the bottom safe area. Used by `ReaderRootScreen` to inset the horizontal /
    /// page viewport so the score never renders under it.
    static let collapsedContentHeight: CGFloat = 44
    /// Height the expanded card's content reserves above the bottom safe area — top 6 + rehearsal-mark bar (32, with an
    /// -8 overlap onto the seek bar) + seek ~28 + time/title row (~17, pulled up -6) + transport row 44 ≈ 114. Reserved
    /// unconditionally (even for scores without rehearsal marks, which omit the mark bar) so the inset stays constant.
    /// The glass background additionally bleeds down into the safe area (stopping `cardMargin` from the physical edge),
    /// but that region sits below the safe area where the score never renders, so the inset only needs the content
    /// height. The A/B pill that floats above the card is intentionally excluded — it overlays the score bottom-right.
    static let expandedContentHeight: CGFloat = 114

    /// Spacing on each side of the centered prev / play / next triad in the expanded card — kept short so step-back and
    /// step-forward sit close to the play/pause button, equidistant from it. Matches VocalTuner's transport card.
    private static let transportTriadSpacing: CGFloat = 4

    /// Margin between the seek card and the screen edges (leading / trailing / bottom). Kept small so the card hugs the
    /// edges; the bottom corner radius is derived from it so the card nests concentrically inside the device's rounded
    /// screen. The glass invades the bottom safe area and stops this far from the physical edge; the content stays
    /// above the safe area. Matches VocalTuner's `cardMargin`.
    private static let cardMargin: CGFloat = 6
    /// Floor for the bottom corner radius, so square-cornered devices (e.g. iPhone SE, iPad) still get a rounded card.
    private static let minCardCornerRadius: CGFloat = 14
    /// Fixed radius for the card's free top corners — a smaller, constant value than the device-hugging bottom corners
    /// (Apple's medium-detent sheet pattern, matching VocalTuner).
    private static let topCornerRadius: CGFloat = 18
    /// Upper bound on the card width. On wide screens (iPad) the card stops growing and is center-aligned instead of
    /// spanning the full width, keeping the seek bar within comfortable reach.
    private static let maxCardWidth: CGFloat = 520

    /// Bottom corner radius that nests the card concentrically inside the device's screen corners: `deviceCorner -
    /// margin`, floored at `minCardCornerRadius` for square-cornered devices.
    private var bottomCornerRadius: CGFloat {
        max(DeviceMetrics.screenCornerRadius - Self.cardMargin, Self.minCardCornerRadius)
    }

    private var loadedScore: Score? {
        if case let .loaded(score) = viewModel.loadState { return score }
        return nil
    }

    /// The score the transport drives: the natively loaded score, or — for a PDF whose background parse
    /// succeeded — its parsed-for-playback score. `nil` until something is playable, so the transport
    /// stays collapsed (and the expanded seek card is withheld) until then.
    private var transportScore: Score? {
        if let loadedScore { return loadedScore }
        return viewModel.isPDFPlaybackReady ? viewModel.playbackScore : nil
    }

    var body: some View {
        if showSeekBar, let score = transportScore {
            expandedLayout(score: score)
        } else {
            collapsedLayout
        }
    }

    /// Score name shown under the seek bar — the same text Library lists (title plus subtitle when present).
    private var scoreDisplayTitle: String {
        let title = viewModel.scoreItem.title
        if let subtitle = viewModel.scoreItem.subtitle, !subtitle.isEmpty {
            return "\(title) \(subtitle)"
        }
        return title
    }

    // MARK: Collapsed (compact pill)

    private var collapsedLayout: some View {
        HStack(spacing: 12) {
            Spacer()
            // Playback affordances (A/B endpoints + transport pill) render for a loaded score, and — once a
            // PDF's background OMR parse succeeds — for a playable PDF too. A PDF whose parse hasn't landed
            // (or failed) keeps `canPlay` false and `isPDFPlaybackReady` false, so the transport collapses.
            // Zoom and page-navigation gestures live in the reader containers and remain available regardless.
            if viewModel.capabilities.canPlay {
                endpointButtons(flat: false)
                if case .loaded = viewModel.loadState {
                    transportPill
                }
            } else if viewModel.isPDFPlaybackReady {
                // A playable PDF gets the full playback inspector, so AB-loop is selectable there and its endpoints
                // belong here too — they snap against the parsed score like any other transport action.
                endpointButtons(flat: false)
                transportPill
            }
        }
        .padding(.horizontal)
        // No bottom padding: the control sits as low as possible, flush against the top of the bottom safe area
        // (just above the home indicator) without invading it.
    }

    // MARK: Expanded (full-width seek card)

    private func expandedLayout(score: Score) -> some View {
        VStack(spacing: 8) {
            // The A/B endpoint pill floats above the card, pinned to the score area's bottom-right, only in AB-loop
            // mode — pushed out of the card so the transport row reads cleanly.
            if viewModel.repeatModel.mode == .abLoop {
                HStack {
                    Spacer()
                    endpointButtons(flat: false)
                }
                .frame(maxWidth: Self.maxCardWidth)
                .padding(.horizontal, Self.cardMargin)
            }
            seekCard(score: score)
        }
    }

    private func seekCard(score: Score) -> some View {
        VStack(spacing: 0) {
            SeekRegion(
                playbackSession: viewModel.playbackSession,
                marks: score.readerRehearsalMarks(),
                durationSeconds: score.notatedDurationSeconds,
                title: scoreDisplayTitle,
                onScrubCommit: { viewModel.logSeekCommitted() },
            )
            transportRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .frame(maxWidth: Self.maxCardWidth)
        .background {
            // The glass invades the bottom safe area (`.ignoresSafeArea`) but its own `.padding(.bottom, cardMargin)`
            // keeps the rounded rect `cardMargin` clear of the physical edge, nesting it concentrically inside the
            // device corners. The free top corners use a smaller fixed radius. The foreground content is unaffected by
            // `.ignoresSafeArea`, so it stays above the home indicator.
            let bottom = bottomCornerRadius
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: min(Self.topCornerRadius, bottom),
                bottomLeadingRadius: bottom,
                bottomTrailingRadius: bottom,
                topTrailingRadius: min(Self.topCornerRadius, bottom),
                style: .continuous,
            )
            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
                .padding(.bottom, Self.cardMargin)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .compositingGroup()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal, Self.cardMargin)
    }

    /// Transport row. The prev / play / next triad is centered as one tight group, so play/pause sits at the card's
    /// horizontal center. The jump-to-start (or previous-score) button is pinned to the leading edge and, in a
    /// playlist, the next-score button to the trailing edge; equal flexible side groups keep the triad centered whether
    /// or not the trailing button is present.
    private var transportRow: some View {
        HStack(spacing: 0) {
            jumpBackButton
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Self.transportTriadSpacing) {
                stepBackwardButton
                playPauseButton(width: 56, height: 44, glyphSize: 34)
                stepForwardButton
            }

            trailingNavGroup
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Trailing side of the transport row: the next-score button in a playlist, otherwise a 44pt clear placeholder.
    /// The placeholder is essential — an empty `@ViewBuilder` branch under `.frame(maxWidth: .infinity)` collapses to
    /// zero width, so the leading group would claim all the slack and shove the centered triad to the right.
    @ViewBuilder private var trailingNavGroup: some View {
        if viewModel.isInPlaylist {
            nextScoreButton
        } else {
            Color.clear.frame(width: 44, height: 44)
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

    private var transportPill: some View {
        HStack(spacing: 0) { transportButtonsContent }
            .glassEffect(.regular.interactive())
            .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
    }

    /// Primary transport buttons in document order: jump-to-start (or previous score), step back a measure, play/pause,
    /// step forward a measure, then — in a playlist — next score. Used in sequence by the collapsed pill and piecewise
    /// by the expanded card, so the two layouts stay in sync.
    @ViewBuilder private var transportButtonsContent: some View {
        jumpBackButton
        stepBackwardButton
        playPauseButton()
        stepForwardButton
        if viewModel.isInPlaylist {
            nextScoreButton
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

    /// Play/pause. `width` / `height` / `glyphSize` default to the standard transport size (used by the collapsed
    /// pill); the expanded card passes a larger glyph and width so play/pause reads as the primary control while
    /// keeping the row's 44pt height.
    private func playPauseButton(width: CGFloat = 44, height: CGFloat = 44, glyphSize: CGFloat = 20) -> some View {
        transportButton(
            label: Text(
                viewModel.playbackSession.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                bundle: .module,
            ),
            width: width,
            height: height,
        ) {
            Task { await viewModel.togglePlayback() }
        } glyph: {
            Image(systemName: viewModel.playbackSession.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: glyphSize, weight: .medium))
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

#if DEBUG
/// Three quarter-rests-per-measure score so AB-loop endpoints can snap to a chord (`snapMeasureEnd` needs at least one
/// `.chord` — rests count). Empty measures would let `setA` work but not `setB`. With `includeMarks` false the score
/// carries no rehearsal marks, so the seek card omits the mark bar — used to confirm the time readout (anchored to the
/// seek bar) stays put whether or not marks are present.
@MainActor
private func transportPreviewViewModel(includeMarks: Bool = true) -> ReaderViewModel {
    let restChords = Array(
        repeating: VoiceElement.chord(Chord(duration: .quarter, notes: [])),
        count: 4,
    )
    let restMeasure = Measure(voices: [Voice(elements: restChords)])
    /// Rehearsal marks on measures 0 and 2 — one short, one long (to exercise truncation) — so the mark bubbles render.
    func marked(_ text: String) -> SystemMeasure {
        SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: text))),
        ])
    }
    let score = Score(
        division: 480,
        parts: [
            Part(
                id: "P0",
                instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [restMeasure, restMeasure, restMeasure])],
            ),
        ],
        systemMeasures: includeMarks ? [marked("A"), SystemMeasure(), marked("B — Chorus, softer")] : [],
        metaTags: [:],
    )
    return ReaderViewModel(
        scoreItem: PreviewFakeRepository.sampleItem,
        repository: PreviewFakeRepository(),
        gateway: PreviewFakeGateway(score: score),
        scoresDirectory: URL(filePath: "/tmp"),
    )
}

/// Puts the control into AB-loop with only the A endpoint set, so the A/B pill shows its split state (A set, B unset).
@MainActor
private func configureTransportPreview(_ vm: ReaderViewModel) async {
    await vm.load()
    vm.repeatModel.mode = .abLoop
    vm.playbackSession.setManualCursor(.beat(measureIndex: 1, tickInMeasure: 0))
    await vm.repeatModel.setA()
}

#Preview("Transport control · seek bar") {
    let vm = transportPreviewViewModel()
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: true)
    }
    .task { await configureTransportPreview(vm) }
}

#Preview("Transport control · seek bar (no marks)") {
    let vm = transportPreviewViewModel(includeMarks: false)
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: true)
    }
    .task { await configureTransportPreview(vm) }
}

#Preview("Transport control · collapsed") {
    let vm = transportPreviewViewModel()
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: false)
    }
    .task { await configureTransportPreview(vm) }
}
#endif
