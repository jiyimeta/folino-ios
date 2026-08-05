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
/// A REST gets the same card, minus the two things a rest has no answer for: there is no pitch to step and nothing
/// to tie. What is left — the length summary and the tray behind it — is exactly what makes the card worth having on
/// a rest, since re-timing silence is otherwise only reachable by bringing the pad up. Its keys wear rest glyphs
/// rather than note ones: the card describes the item it is pinned to, so it has to look like that item.
///
/// Positioning — converting the global selection anchor into local space and clamping it on-screen — is
/// `EditorChromeView`'s job; this view only draws the card. It is only ever mounted while a note or a rest is
/// selected (`EditorViewModel.hasSelectionCallout`), so it needs no empty state.
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
                // Nothing after the summary on a rest, so no rule to draw either — a divider with one side empty
                // reads as a missing key rather than as a separator.
                if viewModel.isNoteSelected {
                    Divider().frame(height: Self.dividerHeight)
                    PitchStepButton(
                        systemImage: "chevron.up", label: "editor.pad.pitchUp",
                        semitones: 1, octaves: 1, viewModel: viewModel,
                    )
                    PitchStepButton(
                        systemImage: "chevron.down", label: "editor.pad.pitchDown",
                        semitones: -1, octaves: -1, viewModel: viewModel,
                    )
                    // Only when there IS a next note at the same pitch. A tie key that spends its life disabled
                    // teaches nothing; one that appears exactly when a tie is possible says what a tie is.
                    if viewModel.canTie {
                        tieKey
                    }
                }
            }

            if isDurationTrayOpen {
                durationTray
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

    /// The SELECTED item's length — not the armed one. The pad answers "what comes next"; the callout is pinned to
    /// one note or rest, so it answers "what is this", and changing it here re-times that item.
    private var durationSummaryKey: some View {
        Button {
            isDurationTrayOpen.toggle()
        } label: {
            HStack(spacing: 2) {
                summaryGlyph
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isDurationTrayOpen ? 180 : 0))
            }
        }
        .buttonStyle(PadKeyStyle())
        .accessibilityLabel(Text(
            viewModel.isNoteSelected ? "editor.callout.noteLength" : "editor.callout.restLength", bundle: .module,
        ))
    }

    @ViewBuilder
    private var summaryGlyph: some View {
        let length = viewModel.selectedDuration
        if viewModel.isNoteSelected {
            PadKeyGlyph.durationSummary(length?.base, dots: length?.dots ?? 0)
        } else {
            PadKeyGlyph.restSummary(length?.base, dots: length?.dots ?? 0)
        }
    }

    /// The length choices behind the summary key. Rest glyphs on a rest — the same durations in the same order, so
    /// the tray's shape never changes, only what its keys are pictures OF.
    private var durationTray: some View {
        let choices = viewModel.isNoteSelected ? PadDurationGlyph.ordered : PadDurationGlyph.rests
        return HStack(spacing: 4) {
            ForEach(choices, id: \.glyph) { duration, glyph in
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

#if DEBUG
/// One 4/4 bar carrying all three shapes the card has to draw: a note, a plain rest and a dotted rest.
/// Elements: [0] 4/4, [1] C4 quarter, [2] quarter rest, [3] dotted-quarter rest, [4] eighth rest.
@MainActor
private func previewCalloutViewModel(select item: SheetMusicCore.ScoreItemID) -> EditorViewModel {
    let voice = Voice(elements: [
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
        .rest(duration: .quarter),
        .rest(duration: NoteDuration.quarter.dotted(1)),
        .rest(duration: .eighth),
    ])
    let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: [Measure(voices: [voice])])])
    let viewModel = PreviewEditorFactory.makeViewModel()
    viewModel.beginSession(score: Score(division: 480, parts: [part]))
    viewModel.select(item)
    return viewModel
}

#Preview("callout · note vs rest") {
    let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    return VStack(spacing: 24) {
        EditorCalloutView(viewModel: previewCalloutViewModel(select: .note(
            NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0),
        )))
        EditorCalloutView(viewModel: previewCalloutViewModel(select: .rest(
            RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2),
        )))
        EditorCalloutView(viewModel: previewCalloutViewModel(select: .rest(
            RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 3),
        )))
    }
    .padding(40)
    .background(Color.gray.opacity(0.15))
}
#endif

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
