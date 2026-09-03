import AppKit
import Domain
import Library
import Reader
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar skeleton the shell itself needs — Show Library, Import, and the display-mode picker. The editing
/// menus live in `AppCommandMenus`.
///
/// `macLibraryImportAction` is published via `focusedSceneValue` by `MacShellView` and by the library browser's window
/// content both, since `@FocusedValue` follows *scene* focus and one window's publication is invisible from another.
struct MacCommands: Commands {
    @FocusedValue(\.macLibraryImportAction) private var libraryImportAction
    @Environment(\.openWindow) private var openWindow

    /// The reader's shared display-mode preference — the same key and the same raw values the iOS reader's visual
    /// inspector writes, so a score opened on the Mac and on the iPad agrees about what mode it is in.
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    /// The picker's selection, resolved through `macDisplayMode` on the way out and written back raw.
    ///
    /// All three modes the reader offers have a Mac container now, so all three get menu entries. The resolution on
    /// the way out is still what guarantees the checkmark names the mode actually on screen: it and
    /// `MacReaderRootScreen` read the stored value through the same function, so an unrecognized raw value can never
    /// leave the menu blank while the reader is drawing Page.
    private var displayMode: Binding<String> {
        Binding(
            get: { ReaderLayoutMode.macDisplayMode(storedRawValue: layoutModeRaw).rawValue },
            set: { layoutModeRaw = $0 },
        )
    }

    var body: some Commands {
        // Import lands beside the system's own New/Open items rather than in a menu of its own.
        CommandGroup(after: .newItem) {
            Button {
                openWindow(id: MacWindowID.library)
            } label: {
                Text("mac.menu.showLibrary")
            }
            .keyboardShortcut("o", modifiers: .command)
            Button {
                presentImportPanel()
            } label: {
                Text("mac.menu.import")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            // Both window kinds publish `macLibraryImportAction`, so this is `nil` only when neither is key (the
            // Settings window, say). Disabling rather than letting `presentImportPanel` open a panel whose picked
            // files `action?(url)` would silently drop.
            .disabled(libraryImportAction == nil)
        }
        CommandGroup(before: .toolbar) {
            Picker(selection: displayMode) {
                Text("mac.menu.displayMode.page")
                    .tag(ReaderLayoutMode.page.rawValue)
                Text("mac.menu.displayMode.vertical")
                    .tag(ReaderLayoutMode.vertical.rawValue)
                Text("mac.menu.displayMode.horizontal")
                    .tag(ReaderLayoutMode.horizontal.rawValue)
            } label: {
                Text("mac.menu.displayMode")
            }
            Divider()
        }
    }

    /// `LibraryRootScreen` owns its own `.fileImporter` (bound to the Library module's own, non-public
    /// `isFileImporterPresented`), so a File-menu command can't trigger that one from outside the module. This
    /// drives `NSOpenPanel` directly instead — the same mechanism `.fileImporter` uses under the hood on macOS —
    /// and hands each picked URL to the focused window's `LibraryViewModel.startImport(from:)`, exactly as
    /// `LibraryRootScreen`'s own importer does.
    private func presentImportPanel() {
        // Snapshotted before the panel opens, not read from `libraryImportAction` inside `panel.begin`'s completion
        // handler: `@FocusedValue` tracks *scene* focus, and once `NSOpenPanel` becomes key window that tracking is
        // no longer guaranteed to still resolve to this scene. Reading it now, while `MacShellView`'s window is
        // still key, removes that ambiguity outright instead of leaving File ▸ Import to silently import nothing.
        let action = libraryImportAction
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScoreFileTypes.allowed
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    await action?(url)
                }
            }
        }
    }
}

extension FocusedValues {
    private struct LibraryImportActionKey: FocusedValueKey {
        typealias Value = (URL) async -> Void
    }

    var macLibraryImportAction: ((URL) async -> Void)? {
        get { self[LibraryImportActionKey.self] }
        set { self[LibraryImportActionKey.self] = newValue }
    }
}

/// Filters a drag-and-drop payload against Library's own `ScoreFileTypes.allowed` — the same list `MacCommands`'s
/// import panel uses above, and the same one `LibraryRootScreen`'s `.fileImporter` uses on iOS. One shared list
/// (lifted from Library, not copied) so a format Library ever adds is picked up here automatically instead of
/// silently going unaccepted.
enum ScoreImportContentTypes {
    static func isImportable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return ScoreFileTypes.allowed.contains { type.conforms(to: $0) }
    }
}
