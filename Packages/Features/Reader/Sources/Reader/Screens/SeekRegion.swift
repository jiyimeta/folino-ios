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
    /// Score name shown below the seek bar (same text Library lists), scrolling when it overflows.
    let title: String

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
            // Elapsed / score title / remaining, pulled up into the seek bar's bottom band — mirrors VocalTuner's
            // transport card so the time labels flank the centered, scrolling title.
            timeRow
                .padding(.top, -6)
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

    /// Current-position (leading) and remaining-time (trailing, with a leading minus) labels flanking the centered,
    /// scrolling score title. The times follow `displayFraction`, tracking the scrub thumb while dragging and the live
    /// cursor otherwise. The whole row is non-interactive so the seek drag just above it is unaffected.
    private var timeRow: some View {
        let elapsed = min(max(displayFraction, 0), 1) * durationSeconds
        let remaining = max(0, durationSeconds - elapsed)
        return HStack(spacing: 16) {
            if durationSeconds > 0 {
                Text(verbatim: Self.formatTime(elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            RotationText(title: title, isCenterAligned: true)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)

            if durationSeconds > 0 {
                Text(verbatim: "-" + Self.formatTime(remaining))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
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
