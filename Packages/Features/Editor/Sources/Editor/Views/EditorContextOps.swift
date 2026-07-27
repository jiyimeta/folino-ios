import Domain
import SwiftUI

/// The contextual ops that live on the pad's third row (and, on iPad, in `EditorPaletteView`).
///
/// This used to carry accidentals (♭ ♮ ♯), chord add / remove, tie and tuplet for the floating callout. The callout
/// is gone and the set is now deliberately small: tuplets moved under the pad's `⋯` duration key, ♯ / ♭ are the pad's
/// own pitch-step keys, and the remaining ops (♮, ＋音, −音) are out of the UI for now — the commands still exist on
/// `EditorViewModel`, so re-surfacing them is a view-only change.
enum EditorContextOps {
    static func buttons(viewModel: EditorViewModel, isFlexible: Bool = false) -> some View {
        TieButton(viewModel: viewModel, isFlexible: isFlexible)
    }

    // MARK: Glyph helpers

    /// Text glyph shared by the ops keys, sized to match the pad's letter keys.
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

/// The pad's tie ＋ key: extends the selected note by writing the armed length after it and tying the two. Disabled
/// when there's nowhere to write (`canAppendTiedNote`). Removing a tie is the callout key's job, not this one's.
private struct TieButton: View {
    let viewModel: EditorViewModel
    var isFlexible = false

    var body: some View {
        Button {
            viewModel.appendTiedNote()
        } label: {
            // The SF Symbol stand-in (`point.topleft.down.curvedto.point.bottomright.up`) read as a generic curve
            // next to a row of real music glyphs; this is the music font's own tie stroke with a `+` for "add".
            PadKeyGlyph.tie()
        }
        .buttonStyle(PadKeyStyle(isFlexible: isFlexible))
        .disabled(!viewModel.canAppendTiedNote)
        .accessibilityLabel(Text("editor.ops.tie", bundle: .module))
    }
}
