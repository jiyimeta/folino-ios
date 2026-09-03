import Editor
import SwiftUI

/// Where a command lives in the menu bar (design §5.1).
enum MacEditingMenu: CaseIterable {
    case file, edit, notes, measures, score
}

/// The submenu a command sits in, or `nil` for a row that lives at the top of its menu.
///
/// Design §5.1 writes the Notes menu with `▸` groups — Accidental ▸, Duration ▸, Chord ▸, Tuplet ▸, Voice ▸ — and
/// this is what makes the generated menu match: without it the Notes menu is one flat list of fifty rows. The
/// grouping is presentation only; `MacEditingCommands.all` and the key map are unaffected by it.
enum MacEditingSubmenu: String, CaseIterable {
    case pitch, duration, accidental, chord, tuplet, voice

    /// The submenu's own key in the App's `Localizable.xcstrings`.
    var titleKey: String {
        "mac.menu.notes.\(rawValue)"
    }

    /// Built through `LocalizedStringKey(_:)` rather than by interpolating into a `LocalizedStringKey` literal —
    /// interpolation would mint the format key `mac.menu.notes.%@` and look up nothing.
    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }
}

/// One editing command, declared exactly once. `MacEditingMenus` turns the table into menu items and
/// `MacEditingKeyMap` (the bench chose view-level delivery) into key equivalents; Ⅳb turns the same rows into
/// search results. Titles are keys in the App's `Localizable.xcstrings`.
struct MacEditingCommand: Identifiable {
    let id: String
    /// The row's title as a key in the App's `Localizable.xcstrings` — stored as the key itself, not as a
    /// `LocalizedStringKey`, so the table can be checked against the catalog (`MacEditingCommandsTests`) and so
    /// Ⅳb's search index can match on it.
    let titleKey: String
    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }

    let menu: MacEditingMenu
    let submenu: MacEditingSubmenu?
    /// The key equivalent, if any. `isBareKey` says it carries no modifier — the case the bench (Task 1) decides the
    /// delivery of; modifier-bearing shortcuts always sit on the menu item.
    let key: KeyEquivalent?
    /// Extra BARE keys that fire the same command, delivered by `MacEditingKeyMap` only — a menu item shows one
    /// key equivalent and that is `key`. Design §6's `⌫ / ⌦` row is the whole reason this exists: the two are one
    /// command, and a second table row for the alias would put a duplicate "Delete" in the Notes menu.
    let alternateKeys: [KeyEquivalent]
    let modifiers: EventModifiers
    var isBareKey: Bool {
        key != nil && modifiers.isEmpty
    }

    /// Every bare key that fires this command — the primary plus the aliases, empty for a modifier-bearing row.
    var bareKeys: [KeyEquivalent] {
        guard isBareKey, let key else { return [] }
        return [key] + alternateKeys
    }

    /// Whether the command changes the score. Every mutating command is inert while the transport runs (§6.2).
    let isMutating: Bool
    let isEnabled: @MainActor @Sendable (MacEditingTarget) -> Bool
    let perform: @MainActor @Sendable (MacEditingTarget) -> Void

    init(
        _ id: String, _ titleKey: String, menu: MacEditingMenu, submenu: MacEditingSubmenu? = nil,
        key: KeyEquivalent? = nil, alternateKeys: [KeyEquivalent] = [], modifiers: EventModifiers = [],
        mutating: Bool = true,
        isEnabled: @escaping @MainActor @Sendable (MacEditingTarget) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (MacEditingTarget) -> Void,
    ) {
        self.id = id
        self.titleKey = titleKey
        self.menu = menu
        self.submenu = submenu
        self.key = key
        self.alternateKeys = alternateKeys
        self.modifiers = modifiers
        isMutating = mutating
        // A mutating command is disabled during playback before its own rule is consulted. Written as an `if`
        // rather than a ternary because a closure literal in a ternary is not inferred `@Sendable`, and the table
        // is a global constant, so every stored closure has to be.
        if mutating {
            self.isEnabled = { @Sendable @MainActor target in
                !target.editor.isPlaybackActive && isEnabled(target)
            }
        } else {
            self.isEnabled = isEnabled
        }
        self.perform = perform
    }
}
