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

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    /// Content height (above the bottom safe area) of the compact control — just the transport pill (44); no top or
    /// bottom padding, so it hugs the top of the bottom safe area. Used by `ReaderRootScreen` to inset the horizontal /
    /// page viewport so the score never renders under it.
    static let collapsedContentHeight: CGFloat = 44
    /// Height the expanded card's content reserves above the bottom safe area — top 12 + rehearsal-mark bar (32, with
    /// an -8 overlap onto the seek bar) + seek ~28 + transport row 44 ≈ 108. Reserved unconditionally (even for scores
    /// without rehearsal marks, which omit the mark bar) so the inset stays a constant. The glass background
    /// additionally bleeds down into the safe area (stopping `cardMargin` from the physical edge), but that region sits
    /// below the safe area where the score never renders, so the inset only needs the content height.
    static let expandedContentHeight: CGFloat = 108

    /// Spacing on each side of the centered prev / play / next triad in the expanded card — kept short so step-back and
    /// step-forward sit close to the play/pause button, equidistant from it.
    private static let transportTriadSpacing: CGFloat = 12

    /// Margin between the seek card and the screen edges (leading / trailing / bottom). Kept small so the card hugs the
    /// edges; the corner radius is derived from it so the card nests concentrically inside the device's rounded screen.
    /// The glass invades the bottom safe area and stops this far from the physical edge; the content stays above the
    /// safe area.
    private static let cardMargin: CGFloat = 10
    /// Floor for the card's corner radius, so square-cornered devices (e.g. iPhone SE, iPad) still get a rounded card.
    private static let minCardCornerRadius: CGFloat = 16
    /// Upper bound on the card width. On wide screens (iPad) the card stops growing and is center-aligned instead of
    /// spanning the full width, keeping the seek bar within comfortable reach.
    private static let maxCardWidth: CGFloat = 520

    /// Corner radius that nests the card concentrically inside the device's screen corners: `deviceCorner - margin`,
    /// floored at `minCardCornerRadius` for square-cornered devices.
    private var cardCornerRadius: CGFloat {
        max(DeviceMetrics.screenCornerRadius - Self.cardMargin, Self.minCardCornerRadius)
    }

    private var loadedScore: Score? {
        if case let .loaded(score) = viewModel.loadState { return score }
        return nil
    }

    var body: some View {
        if showSeekBar, let score = loadedScore {
            expandedLayout(score: score)
        } else {
            collapsedLayout
        }
    }

    // MARK: Collapsed (today's layout)

    private var collapsedLayout: some View {
        HStack(spacing: 12) {
            resetZoomButton
            Spacer()
            endpointButtons(flat: false)
            if case .loaded = viewModel.loadState {
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
            if viewModel.viewportZoom > 1.0 {
                HStack { resetZoomButton; Spacer() }
                    .frame(maxWidth: Self.maxCardWidth)
                    .padding(.horizontal, Self.cardMargin)
            }
            seekCard(score: score)
        }
    }

    private func seekCard(score: Score) -> some View {
        let marks = score.rehearsalMarks()
        return VStack(spacing: 0) {
            if !marks.isEmpty {
                RehearsalMarkBar(marks: marks, currentFraction: displayFraction) { cursor in
                    viewModel.playbackSession.setManualCursor(cursor)
                }
                .padding(.bottom, -8)
            }
            seekBar
            transportRow
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: Self.maxCardWidth)
        .background {
            // The glass invades the bottom safe area (`.ignoresSafeArea`) but its own `.padding(.bottom, cardMargin)`
            // keeps the rounded rect `cardMargin` clear of the physical edge, nesting it concentrically inside the
            // device corners. The foreground content is unaffected by `.ignoresSafeArea`, so it stays above the
            // home indicator.
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cardCornerRadius))
                .padding(.bottom, Self.cardMargin)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .compositingGroup()
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .padding(.horizontal, Self.cardMargin)
    }

    /// Transport row. The prev / play / next triad is centered as one tight group, so play/pause sits at the card's
    /// horizontal center with step-back and step-forward an equal, short distance on either side. Jump-to-start is
    /// pinned to the leading edge and the A/B endpoint buttons (AB-loop only) to the trailing edge, layered behind the
    /// centered triad so they don't shift it.
    private var transportRow: some View {
        ZStack {
            HStack(spacing: Self.transportTriadSpacing) {
                stepBackwardButton
                playPauseButton(width: 56, height: 44, glyphSize: 34)
                stepForwardButton
            }

            HStack(spacing: 8) {
                jumpToStartButton
                Spacer()
                endpointButtons(flat: true)
            }
        }
    }

    /// Position shown on the seek bar (and used to pick the frontmost rehearsal mark): the in-progress scrub value
    /// while dragging, otherwise the live playback cursor's fraction. The live fraction comes from the session, which
    /// maps the engine's full-score cursor (`playbackFraction`) — NOT the filtered display cursor, whose re-stamped
    /// staff address would resolve `seconds(at:)` against the wrong staff under hidden staves.
    private var displayFraction: Double {
        if isScrubbing { return scrubFraction }
        return viewModel.playbackSession.playbackFraction
    }

    private var seekBar: some View {
        SeekBar(
            fraction: displayFraction,
            onScrubBegan: {
                isScrubbing = true
                viewModel.playbackSession.beginScrub()
            },
            onScrubChanged: { newFraction in
                scrubFraction = newFraction
                viewModel.playbackSession.updateScrub(toFraction: newFraction)
            },
            onScrubEnded: {
                isScrubbing = false
                viewModel.playbackSession.endScrub()
            },
        )
    }

    // MARK: Shared pieces

    @ViewBuilder private var resetZoomButton: some View {
        if viewModel.viewportZoom > 1.0 {
            Button {
                viewModel.resetZoom()
            } label: {
                Label {
                    Text("reader.toolbar.resetZoom", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// A / B repeat-endpoint pill, shown only in AB-loop mode. `flat` selects the expanded card's quiet material look
    /// over the collapsed layout's interactive glass + shadow.
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

    /// Primary transport buttons in document order: jump-to-start, step back a measure, play/pause, step forward a
    /// measure. Shared between the collapsed pill (rendered in sequence) and the expanded card (laid out around a
    /// centered play/pause), so the two layouts stay in sync.
    @ViewBuilder private var transportButtonsContent: some View {
        jumpToStartButton
        stepBackwardButton
        playPauseButton()
        stepForwardButton
    }

    /// Same glyph as page mode's "jump to first page" tap zone — a custom symbol bundled with the Reader module
    /// (`PageTapZoneKind.first`), since no system SF Symbol matches the `arrow.uturn.backward.to.line` shape.
    private var jumpToStartButton: some View {
        transportButton(
            image: Image("arrow.uturn.backward.to.line", bundle: .module),
            label: Text("reader.toolbar.jumpToStart", bundle: .module),
        ) {
            viewModel.playbackSession.seekToStart()
        }
    }

    private var stepBackwardButton: some View {
        transportButton(
            image: Image(systemName: "chevron.left.2"),
            label: Text("reader.toolbar.stepBackward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureBackward()
        }
    }

    /// Play/pause. `width` / `height` / `glyphSize` default to the standard transport size (used by the collapsed
    /// pill); the expanded card passes a larger glyph and width so play/pause reads as the primary control while
    /// keeping the row's 44pt height.
    private func playPauseButton(width: CGFloat = 44, height: CGFloat = 44, glyphSize: CGFloat = 20) -> some View {
        transportButton(
            image: Image(systemName: viewModel.playbackSession.isPlaying ? "pause.fill" : "play.fill"),
            label: Text(
                viewModel.playbackSession.isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play",
                bundle: .module,
            ),
            glyphSize: glyphSize,
            width: width,
            height: height,
        ) {
            Task { await viewModel.playbackSession.togglePlayback() }
        }
    }

    private var stepForwardButton: some View {
        transportButton(
            image: Image(systemName: "chevron.right.2"),
            label: Text("reader.toolbar.stepForward", bundle: .module),
        ) {
            viewModel.playbackSession.stepMeasureForward()
        }
    }

    private func transportButton(
        image: Image,
        label: Text,
        glyphSize: CGFloat = 20,
        width: CGFloat = 44,
        height: CGFloat = 44,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            image
                .font(.system(size: glyphSize, weight: .medium))
                .frame(width: width, height: height)
        }
        .tint(.primary)
        .accessibilityLabel(label)
    }
}

#if DEBUG
/// Three quarter-rests-per-measure score so AB-loop endpoints can snap to a chord (`snapMeasureEnd` needs at least one
/// `.chord` — rests count). Empty measures would let `setA` work but not `setB`.
@MainActor
private func transportPreviewViewModel() -> ReaderViewModel {
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
        systemMeasures: [marked("A"), SystemMeasure(), marked("B — Chorus, softer")],
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

#Preview("Transport control · collapsed") {
    let vm = transportPreviewViewModel()
    return VStack(spacing: 0) {
        Color.clear.border(.orange)
        ReaderTransportControl(viewModel: vm, showSeekBar: false)
    }
    .task { await configureTransportPreview(vm) }
}
#endif
