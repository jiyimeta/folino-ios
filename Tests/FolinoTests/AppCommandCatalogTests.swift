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

    @Test func `every menu still has a row after the iOS platform filter`() {
        for menu in AppCommandMenu.allCases {
            #expect(!AppCommandCatalog.commands(in: menu).isEmpty, "\(menu)")
        }
    }
}
