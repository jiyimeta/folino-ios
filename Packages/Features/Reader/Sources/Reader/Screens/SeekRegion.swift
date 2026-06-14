import SheetMusicCore
import SwiftUI

/// The fraction-driven portion of the expanded transport card: the rehearsal-mark bar, the seek bar, and the time
/// readout. Extracted from `ReaderTransportControl` so the live playback fraction is read *here* — a cursor tick during
/// playback re-evaluates only this subview, leaving the transport buttons (play/pause, step, jump, A/B) untouched.
struct SeekRegion: View {
    let playbackSession: ReaderPlaybackSession
    let marks: [ReaderRehearsalMark]
    /// `notatedDurationSeconds` of the score, passed in so this view depends on a scalar rather than the whole `Score`.
    let durationSeconds: Double

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            if !marks.isEmpty {
                RehearsalMarkBar(marks: marks, currentFraction: displayFraction) { cursor in
                    playbackSession.setManualCursor(cursor)
                }
                .padding(.bottom, -8)
            }
            seekBar
                // Time readout sits in the empty band below the thin track. An overlay reserves no layout space, so the
                // gap to the transport row and the buttons' tap targets stay exactly as they were.
                    .overlay(alignment: .bottom) { timeReadout }
        }
    }

    /// Position shown on the seek bar (and used to pick the frontmost rehearsal mark): the in-progress scrub value
    /// while dragging, otherwise the live playback cursor's fraction. The live fraction comes from the session, which
    /// maps the engine's full-score cursor (`playbackFraction`) — NOT the filtered display cursor, whose re-stamped
    /// staff address would resolve `seconds(at:)` against the wrong staff under hidden staves.
    private var displayFraction: Double {
        if isScrubbing { return scrubFraction }
        return playbackSession.playbackFraction
    }

    private var seekBar: some View {
        SeekBar(
            fraction: displayFraction,
            onScrubBegan: {
                isScrubbing = true
                playbackSession.beginScrub()
            },
            onScrubChanged: { newFraction in
                scrubFraction = newFraction
                playbackSession.updateScrub(toFraction: newFraction)
            },
            onScrubEnded: {
                isScrubbing = false
                playbackSession.endScrub()
            },
        )
    }

    /// Small current-position (leading) and remaining-time (trailing, with a leading minus) labels shown just below the
    /// seek track. Both follow `displayFraction`, so they track the scrub thumb while dragging and the live cursor
    /// otherwise. Non-interactive (`allowsHitTesting(false)`) so the seek drag underneath is unaffected.
    private var timeReadout: some View {
        let elapsed = min(max(displayFraction, 0), 1) * durationSeconds
        let remaining = max(0, durationSeconds - elapsed)
        return HStack {
            Text(verbatim: Self.formatTime(elapsed))
            Spacer(minLength: 0)
            Text(verbatim: "-" + Self.formatTime(remaining))
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        // Nudge into the empty band above the transport glyphs. `offset` shifts only the rendered text, so the row's
        // layout and the buttons' tap targets are still unaffected.
        .offset(y: 5)
        .allowsHitTesting(false)
    }

    /// Formats a non-negative second count as `mm:ss`, widening to `h:mm:ss` once it reaches an hour. Minutes are
    /// zero-padded only when an hours field precedes them, matching the usual transport readout.
    private static func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
