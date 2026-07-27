import Domain
import SwiftUI
import UtilityUI

/// The contextual callout: a small Liquid Glass card that floats beside the selected note.
///
/// It carries the two things you reach for while going OVER a score rather than writing one: the pitch steps that
/// alter the selected note, and — behind a tap — the length the next note will be. Those two jobs are why it stays on
/// screen when the pad is hidden: with the keyboard down you can still walk the notes, nudge pitches, and set what
/// comes next, without a row of keys covering the staff.
///
/// The pitch steps are chevrons rather than ♯ / ♭ because what they do is step: one semitone per tap, an octave on a
/// hold, in whatever spelling the key signature calls for — an ♯ that sometimes produces a ♮ (stepping B♯ down) reads
/// as a broken accidental button, while an arrow just means "up".
///
/// Positioning — converting the global selection anchor into local space and clamping it on-screen — is
/// `EditorChromeView`'s job; this view only draws the card. It is only ever mounted while a NOTE is selected, so it
/// needs no empty state.
struct EditorCalloutView: View {
    let viewModel: EditorViewModel

    /// Whether the length tray is open. Local to the card: it's a disclosure, not a mode, and it should collapse the
    /// moment the card goes away with its selection.
    @State private var isDurationTrayOpen = false

    /// Height of the divider separating the length summary from the pitch steps.
    private static let dividerHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                durationSummaryKey
                Divider().frame(height: Self.dividerHeight)
                PitchStepButton(
                    systemImage: "chevron.up", label: "editor.pad.pitchUp",
                    semitones: 1, octaves: 1, viewModel: viewModel,
                )
                PitchStepButton(
                    systemImage: "chevron.down", label: "editor.pad.pitchDown",
                    semitones: -1, octaves: -1, viewModel: viewModel,
                )
                // Only when there IS a next note at the same pitch. A tie key that spends its life disabled teaches
                // nothing; one that appears exactly when a tie is possible says what a tie is.
                if viewModel.canTie {
                    tieKey
                }
            }

            if isDurationTrayOpen {
                HStack(spacing: 4) {
                    ForEach(PadDurationGlyph.ordered, id: \.glyph) { duration, glyph in
                        PadDurationKey(
                            duration: duration,
                            glyph: glyph,
                            isSelected: viewModel.selectedDuration?.base == duration,
                        ) {
                            viewModel.setSelectionDuration(duration)
                        }
                    }
                    PadDotKey(
                        dots: viewModel.selectedDuration?.dots ?? 0,
                        setDots: { viewModel.setSelectionDots($0) },
                        toggle: { viewModel.toggleSelectionDot() },
                    )
                }
            }
        }
        .padding(.horizontal, 8)
        // No vertical padding while collapsed: the keys are already 44 pt tall, so the card comes out exactly one key
        // high and the capsule below is a true pill rather than a rounded slab.
        .padding(.vertical, isDurationTrayOpen ? 4 : 0)
        // Same rule as the pad: nothing that mutates the score stays live while the transport runs.
        .disabled(viewModel.isPlaybackActive)
        .interactiveGlassCompat(in: cardShape)
        .shadow(color: .gray.opacity(0.3), radius: 10, y: 5)
        .animation(.snappy(duration: 0.22), value: isDurationTrayOpen)
    }

    /// A pill while collapsed; a rounded rectangle once the tray opens, since a capsule around two rows of keys bulges
    /// into semicircular ends wide enough to lose the corner keys behind them.
    private var cardShape: AnyShape {
        isDurationTrayOpen ? AnyShape(RoundedRectangle(cornerRadius: 24)) : AnyShape(Capsule())
    }

    /// The SELECTED note's length — not the armed one. The pad answers "what comes next"; the callout is pinned to a
    /// note, so it answers "what is this", and changing it here re-times that note.
    private var durationSummaryKey: some View {
        Button {
            isDurationTrayOpen.toggle()
        } label: {
            HStack(spacing: 2) {
                PadKeyGlyph.durationSummary(
                    viewModel.selectedDuration?.base, dots: viewModel.selectedDuration?.dots ?? 0,
                )
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isDurationTrayOpen ? 180 : 0))
            }
        }
        .buttonStyle(PadKeyStyle())
        .accessibilityLabel(Text("editor.callout.noteLength", bundle: .module))
    }

    /// Ties the selected note to its same-pitch neighbour, and unties it again. No `+` badge, unlike the pad's tie
    /// key: this one is a state, shown by the accent capsule when the tie is there, rather than an "add" action.
    private var tieKey: some View {
        Button {
            viewModel.toggleTie()
        } label: {
            PadKeyGlyph.tie(showsAddBadge: false)
        }
        .buttonStyle(PadKeyStyle(isArmed: viewModel.isSelectionTied))
        .accessibilityLabel(Text("editor.ops.tie", bundle: .module))
    }
}

/// A single pitch-step key. Tap and long-press must be mutually exclusive — a real long-press (hold past the
/// threshold, then lift) has to apply ONLY `shiftOctave`, never also `shiftPitch` on release.
///
/// `.simultaneousGesture` deliberately does not suppress the `Button`'s own tap recognizer, so without a guard a
/// long-press would fire both: `shiftOctave` when `LongPressGesture` reaches its threshold, and `shiftPitch` when the
/// finger lifts and the `Button` sees that as a completed tap — moving the note 13 semitones across two undo steps.
/// `didOctaveShift` closes that gap: `LongPressGesture.onEnded` fires at the hold threshold, strictly before the
/// tap fires on release, so by the time the `Button` action runs it can check the flag and swallow the spurious tap.
struct PitchStepButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let semitones: Int
    let octaves: Int
    let viewModel: EditorViewModel

    @State private var didOctaveShift = false

    var body: some View {
        Button {
            if didOctaveShift {
                didOctaveShift = false
            } else {
                viewModel.shiftPitch(bySemitones: semitones)
            }
        } label: {
            PadKeyGlyph.symbol(systemImage)
        }
        .buttonStyle(PadKeyStyle())
        .tint(.primary)
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            didOctaveShift = true
            viewModel.shiftOctave(by: octaves)
        })
        .accessibilityLabel(Text(label, bundle: .module))
    }
}
