import Editor
import SwiftUI

/// Where a command lives in the menu bar (design §5.1). `.view` reuses the system's own View menu (`AppCommandMenus`
/// inserts into it with `CommandGroup(before: .toolbar)`) rather than minting a menu of its own.
enum AppCommandMenu: CaseIterable {
    case file, edit, notes, measures, score, view

    /// The menu's own key in the App's `Localizable.xcstrings`, or `nil` for a menu that carries no title of its
    /// own — `.file`, `.edit` and `.view` merge their rows into the system's own File/Edit/View menus
    /// (`AppCommandMenus`'s `CommandGroup(after: .newItem)` / `.undoRedo` / `CommandGroup(before: .toolbar)`), so
    /// there is no app-owned title to look up. The one place `.notes` / `.measures` / `.score` name themselves —
    /// `AppCommandMenus`'s own `CommandMenu`s read it through `commandMenuTitle` below, and
    /// `AppCommandSearch.menuPath(of:)` (Ⅳb Task 4) reads it directly — so a rename here cannot leave the menu bar
    /// and the search breadcrumb naming a menu two different ways (final review F5).
    var titleKey: String? {
        switch self {
        case .notes: "mac.menu.notes"
        case .measures: "mac.menu.measures"
        case .score: "mac.menu.score"
        case .file, .edit, .view: nil
        }
    }

    /// `titleKey` as a `LocalizedStringKey`, or `nil` where there is no title to show.
    var title: LocalizedStringKey? {
        titleKey.map { LocalizedStringKey($0) }
    }

    /// `title`, for the three menus that get a `CommandMenu` of their own — `.notes` / `.measures` / `.score`.
    /// `AppCommandMenus.body` reads this rather than a string literal of its own, so its `CommandMenu` titles and
    /// `AppCommandSearch.menuPath`'s breadcrumb (which reads `title` directly) can never name a menu two different
    /// ways (final review F5: they used to be two separate declarations, with nothing pinning them to agree).
    /// Traps rather than force-unwrapping (`force_unwrapping` is an opt-in SwiftLint rule this repo enables) on
    /// `.file` / `.edit` / `.view`, which is a caller error — those three fold into a system menu and were never
    /// meant to reach a `CommandMenu` label at all.
    var commandMenuTitle: LocalizedStringKey {
        guard let title else {
            preconditionFailure("\(self) has no title of its own — it merges into a system menu")
        }
        return title
    }
}

/// The submenu a command sits in, or `nil` for a row that lives at the top of its menu.
///
/// Design §5.1 writes the Notes menu with `▸` groups — Accidental ▸, Duration ▸, Chord ▸, Tuplet ▸, Voice ▸ — and
/// this is what makes the generated menu match: without it the Notes menu is one flat list of fifty rows. `displayMode`
/// (View) and `revertTo` (File) are the same mechanism reused for a menu that mixes row kinds — the grouping is
/// presentation only; `AppCommandCatalog.allIncludingOtherPlatforms` and the key map are unaffected by it.
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

    /// `title`, resolved to a `String`. `LocalizedStringKey` cannot be read back once built — its stored key is
    /// private to SwiftUI — so `AppCommandSearch` (Ⅳb Task 4) needs this to match a typed query against the row's
    /// displayed title rather than only its stable `id`.
    var localizedTitle: String {
        Bundle.main.localizedString(forKey: titleKey, value: titleKey, table: nil)
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
        // Whether this row's own rule reads `context.editor` at all. NOT the same test as "is `context.editor`
        // nil": on iOS `EditableReaderScreen` publishes a non-nil `EditorViewModel` whether or not an edit session
        // is running (Ⅳa: no edit mode on the Mac, a mode on iOS), so `context.editor == nil` never distinguishes
        // reading from editing there — it would gate nothing. `editorRow` (`AppCommandCatalog.swift`) sets this
        // `true` for every row it builds, since its whole point is wrapping a rule that needs an editor; the two
        // File ▸ Revert To rows set it by hand because their `perform` calls back into the CONTEXT
        // (`confirmDiscard` / `confirmRevert`), not the editor, so they cannot go through `editorRow` at all — see
        // the comment on `file` in `AppCommandCatalog.swift`. A row that never asks for an editor (Display Mode,
        // search) leaves this at its default and is unaffected by the session gate below.
        requiresEditor: Bool = false,
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
        // Two wrappers, applied outermost-first, so the cheapest refusal wins: a mutating row is dead while the
        // transport runs (§6.2), and on iOS a row that requires an editor is dead outside an edit session —
        // editing is a mode there, unlike the Mac (spec §3.2). A row that does not require one (Display Mode,
        // search) passes both guards.
        let rule = isEnabled
        let sessionGated: @MainActor @Sendable (AppCommandContext) -> Bool
        #if os(macOS)
        sessionGated = rule
        #else
        sessionGated = { context in
            guard !requiresEditor || context.host?.isEditing == true else { return false }
            return rule(context)
        }
        #endif
        if mutating {
            self.isEnabled = { context in
                guard context.editor?.isPlaybackActive != true else { return false }
                return sessionGated(context)
            }
        } else {
            self.isEnabled = sessionGated
        }
        self.perform = perform
    }
}
