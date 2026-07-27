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

/// Tie key. Disabled unless the selected note has a same-pitch successor (`canTie`); toggles the tie otherwise.
private struct TieButton: View {
    let viewModel: EditorViewModel
    var isFlexible = false

    var body: some View {
        Button {
            viewModel.toggleTie()
        } label: {
            // FLAG (Task 17 visual review): this SF Symbol is the more tie-like of the two candidates in the brief
            // (an arced slur/tie curve) vs. `link` (a chain). Confirm it reads as a musical tie at 20 pt; fall back
            // to `link` if not.
            EditorContextOps.symbolGlyph("point.topleft.down.curvedto.point.bottomright.up")
        }
        .buttonStyle(PadKeyStyle(isFlexible: isFlexible))
        .disabled(!viewModel.canTie)
        .accessibilityLabel(Text("editor.ops.tie", bundle: .module))
    }
}
