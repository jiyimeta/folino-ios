import Domain
import Foundation
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

    /// `@AppStorage` is a property wrapper for a `View`, not for a table of static rows, so the read and write here
    /// are plain `UserDefaults` — the same key `MacCommands` wrote, so the checkmark still names the mode actually
    /// on screen.
    ///
    /// Not filtered to Mac only: this writes the same key the iOS reader's visual inspector writes, so a score
    /// opened on the Mac and on the iPad agrees about what mode it is in — Ⅳb's search sheet is expected to surface
    /// these same three rows on iOS. `ReaderLayoutMode.macDisplayMode` — the Mac reader's own resolution function,
    /// which `MacReaderRootScreen` also reads — is Mac-only in the `Reader` package, so this file (shared with iOS)
    /// calls it only under `#if os(macOS)`; the fallback below is the exact same resolution, spelled out, for the
    /// platforms where that convenience does not exist.
    private static var storedLayoutMode: ReaderLayoutMode {
        get {
            let raw = UserDefaults.standard.string(forKey: ReaderGlobalSettingsKey.layoutMode)
                ?? ReaderLayoutMode.page.rawValue
            #if os(macOS)
            return ReaderLayoutMode.macDisplayMode(storedRawValue: raw)
            #else
            return ReaderLayoutMode(rawValue: raw) ?? .page
            #endif
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode) }
    }

    private static func displayModeRow(_ mode: ReaderLayoutMode, _ titleKey: String) -> AppCommand {
        AppCommand(
            "view.displayMode.\(mode.rawValue)", titleKey, menu: .view, submenu: .displayMode, mutating: false,
            isEnabled: { _ in true },
            perform: { _ in storedLayoutMode = mode },
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
    static func isDisplayModeCurrent(_ command: AppCommand) -> Bool {
        command.id == "view.displayMode.\(storedLayoutMode.rawValue)"
    }
}
