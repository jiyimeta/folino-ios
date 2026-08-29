import SheetMusicCore
import SwiftUI

// Previews for `EditorTopBarView`, split out to keep that file within the line budget — mirrors
// `EditorChromeView+Previews.swift`. The cutout tier itself (完了 / revert) is NOT shown here — it's the Reader's
// own `ReaderCutoutTier`, previewed alongside that type, not this one.

#if DEBUG
@MainActor
private func previewViewModel(canRevert: Bool) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel(armedDuration: .quarter)
    if canRevert {
        // The same door a real caller uses to re-seed the row (`refreshRow` also updates `hasCapturedOriginal`),
        // rather than a preview-only setter on state the core owns.
        viewModel.refreshRow(viewModel.scoreItem.capturingOriginal(
            fileName: "preview.original.mscx", contentHash: "preview-original", provenance: .importTime,
        ))
    }
    return viewModel
}

// With a cutout tier: ✕ and the session-end control live there instead, so the control tier is a fixed 3-item row
// that never folds.
#Preview("Cutout-tier device") {
    EditorTopBarView(
        viewModel: previewViewModel(canRevert: true),
        hasMusicalAnnotations: false,
        hasCutoutTier: true,
        onDone: {},
    )
    .frame(width: 440, height: 52)
    .border(.red)
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}

// No cutout tier: 完了 and revert join the control tier and fold together into `⋯` below `narrow`'s width (see
// `EditorTopBarView.Collapse`).
#Preview("No cutout tier · widths") {
    let narrow = previewViewModel(canRevert: true)
    let wide = previewViewModel(canRevert: true)
    return VStack(spacing: 24) {
        EditorTopBarView(
            viewModel: narrow, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {},
        )
        .frame(width: 320, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: wide, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {},
        )
        .frame(width: 440, height: 52)
        .border(.red)
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}
#endif
