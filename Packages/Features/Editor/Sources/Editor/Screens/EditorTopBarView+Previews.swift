import SheetMusicCore
import SwiftUI

// Previews for `EditorTopBarView`, split out to keep that file within the line budget — mirrors
// `EditorChromeView+Previews.swift`.

#if DEBUG
@MainActor
private func previewViewModel(canRevert: Bool) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel(armedDuration: .quarter)
    if canRevert {
        viewModel.scoreItem = viewModel.scoreItem.capturingOriginal(
            fileName: "preview.original.mscx", contentHash: "preview-original", provenance: .importTime,
        )
        viewModel.hasCapturedOriginal = true
    }
    return viewModel
}

#Preview("Cutout tier · iPhone 17 Pro Max") {
    VStack(spacing: 0) {
        EditorTopBarView(
            viewModel: previewViewModel(canRevert: true),
            hasMusicalAnnotations: false,
            hasCutoutTier: true,
            topSafeAreaInset: 59,
            onDone: {},
            onNoteInputAnchorFrameChange: { _ in },
        )
        .padding(.top, 59)
        .frame(height: 52)
        Spacer()
    }
    .frame(width: 440, height: 956)
    .background(Color(white: 0.97))
}

// No cutout tier: 完了 and revert join the control tier, five controls wide.
#Preview("No cutout tier · widths") {
    let narrow = previewViewModel(canRevert: true)
    let wide = previewViewModel(canRevert: true)
    return VStack(spacing: 24) {
        EditorTopBarView(
            viewModel: narrow, hasMusicalAnnotations: false, hasCutoutTier: false, topSafeAreaInset: 0,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 320, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: wide, hasMusicalAnnotations: false, hasCutoutTier: false, topSafeAreaInset: 0,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 440, height: 52)
        .border(.red)
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}
#endif
