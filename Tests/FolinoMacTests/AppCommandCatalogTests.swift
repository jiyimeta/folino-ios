// `@testable` for `PreviewEditorFactory`, which is internal to the Editor package: the repo rule is never to widen
// access for a test.
@testable import Editor
@testable import folino
import Foundation
import Reader
import SwiftUI
import Testing

/// The command table is the single declaration every editing surface reads (design §5). These are the invariants
/// that make it safe to generate menus and key equivalents from it: ids identify, bare keys do not collide, no row
/// is homeless, the MuseScore letters and digits are where §6's table puts them, and nothing that writes to the
/// score survives the transport running.
struct AppCommandCatalogTests {
    private func key(_ id: String) -> Character? {
        AppCommandCatalog.allIncludingOtherPlatforms.first { $0.id == id }?.key?.character
    }

    @Test func `every command id is unique`() {
        let ids = AppCommandCatalog.allIncludingOtherPlatforms.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `every bare key is bound at most once and never with modifiers`() {
        let bare = AppCommandCatalog.allIncludingOtherPlatforms.filter(\.isBareKey)
        // Hoisted out of `#expect`: `allSatisfy` is `rethrows`, and the macro's expansion of a rethrowing call
        // taking a key path does not typecheck.
        let everyBareKeyIsUnmodified = bare.allSatisfy(\.modifiers.isEmpty)
        #expect(everyBareKeyIsUnmodified)
        // `bareKeys`, not `key`: an alias (⌦ beside ⌫) is a bare key the key map delivers too, and it has to be
        // unique against every other one.
        let keys = AppCommandCatalog.allIncludingOtherPlatforms.flatMap(\.bareKeys).map(\.character)
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == keys.count)
        // A row with an alias but no primary key would silently bind nothing.
        let everyAliasHasAPrimary = AppCommandCatalog.allIncludingOtherPlatforms
            .allSatisfy { $0.alternateKeys.isEmpty || $0.isBareKey }
        #expect(everyAliasHasAPrimary)
    }

    /// A modifier-bearing shortcut is a menu item's key equivalent, so the pair (key, modifiers) has to be unique
    /// too — two items sharing one would leave AppKit to pick, silently.
    @Test func `every modified shortcut is bound at most once`() {
        let pairs = AppCommandCatalog.allIncludingOtherPlatforms.compactMap { command -> String? in
            guard let key = command.key, !command.isBareKey else { return nil }
            return "\(key.character)+\(command.modifiers.rawValue)"
        }
        #expect(!pairs.isEmpty)
        #expect(Set(pairs).count == pairs.count)
    }

    /// Design §6: MuseScore's `N` (note-input mode toggle) is deliberately unbound — folino's editing model is
    /// caret & pad, with no mode to toggle. A bound `N` would be bound to something a MuseScore hand does not expect.
    @Test func `no bare key is N`() {
        let keys = AppCommandCatalog.allIncludingOtherPlatforms.flatMap(\.bareKeys).map(\.character)
        #expect(!keys.contains("n"))
    }

    @Test func `every menu has at least one command and every command is in a menu`() {
        for menu in AppCommandMenu.allCases {
            #expect(!AppCommandCatalog.commands(in: menu).isEmpty, "\(menu)")
        }
        let placed = AppCommandMenu.allCases.flatMap { AppCommandCatalog.commands(in: $0) }.count
        #expect(placed == AppCommandCatalog.allIncludingOtherPlatforms.count)
    }

    @Test func `the MuseScore letters and digits are bound as the spec's table says`() {
        #expect(key("notes.pitch.a") == "a")
        #expect(key("notes.pitch.g") == "g")
        #expect(key("notes.duration.quarter") == "5")
        #expect(key("notes.duration.whole") == "7")
        #expect(key("notes.duration.64th") == "1")
        #expect(key("notes.rest") == "0")
        #expect(key("notes.dot") == ".")
        #expect(key("notes.tie") == "+")
        #expect(key("notes.tuplet.3") == "3")
        #expect(key("score.instruments") == "i")
    }

    @Test func `the tuplet and voice digits carry the modifiers the key map assigns them`() {
        func modifiers(_ id: String) -> EventModifiers? {
            AppCommandCatalog.allIncludingOtherPlatforms.first { $0.id == id }?.modifiers
        }
        #expect(modifiers("notes.tuplet.9") == .command)
        #expect(modifiers("notes.voice.1") == [.command, .option])
        #expect(modifiers("notes.chord.add.c") == .shift)
    }

    /// A title key with no catalog entry renders as the key itself — "mac.menu.notes.tuplet.7" in the menu bar,
    /// in every language. The table builds several of its keys by interpolation, so nothing but this check would
    /// notice one that was never added.
    @Test func `every title key resolves in the App's string catalog`() {
        let missing = "␀"
        let keys = AppCommandCatalog.allIncludingOtherPlatforms.map(\.titleKey)
            + AppCommandSubmenu.allCases.map(\.titleKey)
            + ["mac.menu.notes", "mac.menu.measures", "mac.menu.score", "mac.menu.revertTo"]
        for key in keys {
            let localized = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
            #expect(localized != missing, "\(key) has no catalog entry")
            #expect(localized != key, "\(key) resolves to its own key")
        }
    }

    @Test @MainActor func `every mutating command is disabled while playback runs`() {
        let editor = PreviewEditorFactory.makeViewModel()
        editor.isPlaybackActive = true
        let target = AppCommandContext(editor: editor, host: ReaderEditingHost())
        for command in AppCommandCatalog.allIncludingOtherPlatforms where command.isMutating {
            #expect(!command.isEnabled(target), "\(command.id)")
        }
    }

    /// The non-mutating rows are the ones that stay live during playback — selection and voice, per §6.2 — so at
    /// least one of them must actually be enabled with the transport running, or the guard above would be passing
    /// for the wrong reason (everything disabled).
    @Test @MainActor func `voice selection stays live while playback runs`() {
        let editor = PreviewEditorFactory.makeViewModel()
        editor.isPlaybackActive = true
        let target = AppCommandContext(editor: editor, host: ReaderEditingHost())
        let voice = AppCommandCatalog.allIncludingOtherPlatforms.first { $0.id == "notes.voice.1" }
        #expect(voice != nil)
        #expect(voice?.isMutating == false)
        #expect(voice.map { $0.isEnabled(target) } == true)
    }

    @Test func `the app level rows are in the table`() {
        let ids = Set(AppCommandCatalog.allIncludingOtherPlatforms.map(\.id))
        #expect(ids.contains("file.showLibrary"))
        #expect(ids.contains("file.import"))
        #expect(ids.contains("view.displayMode.page"))
    }

    /// Spec §3.2: a row is filtered out only where the concept does not exist. Show Library and Import are the
    /// only two, and Display Mode is deliberately NOT one of them — it writes the same preference key the iOS
    /// reader's visual inspector writes.
    @Test func `only the two library rows are Mac only`() {
        let macOnly = AppCommandCatalog.allIncludingOtherPlatforms.filter { $0.platforms == [.mac] }.map(\.id)
        #expect(Set(macOnly) == ["file.showLibrary", "file.import"])
    }

    @Test @MainActor func `the app level rows are disabled when the context cannot serve them`() {
        let context = AppCommandContext(editor: nil, host: nil)
        let showLibrary = AppCommandCatalog.allIncludingOtherPlatforms.first { $0.id == "file.showLibrary" }
        #expect(showLibrary?.isEnabled(context) == false)
        context.showLibrary = {}
        #expect(showLibrary?.isEnabled(context) == true)
    }

    /// A small fixture table for the two tests below — NOT `AppCommandCatalog.allIncludingOtherPlatforms`. Asserting
    /// the platform-filter mechanism against the real table doesn't work today: `file.showLibrary` / `file.import`
    /// (the only Mac-only rows) carry modifier-bearing shortcuts, so they never contribute a bare key either way,
    /// there is no iPad-only row at all, and `FolinoMacTests` only ever runs on macOS — so on this platform,
    /// `current`'s bare-key set is identical to `allIncludingOtherPlatforms`'s whether or not the filter runs at
    /// all. These two tests exercise `filtered(_:for:)` composed with `AppCommandKeyMap.keyBindings(in:)` against a
    /// fixture that actually has a bare key on each single platform, which real-table assertions cannot do — but
    /// note that composition is NOT the same invariant as "`AppCommandKeyMap.bindings` passes `.current`, not
    /// `allIncludingOtherPlatforms`, to that composition": mutation-testing `bindings` itself (swapping in
    /// `allIncludingOtherPlatforms`) still passes all 38 tests today, for the same reason. That call-site choice has
    /// no behavioral test until a platform-restricted BARE-key row exists; until then, the loud name on
    /// `allIncludingOtherPlatforms` is the actual defense — see its doc comment.
    private var fixtureCommands: [AppCommand] {
        [
            AppCommand(
                "fixture.mac", "fixture.mac", menu: .file, key: "m", mutating: false, platforms: [.mac],
            ) { _ in },
            AppCommand(
                "fixture.pad", "fixture.pad", menu: .file, key: "p", mutating: false, platforms: [.pad],
            ) { _ in },
            AppCommand("fixture.both", "fixture.both", menu: .file, key: "b", mutating: false) { _ in },
        ]
    }

    /// Pins the mechanism `AppCommandKeyMap.bindings` relies on: filtering to a platform, then computing bare keys,
    /// must never leak a bare key from a row the OTHER platform owns. Exercises the same two functions `bindings`
    /// composes (`AppCommandCatalog.filtered` then `AppCommandKeyMap.keyBindings(in:)`), not a re-derivation of
    /// either, so a regression in either one fails this test.
    @Test @MainActor func `the key map never delivers a key from a row this platform does not have`() {
        let padRows = AppCommandCatalog.filtered(fixtureCommands, for: .pad)
        let padKeys = Set(AppCommandKeyMap.keyBindings(in: padRows).map(\.key.character))
        #expect(!padKeys.contains("m"), "a Mac-only row's key leaked into the iPad's key map")
        #expect(padKeys.contains("p"))
        #expect(padKeys.contains("b"))
    }

    /// The reverse direction: filtering for Mac must not leak the iPad-only row's key either.
    @Test @MainActor func `the key map never delivers a key from a row the Mac does not have`() {
        let macRows = AppCommandCatalog.filtered(fixtureCommands, for: .mac)
        let macKeys = Set(AppCommandKeyMap.keyBindings(in: macRows).map(\.key.character))
        #expect(!macKeys.contains("p"), "an iPad-only row's key leaked into the Mac's key map")
        #expect(macKeys.contains("m"))
        #expect(macKeys.contains("b"))
    }
}
