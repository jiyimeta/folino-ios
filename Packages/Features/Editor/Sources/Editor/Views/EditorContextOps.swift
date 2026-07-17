import Domain
import SwiftUI

/// The shared contextual-op buttons — accidentals (♭ ♮ ♯, long-press ♭/♯ → 𝄫/𝄪), chord add / remove, tie, and
/// tuplet — used by both `EditorCalloutView` (iPhone, horizontal capsule) and `EditorPaletteView` (iPad, 3-column
/// grid). `buttons(viewModel:)` returns a `@ViewBuilder` tuple so the caller can flow the buttons directly into its
/// own container: dropped into an `HStack` they lay out in a row; dropped into a `LazyVGrid` they distribute into
/// cells (both flatten a `TupleView`'s children). Each op maps to an `EditorViewModel` command that already no-ops
/// when the selection doesn't fit — the buttons stay simple.
enum EditorContextOps {
    @ViewBuilder
    static func buttons(viewModel: EditorViewModel) -> some View {
        AccidentalOpButton(
            glyph: "♭", tap: .flat, longPress: .doubleFlat,
            accessibility: "editor.ops.accidentalFlat", viewModel: viewModel,
        )
        AccidentalOpButton(
            glyph: "♮", tap: .natural, longPress: nil,
            accessibility: "editor.ops.accidentalNatural", viewModel: viewModel,
        )
        AccidentalOpButton(
            glyph: "♯", tap: .sharp, longPress: .doubleSharp,
            accessibility: "editor.ops.accidentalSharp", viewModel: viewModel,
        )
        ChordAddButton(viewModel: viewModel)
        ChordRemoveButton(viewModel: viewModel)
        TieButton(viewModel: viewModel)
        TupletButton(viewModel: viewModel)
    }

    // MARK: Glyph helpers

    /// Text glyph shared by the accidental and chord-op keys, sized to match the pad's letter keys. Scales down for
    /// the two-character chord labels ("＋音" / "−音") so they never clip the 40 pt key.
    static func textGlyph(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }

    /// SF Symbol glyph, matching the pad's 20 pt medium icon size.
    static func symbolGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .medium))
    }
}

/// ♭ ♮ ♯ accidental key. ♭ and ♯ additionally set the double variant (𝄫 / 𝄪) on a long-press; ♮ passes `longPress:
/// nil`. Tap and long-press are mutually exclusive, enforced the same way as the pad's octave keys
/// (`PitchStepButton`): `LongPressGesture.onEnded` fires at the hold threshold — strictly before the `Button`'s tap on
/// release — so the tap can see `didLongPress` and swallow the spurious single-tap.
private struct AccidentalOpButton: View {
    let glyph: String
    let tap: Accidental
    let longPress: Accidental?
    let accessibility: LocalizedStringKey
    let viewModel: EditorViewModel

    @State private var didLongPress = false

    var body: some View {
        let button = Button {
            if didLongPress {
                didLongPress = false
            } else {
                viewModel.setAccidental(tap)
            }
        } label: {
            EditorContextOps.textGlyph(glyph)
        }
        .buttonStyle(PadKeyStyle())
        .accessibilityLabel(Text(accessibility, bundle: .module))

        if let longPress {
            button.simultaneousGesture(LongPressGesture().onEnded { _ in
                didLongPress = true
                viewModel.setAccidental(longPress)
            })
        } else {
            button
        }
    }
}

/// ＋音: arms add-to-chord (`toggleAddToChord`). Shows the persistent accent capsule while armed, reusing the pad's
/// `PadKeyStyle(isArmed:)`.
private struct ChordAddButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Button {
            viewModel.toggleAddToChord()
        } label: {
            EditorContextOps.textGlyph("＋音")
        }
        .buttonStyle(PadKeyStyle(isArmed: viewModel.isAddToChordArmed))
        .accessibilityLabel(Text("editor.ops.addToChord", bundle: .module))
    }
}

/// −音: removes the selected notehead from its chord (`removeSelectedNoteFromChord`).
private struct ChordRemoveButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Button {
            viewModel.removeSelectedNoteFromChord()
        } label: {
            EditorContextOps.textGlyph("−音")
        }
        .buttonStyle(PadKeyStyle())
        .accessibilityLabel(Text("editor.ops.removeFromChord", bundle: .module))
    }
}

/// Tie key. Disabled unless the selected note has a same-pitch successor (`canTie`); toggles the tie otherwise.
private struct TieButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Button {
            viewModel.toggleTie()
        } label: {
            // FLAG (Task 17 visual review): this SF Symbol is the more tie-like of the two candidates in the brief
            // (an arced slur/tie curve) vs. `link` (a chain). Confirm it reads as a musical tie at 20 pt; fall back
            // to `link` if not.
            EditorContextOps.symbolGlyph("point.topleft.down.curvedto.point.bottomright.up")
        }
        .buttonStyle(PadKeyStyle())
        .disabled(!viewModel.canTie)
        .accessibilityLabel(Text("editor.ops.tie", bundle: .module))
    }
}

/// Tuplet key. A tap toggles a triplet on / off (`createTuplet(actualNotes: 3)` / `removeTuplet`, chosen by
/// `isSelectionInTuplet`); a long-press opens a `Menu` offering quintuplet / sextuplet / septuplet (5 / 6 / 7). The
/// key shows the armed capsule while the selection sits inside a tuplet.
private struct TupletButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Menu {
            ForEach([5, 6, 7], id: \.self) { count in
                Button {
                    viewModel.createTuplet(actualNotes: count)
                } label: {
                    Text(verbatim: "\(count)")
                }
            }
        } label: {
            EditorContextOps.textGlyph("3")
        } primaryAction: {
            if viewModel.isSelectionInTuplet {
                viewModel.removeTuplet()
            } else {
                viewModel.createTuplet(actualNotes: 3)
            }
        }
        .buttonStyle(PadKeyStyle(isArmed: viewModel.isSelectionInTuplet))
        .accessibilityLabel(Text("editor.ops.tuplet", bundle: .module))
    }
}
