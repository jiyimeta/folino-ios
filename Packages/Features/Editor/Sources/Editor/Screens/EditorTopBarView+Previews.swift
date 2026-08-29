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

// With a cutout tier: ✕ and the session-end control live there instead, so the control tier is a fixed 5-item row
// (undo, redo, voice, the instruments sheet, and the measure-actions menu) that never folds.
#Preview("Cutout-tier device") {
    controlTier()
}

// The narrow end of the cutout-tier range, which is NOT the modern 393pt class: `hasCutoutTier` keys off the top
// safe-area inset, and the 375pt notched phones (12/13 mini, 11 Pro, XS) clear it. Five 44pt controls plus four 12pt
// gaps is 268pt against ≈343pt of usable row — the tightest layout that has no fold to fall back on, so this is the
// one to look at whenever a control is added to that branch.
#Preview("Cutout-tier device · 375pt") {
    controlTier(width: 375)
}

@MainActor
private func controlTier(width: CGFloat = 440) -> some View {
    EditorTopBarView(
        viewModel: previewViewModel(canRevert: true),
        hasMusicalAnnotations: false,
        hasCutoutTier: true,
        onDone: {},
    )
    .frame(width: width, height: 52)
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

// Checkmark mode (`canRevert: false`, no session edits → `.commitUnchanged`) reaches the fold for the first
// time now that `.expanded` carries `measureMenu` alongside `endGroup` — before this menu existed, `.expanded`
// and `.folded` measured identically in the checkmark states (both a bare 44×44 icon), so `ViewThatFits` could
// never actually select `.folded` there. `.expanded`'s ideal width is ≈392pt (✕ 44 + undo/redo 88 + voice ~68 +
// instruments 44 + measureMenu 44 + endGroup 44 + 5×12 spacing), which no longer fits at 320 (iPad Slide Over) or
// 375 (iPhone SE class) — both must fold — while 440 stays `.expanded`.
#Preview("No cutout tier · widths (checkmark mode)") {
    let slideOver = previewViewModel(canRevert: false)
    let se = previewViewModel(canRevert: false)
    let wide = previewViewModel(canRevert: false)
    return VStack(spacing: 24) {
        EditorTopBarView(
            viewModel: slideOver, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {},
        )
        .frame(width: 320, height: 52)
        .border(.red)
        EditorTopBarView(
            viewModel: se, hasMusicalAnnotations: false, hasCutoutTier: false,
            onDone: {},
        )
        .frame(width: 375, height: 52)
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
