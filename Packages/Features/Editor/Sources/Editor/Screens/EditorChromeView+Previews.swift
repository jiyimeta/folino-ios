import Domain
import SheetMusicCore
import SwiftUI

// Previews for `EditorChromeView`, split out to keep that file within the line budget.

#if DEBUG
/// Preview-only: seed a session + selection on a `PreviewEditorFactory` VM so the callout / palette / readout render
/// populated. Reuses the Task 13 factory (`EditorPadButtons.swift`) for the Infrastructure-free fakes.
@MainActor
private func previewChromeViewModel(select item: SheetMusicCore.ScoreItemID) -> EditorViewModel {
    let viewModel = PreviewEditorFactory.makeViewModel(armedDuration: .quarter)
    viewModel.beginSession(score: previewChromeScore())
    viewModel.select(item)
    return viewModel
}

/// One 4/4 measure: element 1 is a C4 quarter chord, elements 2…4 are quarter rests.
private func previewChromeScore() -> Score {
    let voice = Voice(elements: [
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
    ])
    let staff = Staff(measures: [Measure(voices: [voice])])
    let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
    return Score(division: 480, parts: [part])
}

private let previewStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

/// The fixed controls (voice, pad toggle, undo / redo / 完了, revert) live in `EditorTopBarView` now, drawn into the
/// Reader's own top strip rather than a navigation bar this view fills — so unlike the old `ToolbarContent` version,
/// this preview needs no navigation container to render in.
@MainActor
private func previewChromeHost(viewModel: EditorViewModel) -> some View {
    EditorChromeView(viewModel: viewModel, bottomTransportClearance: 44)
        .background(Color.gray.opacity(0.15))
}

#Preview("chrome · compact / rest selected") {
    let restItem = SheetMusicCore.ScoreItemID.rest(
        RestID(staff: previewStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 2),
    )
    return previewChromeHost(viewModel: previewChromeViewModel(select: restItem))
        .frame(width: 390, height: 844)
        .environment(\.horizontalSizeClass, .compact)
}

#Preview("chrome · regular / note selected") {
    let noteItem = SheetMusicCore.ScoreItemID.note(
        NoteID(staff: previewStaff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0),
    )
    return previewChromeHost(viewModel: previewChromeViewModel(select: noteItem))
        .frame(width: 1180, height: 820)
        .environment(\.horizontalSizeClass, .regular)
}
#endif
