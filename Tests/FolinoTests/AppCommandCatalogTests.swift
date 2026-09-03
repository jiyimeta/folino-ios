@testable import Editor
@testable import folino
import Reader
import SwiftUI
import Testing

/// The iOS half of the table's invariants. Editing is a mode here, unlike the Mac (Ⅳa: no edit mode), so the
/// rows exist while reading and come alive with the session.
struct AppCommandCatalogTests {
    @Test func `the Mac only rows are absent on iOS`() {
        let ids = Set(AppCommandCatalog.current.map(\.id))
        #expect(!ids.contains("file.showLibrary"))
        #expect(!ids.contains("file.import"))
    }

    @Test func `display mode and search are present on iOS`() {
        let ids = Set(AppCommandCatalog.current.map(\.id))
        #expect(ids.contains("view.displayMode.page"))
        #expect(ids.contains("app.search"))
    }

    @Test @MainActor func `editing rows are disabled while not in an edit session`() {
        let host = ReaderEditingHost()
        let context = AppCommandContext(editor: PreviewEditorFactory.makeViewModel(), host: host)
        let tie = AppCommandCatalog.current.first { $0.id == "notes.tie" }
        #expect(tie?.isEnabled(context) == false, "editing rows must be inert while reading")
    }

    /// The regression the Task 6 review's probe surfaced: on iOS `context.editor` is non-nil whether or not an
    /// edit session is running (`EditableReaderScreen` always publishes an `EditorViewModel`), so a row that
    /// requires no editor at all must not be gated by `host.isEditing` — the session gate has to key off whether
    /// the ROW needs an editor (`AppCommand.init`'s `requiresEditor`), not off `context.editor`'s nil-ness.
    @Test @MainActor func `display mode and search stay enabled outside an edit session`() {
        let host = ReaderEditingHost()
        let context = AppCommandContext(editor: PreviewEditorFactory.makeViewModel(), host: host)
        let displayMode = AppCommandCatalog.current.first { $0.id == "view.displayMode.page" }
        let search = AppCommandCatalog.current.first { $0.id == "app.search" }
        #expect(displayMode?.isEnabled(context) == true, "a row that needs no editor must survive the session gate")
        #expect(search?.isEnabled(context) == true, "a row that needs no editor must survive the session gate")
    }

    /// The File ▸ Revert To rows need an editor but are NOT built through `editorRow` (their `perform` calls back
    /// into the context, not the editor — see the doc comment on `AppCommandCatalog.file`), so they are the one
    /// place `requiresEditor: true` had to be set by hand rather than inherited. Forcing `hasCapturedOriginal` true
    /// makes the row's OWN rule (`canRevertToOriginal`) pass, so a `false` here can only come from the session
    /// gate — proving it, and not the rule, is what disables the row while reading.
    @Test @MainActor func `the revert rows stay disabled outside an edit session even with something to revert`() {
        let editor = PreviewEditorFactory.makeViewModel()
        editor.hasCapturedOriginal = true
        let context = AppCommandContext(editor: editor, host: ReaderEditingHost())
        let revert = AppCommandCatalog.current.first { $0.id == "file.revert.original" }
        #expect(revert?.isEnabled(context) == false, "the revert rows bypass editorRow and must be gated by hand")
    }

    @Test func `every menu still has a row after the iOS platform filter`() {
        for menu in AppCommandMenu.allCases {
            #expect(!AppCommandCatalog.commands(in: menu).isEmpty, "\(menu)")
        }
    }
}
