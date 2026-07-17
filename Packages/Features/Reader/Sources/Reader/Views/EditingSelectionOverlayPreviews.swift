#if DEBUG
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SheetMusicUI
import SwiftUI

/// `EditorFixtures.fourQuarterRests()` shape, but with a C4 chord at element 1 (so the surface shows a real note
/// alongside the rests): [0] 4/4 time signature, [1] C4 quarter chord, [2...4] quarter rests.
private func editingOverlayPreviewScore() -> Score {
    let voice = Voice(elements: [
        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
        .rest(duration: .quarter),
    ])
    let measure = Measure(voices: [voice])
    let staff = Staff(measures: [measure])
    let part = Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])
    return Score(division: 480, parts: [part])
}

// Standalone preview for `EditingSelectionOverlay` that needs no Reader plumbing (no `ReaderViewModel`, no fakes) —
// it lays out the inline score directly and drives a bare `ReaderEditingHost`. Visual confirmation of the caret /
// rest tint / selection is deferred to the Task 17 manual device checklist; this block exists so the overlay keeps
// compiling as the surrounding editing feature evolves. The `return` disables the `#Preview` ViewBuilder transform,
// so the setup statements below run as an ordinary closure body.
#Preview("Editing overlay — caret on rest 2") {
    _ = SheetMusicLayoutApple.install
    let score = editingOverlayPreviewScore()
    let doc = LayoutEngine.layout(
        score: score,
        options: ScoreViewOptions(staffSize: 14, wrapToViewWidth: true),
        availableWidth: 700,
    )
    let restID = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
        measureIndex: 0, voiceIndex: 0, elementIndex: 2,
    )
    let host = ReaderEditingHost()
    host.isEditing = true
    host.selection = .single(.rest(restID))
    host.caretItem = .rest(restID)
    return ZStack(alignment: .topLeading) {
        ScoreView(
            document: doc, score: score,
            selection: host.selection,
            voiceColors: [0: .accentColor, 1: .accentColor, 2: .accentColor, 3: .accentColor],
        )
        EditingSelectionOverlay(host: host, score: score, document: doc)
    }
    .frame(width: 700)
    .padding()
}
#endif
