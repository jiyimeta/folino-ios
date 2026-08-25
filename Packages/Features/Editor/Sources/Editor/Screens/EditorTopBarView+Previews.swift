import SheetMusicCore
import SwiftUI

// Previews for `EditorTopBarView`, split out to keep that file within the line budget — mirrors
// `EditorChromeView+Previews.swift`. The cutout tier itself (完了 / revert) is NOT shown here — it's the Reader's
// own `ReaderCutoutTier`, previewed alongside that type, not this one (review Important 4).

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

// With a cutout tier: ✕ and the session-end control live there instead, so the control tier is a fixed 5-item row
// (undo, redo, voice, pad, and the measure-actions menu) that never folds. Shown in both pad states — the toggle's
// active form is a filled disc, and whether that disc still reads as filled once the glass around it is composited
// is exactly the thing to look at.
#Preview("Cutout-tier device · pad off") {
    UserDefaults.standard.set(false, forKey: "editorPadVisible")
    return controlTier()
}

#Preview("Cutout-tier device · pad ON") {
    UserDefaults.standard.set(true, forKey: "editorPadVisible")
    return controlTier()
}

@MainActor
private func controlTier() -> some View {
    EditorTopBarView(
        viewModel: previewViewModel(canRevert: true),
        hasMusicalAnnotations: false,
        hasCutoutTier: true,
        onDone: {},
        onNoteInputAnchorFrameChange: { _ in },
    )
    .frame(width: 440, height: 52)
    .border(.red)
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}

// No cutout tier: 完了/revert AND the measure-actions menu join the control tier, and the whole row folds
// together into `⋯` below `narrow`'s width — in every `sessionEndMode` now, not only when revert is showing
// (see `EditorTopBarView.Collapse`). `canRevert: false` below covers the newly-reachable checkmark-mode fold.
#Preview("No cutout tier · widths") {
    let narrow = previewViewModel(canRevert: true)
    let wide = previewViewModel(canRevert: true)
    return VStack(spacing: 24) {
        EditorTopBarView(
            viewModel: narrow, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 320, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: wide, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 440, height: 52)
        .border(.red)
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}

// Checkmark mode (`canRevert: false`, no session edits → `.commitUnchanged`) reaches the fold for the first
// time now that `.expanded` carries `measureMenu` alongside `endGroup` — before this menu existed, `.expanded`
// and `.folded` measured identically in the checkmark states (both a bare 44×44 icon), so `ViewThatFits` could
// never actually select `.folded` there. `.expanded`'s ideal width is ≈392pt (✕ 44 + undo/redo 88 + voice ~68 +
// pad 44 + measureMenu 44 + endGroup 44 + 5×12 spacing), which no longer fits at 320 (iPad Slide Over) or 375
// (iPhone SE class) — both must fold — while 440 stays `.expanded`.
#Preview("No cutout tier · widths (checkmark mode)") {
    let slideOver = previewViewModel(canRevert: false)
    let se = previewViewModel(canRevert: false)
    let wide = previewViewModel(canRevert: false)
    return VStack(spacing: 24) {
        EditorTopBarView(
            viewModel: slideOver, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 320, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: se, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 375, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: wide, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {}, onNoteInputAnchorFrameChange: { _ in },
        )
        .frame(width: 440, height: 52)
        .border(.red)
    }
    .padding(.vertical, 40)
    .background(Color(white: 0.97))
}
#endif
