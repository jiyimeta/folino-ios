import Editor
import SwiftUI

/// Split out of `AppCommandCatalog.swift` so that file stays under SwiftLint's `file_length` budget — the same
/// convention `AppBootstrap+PDFConversion.swift` and `ReaderTopBarControls+Annotation.swift` already use elsewhere
/// in this repo. `measures` and `score` are not `private` for the same reason `editorRow` is not: `all`, in the
/// main file, needs to see them, and `private` is file-scoped rather than type-scoped.
extension AppCommandCatalog {
    // MARK: Measures

    /// "Add Measures…" raises `EditorAddMeasuresSheet`, which offers both placements — at the end and before the
    /// target bar — so design §5.1's "Insert measures before…" is that sheet and not a menu row of its own.
    ///
    /// Both rows want a session and nothing else — unlike the rest of the menu they need no caret, because appending
    /// at the end addresses no measure. A window with no session at all (a PDF-only row, or one whose load failed)
    /// still has an `EditorViewModel`, and `appendMeasure()` there is a no-op the menu should not offer.
    static let measures: [AppCommand] = [
        editorRow(
            "measures.append",
            "mac.menu.measures.append",
            menu: .measures,
            isEnabled: { $0.isSessionActive },
        ) { $0.appendMeasure() },
        editorRow(
            "measures.append.many",
            "mac.menu.measures.appendMany",
            menu: .measures,
            isEnabled: { $0.isSessionActive },
        ) { $0.isAddMeasuresSheetPresented = true },
        editorRow(
            "measures.insertBefore",
            "mac.menu.measures.insertBefore",
            menu: .measures,
            isEnabled: { $0.targetMeasureIndex != nil },
        ) { $0.insertMeasureBeforeTarget() },
        editorRow(
            "measures.delete",
            "mac.menu.measures.delete",
            menu: .measures,
            isEnabled: { $0.targetMeasureIndex != nil },
        ) { $0.deleteTargetMeasure() },
        editorRow(
            "measures.keySignature",
            "mac.menu.measures.keySignature",
            menu: .measures,
            isEnabled: { $0.targetMeasureIndex != nil && $0.targetConcertKey != nil },
        ) { $0.isKeySignatureSheetPresented = true },
        editorRow(
            "measures.timeSignature",
            "mac.menu.measures.timeSignature",
            menu: .measures,
            isEnabled: { $0.targetMeasureIndex != nil },
        ) { $0.isTimeSignatureSheetPresented = true },
        editorRow(
            "measures.rehearsalMark",
            "mac.menu.measures.rehearsalMark",
            menu: .measures,
            isEnabled: { $0.targetMeasureIndex != nil },
        ) { $0.isRehearsalMarkSheetPresented = true },
    ]

    // MARK: Score

    static let score: [AppCommand] = [
        editorRow(
            "score.instruments",
            "mac.menu.score.instruments",
            menu: .score,
            key: "i",
            isEnabled: { $0.isSessionActive },
        ) { $0.isInstrumentsSheetPresented = true },
        editorRow(
            "score.drumLayout",
            "mac.menu.score.drumLayout",
            menu: .score,
            isEnabled: { $0.isDrumStaffActive },
        ) { $0.isDrumLayoutSheetPresented = true },
    ]
}
