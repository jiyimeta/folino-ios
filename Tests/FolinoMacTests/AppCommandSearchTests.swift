@testable import folino
import SwiftUI
import Testing

struct AppCommandSearchTests {
    private let table = AppCommandCatalog.current

    @Test func `an empty query returns the whole table in table order`() {
        #expect(AppCommandSearch.results(matching: "", in: table).map(\.id) == table.map(\.id))
    }

    /// The id is the stable English name, so MuseScore's vocabulary keeps working in a Japanese UI without a
    /// second, hand-maintained alias list (spec §6).
    @Test func `a command is found by its English id when the title is localized`() {
        let ids = AppCommandSearch.results(matching: "triplet", in: table).map(\.id)
        #expect(ids.contains("notes.tuplet.3"))
    }

    @Test func `a prefix match outranks a substring match`() {
        let rows = [
            AppCommand("b.deleted", "mac.menu.notes", menu: .notes, perform: { _ in }),
            AppCommand("delete.row", "mac.menu.notes", menu: .notes, perform: { _ in }),
        ]
        #expect(AppCommandSearch.results(matching: "delete", in: rows).map(\.id) == ["delete.row", "b.deleted"])
    }

    @Test func `matching ignores case`() {
        #expect(!AppCommandSearch.results(matching: "TRIPLET", in: table).isEmpty)
    }

    @Test func `a query that matches nothing returns nothing`() {
        #expect(AppCommandSearch.results(matching: "zzzznothing", in: table).isEmpty)
    }

    /// `notes.tuplet.3` sits in the Notes menu's Tuplet ▸ group, so its breadcrumb is both names, in that order.
    @Test func `menuPath includes the submenu when the row has one`() {
        let tuplet = table.first { $0.id == "notes.tuplet.3" }
        #expect(tuplet != nil)
        #expect(tuplet.map(AppCommandSearch.menuPath) == [AppCommandMenu.notes.title, AppCommandSubmenu.tuplet.title]
            .compactMap(\.self))
    }

    /// `edit.deselect` is a top-level Edit row: `.edit` carries no title of its own (it merges into the system Edit
    /// menu) and the row has no submenu, so the breadcrumb is empty rather than a placeholder.
    @Test func `menuPath is empty for a row with no titled menu and no submenu`() {
        let deselect = table.first { $0.id == "edit.deselect" }
        #expect(deselect != nil)
        #expect(deselect.map(AppCommandSearch.menuPath) == [])
    }
}
