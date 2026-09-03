import Domain
import Foundation
import Reader
import SwiftUI

/// Split out of `AppCommandCatalog.swift` so that file stays under SwiftLint's `file_length` budget — the same
/// convention `AppCommandCatalog+MeasuresAndScore.swift` already uses. `shell` and `view` are not `private` for the
/// same reason `editorRow` is not: `all`, in the main file, needs to see them, and `private` is file-scoped rather
/// than type-scoped.
///
/// Both arrays absorb what used to be `MacCommands`' hand-written rows — Show Library, Import, and the Display Mode
/// picker — so the whole Mac menu bar now comes from one table (Ⅳb §3).
extension AppCommandCatalog {
    // MARK: File — the shell's own rows

    /// Show Library and Import open a native panel or a sibling window rather than editing a score, so they read
    /// `AppCommandContext.showLibrary` / `.importScore` directly instead of routing through `editorRow`'s editor
    /// unwrap. Mac only — iOS has no library window and no reachable importer of its own (spec §3.2).
    static let shell: [AppCommand] = [
        .init(
            "file.showLibrary", "mac.menu.showLibrary", menu: .file,
            key: "o", modifiers: .command, mutating: false, platforms: [.mac],
            isEnabled: { $0.showLibrary != nil },
            perform: { $0.showLibrary?() },
        ),
        .init(
            "file.import", "mac.menu.import", menu: .file,
            key: "i", modifiers: [.command, .shift], mutating: false, platforms: [.mac],
            isEnabled: { $0.importScore != nil },
            perform: { $0.importScore?() },
        ),
    ]

    // MARK: View — Display Mode

    /// `@AppStorage` is a property wrapper for a `View`, not for a table of static rows, so the write here is a
    /// plain `UserDefaults` set — the same key `MacCommands` wrote, so the checkmark (`isDisplayModeCurrent` below)
    /// still names the mode actually on screen. Only the write lives here: reading needs SwiftUI observation, which
    /// only a `DynamicProperty` at the call site (`AppCommandMenus`'s `@AppStorage`) can give it — see
    /// `isDisplayModeCurrent`'s doc comment.
    ///
    /// Not filtered to Mac only: this writes the same key the iOS reader's visual inspector writes, so a score
    /// opened on the Mac and on the iPad agrees about what mode it is in — Ⅳb's search sheet is expected to surface
    /// these same three rows on iOS.
    private static func storeLayoutMode(_ mode: ReaderLayoutMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
    }

    private static func displayModeRow(_ mode: ReaderLayoutMode, _ titleKey: String) -> AppCommand {
        AppCommand(
            "view.displayMode.\(mode.rawValue)", titleKey, menu: .view, submenu: .displayMode, mutating: false,
            isEnabled: { _ in true },
            perform: { _ in storeLayoutMode(mode) },
        )
    }

    static let view: [AppCommand] = [
        displayModeRow(.page, "mac.menu.displayMode.page"),
        displayModeRow(.vertical, "mac.menu.displayMode.vertical"),
        displayModeRow(.horizontal, "mac.menu.displayMode.horizontal"),
        // `Z` is free in MuseScore's Mac map (umbrella §2.2) and is the Master Palette's successor. It is
        // non-mutating, so it stays live while the transport runs — and works with no score open, since
        // `presentSearch` is answered by whichever screen is on screen (`MacShellView`'s empty-window branch
        // included).
        .init(
            "app.search", "mac.menu.commandSearch", menu: .view, key: "z", mutating: false,
            isEnabled: { _ in true },
            perform: { $0.presentSearch() },
        ),
    ]

    /// Drives the checkmark in the View ▸ Display Mode submenu (`AppCommandMenus`).
    ///
    /// `storedRawValue` MUST come from an observed property at the call site — `@AppStorage` in a `Commands` struct,
    /// which is a `DynamicProperty` and so does invalidate that struct's `body` when the key changes — never from a
    /// fresh `UserDefaults` read taken here. A plain read is not observed by SwiftUI, so nothing would tell the menu
    /// to re-evaluate when the stored mode changes elsewhere (the Reader's own picker, or the other platform), and
    /// the checkmark would stay on whichever row was current when the menu was first built. This bug shipped once
    /// already for exactly that reason; there is deliberately no no-argument overload to fall back to.
    static func isDisplayModeCurrent(_ command: AppCommand, storedRawValue raw: String) -> Bool {
        #if os(macOS)
        let mode = ReaderLayoutMode.macDisplayMode(storedRawValue: raw)
        #else
        let mode = ReaderLayoutMode(rawValue: raw) ?? .page
        #endif
        return command.id == "view.displayMode.\(mode.rawValue)"
    }
}
