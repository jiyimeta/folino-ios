#if os(macOS)
import SwiftUI

/// The Mac reader's transport: play/pause, a position readout and a seek slider, docked under the score.
///
/// **A sibling of `ReaderTransportControl`, not a port of it.** It binds to the same view-model members — the same
/// `togglePlayback()` facade, the same `playbackSession` scrub state machine, the same cached
/// `seekTimeline.durationSeconds` — but none of that screen's chrome comes across: the swipe-to-resize card, the
/// rubber band, the interpolated `TransportCardMetrics`, the floating glass and the coach-mark anchors are all touch
/// physics with nothing to do on a Mac. What is left is a bar.
///
/// Shown under exactly the iOS condition (`ReaderTransportControl.showsTransportCard`): a loaded score whose
/// capabilities allow playback, or a PDF whose background OMR parse has landed. Withheld while loading, so the bar
/// does not appear before there is anything it could drive.
struct MacTransportBar: View {
    let viewModel: ReaderViewModel

    var body: some View {
        if isTransportAvailable {
            HStack(spacing: 12) {
                playPauseButton
                // The live position is read inside `MacSeekRegion`'s body, never here — see its doc comment.
                MacSeekRegion(
                    playbackSession: viewModel.playbackSession,
                    durationSeconds: viewModel.seekTimeline.durationSeconds,
                    onScrubCommit: { viewModel.logSeekCommitted() },
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    /// The same gate `ReaderTransportControl.showsTransportCard` applies. Deliberately not `viewModel.canPlayNow`,
    /// which is the *rule for whether playback is possible* and answers true from the default capabilities before the
    /// score has finished loading — right for the engine, too early for a bar.
    private var isTransportAvailable: Bool {
        if viewModel.capabilities.canPlay, case .loaded = viewModel.loadState {
            return true
        }
        return viewModel.isPDFPlaybackReady
    }

    /// Play/pause, and the space bar's only vehicle.
    ///
    /// **`.keyboardShortcut` on this button rather than a `MacCommands` menu item, and that is a measured choice.**
    /// An `NSMenuItem` whose key equivalent is an unmodified Space steals the key outright: with an editable field's
    /// field editor as the key window's first responder, `NSMenu.performKeyEquivalent(with:)` still returns `true`
    /// and still fires the item — AppKit has no text-field exemption, so File ▸ … ▸ Play would swallow every space
    /// typed into the library's search field. SwiftUI's view-level shortcut is focus-aware instead: driven through
    /// the full `NSApplication.sendEvent` path, a space with a focused `TextField` inserted the space and left this
    /// action unfired, while the same event with nothing focused fired it. Focus-aware also means window-wide — the
    /// shortcut works with the sidebar focused, or with no focus at all, so it does not depend on the reader having
    /// been clicked first.
    ///
    /// The field that actually matters was measured too, in the shape it really has: `LibraryRootScreen`'s
    /// `.searchable(text:)` in a `NavigationSplitView` sidebar, with this shortcut in the detail column. macOS backs
    /// it with an `AppKitSearchField` whose field editor is a `SearchTextView`, and with that as first responder the
    /// space landed in the field (the bound `String` became `" "`) while this action stayed unfired. `.searchable`
    /// installs its field in the window's TOOLBAR rather than the content view, which is worth knowing before
    /// re-measuring: a probe that walks only `contentView` finds nothing and reads as a false pass.
    ///
    /// The shortcut lives on the button, so it exists exactly when the transport does: no score, no space bar.
    private var playPauseButton: some View {
        let isPlaying = viewModel.playbackSession.isPlaying
        let label = Text(isPlaying ? "reader.toolbar.pause" : "reader.toolbar.play", bundle: .module)
        return Button {
            Task { await viewModel.togglePlayback() }
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Elapsed / seek slider / remaining, split into its own view for one reason: **the live playback position is read
/// here and nowhere above.**
///
/// `playbackSession.playbackFraction` advances on every cursor tick, so whichever body reads it is rebuilt at the
/// engine's tick rate. Read in `MacTransportBar`, that would rebuild the whole bar; read in `MacReaderRootScreen`, it
/// would rebuild the reader. `MacTransportBar` only passes the session down as a reference — touching no property of
/// it — so nothing above this struct observes the position, and a tick repaints three labels' worth of view.
/// `MacScoreContentView` draws the same boundary for the cursors; this is the transport's half of it.
///
/// The scrub is one piece of state, not two: `scrubFraction` is non-`nil` exactly while a drag is in progress, so
/// each of the three handlers below performs a single state write. That keeps this view inside the one-write rule
/// `MacShellView.openImportedScore` documents, even though a slider's callbacks run from a gesture rather than from
/// inside a SwiftUI update pass.
private struct MacSeekRegion: View {
    let playbackSession: ReaderPlaybackSession
    /// The score's notated length, from the owner's cached `ReaderSeekTimeline` — a scalar, so this view depends on
    /// neither the `Score` nor the walk that derives it.
    let durationSeconds: Double
    /// Called once when a scrub commits, so this view can log the seek without importing analytics.
    let onScrubCommit: () -> Void

    /// In-progress scrub position; `nil` when not scrubbing, which is also what says the live position is in charge.
    @State private var scrubFraction: Double?

    var body: some View {
        let fraction = min(max(scrubFraction ?? playbackSession.playbackFraction, 0), 1)
        let elapsed = fraction * durationSeconds
        HStack(spacing: 8) {
            timeLabel(SeekRegion.formatTime(elapsed))
            Slider(value: binding(currentFraction: fraction), in: 0 ... 1) { editing in
                if editing {
                    scrubFraction = playbackSession.playbackFraction
                    playbackSession.beginScrub()
                } else {
                    scrubFraction = nil
                    playbackSession.endScrub()
                    onScrubCommit()
                }
            }
            .controlSize(.small)
            .accessibilityLabel(Text("reader.toolbar.seekBar", bundle: .module))
            timeLabel("-" + SeekRegion.formatTime(max(0, durationSeconds - elapsed)))
        }
    }

    /// Reads the position the body already resolved rather than resolving it again, so the thumb can never disagree
    /// with the labels beside it within one frame.
    private func binding(currentFraction: Double) -> Binding<Double> {
        Binding(
            get: { currentFraction },
            set: { newValue in
                scrubFraction = newValue
                playbackSession.updateScrub(toFraction: newValue)
            },
        )
    }

    private func timeLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}
#endif
