@testable import folino
import SwiftUI
import Testing

struct AppCommandSearchTests {
    private let table = AppCommandCatalog.current

    @Test func `an empty query returns the whole table in table order`() {
        #expect(AppCommandSearch.results(matching: "", in: table).map(\.id) == table.map(\.id))
    }

    /// The id carries the stable English MuseScore term ("tuplet"), so that vocabulary keeps working under any
    /// title, in any language, without a second, hand-maintained alias list (spec §6 — corrected 2026-09-03: the
    /// spec's earlier example, "triplet", was never actually in the id `notes.tuplet.3`; only its English *title*
    /// is "Triplet"). The resolver passed here is a deterministic dummy that never mentions "tuplet", so this test
    /// isolates the id path — it fails if `results` ever stops matching against `id`, regardless of what the host
    /// machine's resolved language does to `localizedTitle`.
    @Test func `a command is found by its stable id even when the title resolver never mentions it`() {
        let ids = AppCommandSearch.results(matching: "tuplet", in: table, title: { _ in "3連符" }).map(\.id)
        #expect(ids.contains("notes.tuplet.3"))
    }

    /// The mirror of the test above: a deterministic resolver isolates the title path. The row's id shares nothing
    /// with the query, so this fails if `results` ever stops matching against the resolved title.
    @Test func `a command is found by its title even when the id shares nothing with the query`() {
        let rows = [AppCommand("row.without.match", "mac.menu.notes", menu: .notes, perform: { _ in })]
        let ids = AppCommandSearch.results(matching: "banana", in: rows, title: { _ in "Banana Bread" }).map(\.id)
        #expect(ids.contains("row.without.match"))
    }

    @Test func `a prefix match outranks a substring match`() {
        let rows = [
            AppCommand("b.deleted", "mac.menu.notes", menu: .notes, perform: { _ in }),
            AppCommand("delete.row", "mac.menu.notes", menu: .notes, perform: { _ in }),
        ]
        #expect(AppCommandSearch.results(matching: "delete", in: rows).map(\.id) == ["delete.row", "b.deleted"])
    }

    /// "TUPLET" against the id `notes.tuplet.3`, not the title — so this stays locale-independent without needing
    /// a dummy resolver of its own.
    @Test func `matching ignores case`() {
        #expect(!AppCommandSearch.results(matching: "TUPLET", in: table).isEmpty)
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

    /// The third combination: `notes.rest` is a top-level Notes row — `.notes` has its own title, but the row sits
    /// in no submenu — so the breadcrumb is just the menu name.
    @Test func `menuPath is just the menu name for a top-level row in a titled menu`() {
        let rest = table.first { $0.id == "notes.rest" }
        #expect(rest != nil)
        #expect(rest.map(AppCommandSearch.menuPath) == [AppCommandMenu.notes.title].compactMap(\.self))
    }
}
