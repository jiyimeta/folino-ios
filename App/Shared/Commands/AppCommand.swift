import Editor
import SwiftUI

/// Where a command lives in the menu bar (design §5.1). `.view` reuses the system's own View menu (`AppCommandMenus`
/// inserts into it with `CommandGroup(before: .toolbar)`) rather than minting a menu of its own.
enum AppCommandMenu: CaseIterable {
    case file, edit, notes, measures, score, view
}

/// The submenu a command sits in, or `nil` for a row that lives at the top of its menu.
///
/// Design §5.1 writes the Notes menu with `▸` groups — Accidental ▸, Duration ▸, Chord ▸, Tuplet ▸, Voice ▸ — and
/// this is what makes the generated menu match: without it the Notes menu is one flat list of fifty rows. `displayMode`
/// (View) and `revertTo` (File) are the same mechanism reused for a menu that mixes row kinds — the grouping is
/// presentation only; `AppCommandCatalog.all` and the key map are unaffected by it.
enum AppCommandSubmenu: String, CaseIterable {
    case pitch, duration, accidental, chord, tuplet, voice, displayMode, revertTo

    /// The submenu's own key in the App's `Localizable.xcstrings`. Interpolating `mac.menu.notes.\(rawValue)` only
    /// fits the Notes ▸ groups; `displayMode` sits in the View menu and `revertTo` in the File menu, so both need an
    /// explicit key instead.
    var titleKey: String {
        switch self {
        case .displayMode: "mac.menu.displayMode"
        case .revertTo: "mac.menu.revertTo"
        default: "mac.menu.notes.\(rawValue)"
        }
    }

    /// Built through `LocalizedStringKey(_:)` rather than by interpolating into a `LocalizedStringKey` literal —
    /// interpolation would mint the format key `mac.menu.notes.%@` and look up nothing.
    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }
}

/// The platform a command row is offered on. iPhone is `pad` too — it reaches the same rows through the search
/// sheet, and no row is iPhone-specific.
enum AppCommandPlatform: CaseIterable {
    case mac, pad

    /// The platform this build runs on.
    static var current: AppCommandPlatform {
        #if os(macOS)
        .mac
        #else
        .pad
        #endif
    }
}

/// One editing command, declared exactly once. `AppCommandMenus` turns the table into menu items and
/// `AppCommandKeyMap` (the bench chose view-level delivery) into key equivalents; Ⅳb turns the same rows into
/// search results. Titles are keys in the App's `Localizable.xcstrings`.
struct AppCommand: Identifiable {
    let id: String
    /// The row's title as a key in the App's `Localizable.xcstrings` — stored as the key itself, not as a
    /// `LocalizedStringKey`, so the table can be checked against the catalog (`AppCommandCatalogTests`) and so
    /// Ⅳb's search index can match on it.
    let titleKey: String
    var title: LocalizedStringKey {
        LocalizedStringKey(titleKey)
    }

    let menu: AppCommandMenu
    let submenu: AppCommandSubmenu?
    /// The key equivalent, if any. `isBareKey` says it carries no modifier — the case the bench (Task 1) decides the
    /// delivery of; modifier-bearing shortcuts always sit on the menu item.
    let key: KeyEquivalent?
    /// Extra BARE keys that fire the same command, delivered by `AppCommandKeyMap` only — a menu item shows one
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
    /// The platforms this row is offered on. Defaults to both — most rows are shared; a platform-specific row
    /// narrows this explicitly.
    let platforms: Set<AppCommandPlatform>
    let isEnabled: @MainActor @Sendable (AppCommandContext) -> Bool
    let perform: @MainActor @Sendable (AppCommandContext) -> Void

    init(
        _ id: String, _ titleKey: String, menu: AppCommandMenu, submenu: AppCommandSubmenu? = nil,
        key: KeyEquivalent? = nil, alternateKeys: [KeyEquivalent] = [], modifiers: EventModifiers = [],
        mutating: Bool = true,
        platforms: Set<AppCommandPlatform> = Set(AppCommandPlatform.allCases),
        isEnabled: @escaping @MainActor @Sendable (AppCommandContext) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (AppCommandContext) -> Void,
    ) {
        self.id = id
        self.titleKey = titleKey
        self.menu = menu
        self.submenu = submenu
        self.key = key
        self.alternateKeys = alternateKeys
        self.modifiers = modifiers
        isMutating = mutating
        self.platforms = platforms
        // A mutating command is disabled during playback before its own rule is consulted. Written as an `if`
        // rather than a ternary because a closure literal in a ternary is not inferred `@Sendable`, and the table
        // is a global constant, so every stored closure has to be.
        if mutating {
            self.isEnabled = { @Sendable @MainActor context in
                context.editor?.isPlaybackActive != true && isEnabled(context)
            }
        } else {
            self.isEnabled = isEnabled
        }
        self.perform = perform
    }
}
