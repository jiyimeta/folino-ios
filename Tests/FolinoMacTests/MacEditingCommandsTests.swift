import Editor
@testable import folino
import Foundation
import Reader
import SwiftUI
import Testing

/// The command table is the single declaration every editing surface reads (design §5). These are the invariants
/// that make it safe to generate menus and key equivalents from it: ids identify, bare keys do not collide, no row
/// is homeless, the MuseScore letters and digits are where §6's table puts them, and nothing that writes to the
/// score survives the transport running.
struct MacEditingCommandsTests {
    private func key(_ id: String) -> Character? {
        MacEditingCommands.all.first { $0.id == id }?.key?.character
    }

    @Test func `every command id is unique`() {
        let ids = MacEditingCommands.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `every bare key is bound at most once and never with modifiers`() {
        let bare = MacEditingCommands.all.filter(\.isBareKey)
        // Hoisted out of `#expect`: `allSatisfy` is `rethrows`, and the macro's expansion of a rethrowing call
        // taking a key path does not typecheck.
        let everyBareKeyIsUnmodified = bare.allSatisfy(\.modifiers.isEmpty)
        #expect(everyBareKeyIsUnmodified)
        // `bareKeys`, not `key`: an alias (⌦ beside ⌫) is a bare key the key map delivers too, and it has to be
        // unique against every other one.
        let keys = MacEditingCommands.all.flatMap(\.bareKeys).map(\.character)
        #expect(!keys.isEmpty)
        #expect(Set(keys).count == keys.count)
        // A row with an alias but no primary key would silently bind nothing.
        let everyAliasHasAPrimary = MacEditingCommands.all.allSatisfy { $0.alternateKeys.isEmpty || $0.isBareKey }
        #expect(everyAliasHasAPrimary)
    }

    /// A modifier-bearing shortcut is a menu item's key equivalent, so the pair (key, modifiers) has to be unique
    /// too — two items sharing one would leave AppKit to pick, silently.
    @Test func `every modified shortcut is bound at most once`() {
        let pairs = MacEditingCommands.all.compactMap { command -> String? in
            guard let key = command.key, !command.isBareKey else { return nil }
            return "\(key.character)+\(command.modifiers.rawValue)"
        }
        #expect(!pairs.isEmpty)
        #expect(Set(pairs).count == pairs.count)
    }

    /// Design §6: MuseScore's `N` (note-input mode toggle) is deliberately unbound — folino's editing model is
    /// caret & pad, with no mode to toggle. A bound `N` would be bound to something a MuseScore hand does not expect.
    @Test func `no bare key is N`() {
        let keys = MacEditingCommands.all.flatMap(\.bareKeys).map(\.character)
        #expect(!keys.contains("n"))
    }

    @Test func `every menu has at least one command and every command is in a menu`() {
        for menu in MacEditingMenu.allCases {
            #expect(!MacEditingCommands.commands(in: menu).isEmpty, "\(menu)")
        }
        let placed = MacEditingMenu.allCases.flatMap { MacEditingCommands.commands(in: $0) }.count
        #expect(placed == MacEditingCommands.all.count)
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
            MacEditingCommands.all.first { $0.id == id }?.modifiers
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
        let keys = MacEditingCommands.all.map(\.titleKey)
            + MacEditingSubmenu.allCases.map(\.titleKey)
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
        let target = MacEditingTarget(editor: editor, host: ReaderEditingHost())
        for command in MacEditingCommands.all where command.isMutating {
            #expect(!command.isEnabled(target), "\(command.id)")
        }
    }

    /// The non-mutating rows are the ones that stay live during playback — selection and voice, per §6.2 — so at
    /// least one of them must actually be enabled with the transport running, or the guard above would be passing
    /// for the wrong reason (everything disabled).
    @Test @MainActor func `voice selection stays live while playback runs`() {
        let editor = PreviewEditorFactory.makeViewModel()
        editor.isPlaybackActive = true
        let target = MacEditingTarget(editor: editor, host: ReaderEditingHost())
        let voice = MacEditingCommands.all.first { $0.id == "notes.voice.1" }
        #expect(voice != nil)
        #expect(voice?.isMutating == false)
        #expect(voice.map { $0.isEnabled(target) } == true)
    }
}
