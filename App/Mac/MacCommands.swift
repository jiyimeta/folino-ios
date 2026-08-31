import AppKit
import Domain
import Library
import SwiftUI
import UniformTypeIdentifiers

/// The menu-bar skeleton. Sub-project Ⅳ fills in the editing commands and the full key map; this is only what the
/// shell itself needs, plus the two toggles a reader wants on day one.
struct MacCommands: Commands {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    /// The frontmost window's open score and import action, published by `MacShellView` via `focusedSceneValue`.
    /// `@FocusedValue` follows scene focus, so these always read the state of whichever window is key — the right
    /// notion of "current selection" for a File-menu command in a multi-window app. `LibraryRootScreen` exposes no
    /// per-row context-menu seam, which is what a per-row "Open in New Tab" would otherwise hang off of, so this
    /// reads the window's currently open score instead.
    @FocusedValue(\.macCurrentScoreID) private var currentScoreID
    @FocusedValue(\.macLibraryImportAction) private var libraryImportAction
    @Environment(\.openWindow) private var openWindow

    /// The reader's shared display-mode preference — the same key and the same raw values the iOS reader's visual
    /// inspector writes, so a score opened on the Mac and on the iPad agrees about what mode it is in.
    ///
    /// Only the two modes the Mac can draw are listed. `ReaderLayoutMode.horizontal` exists and iOS offers it, but the
    /// Mac has no horizontal container yet and a menu entry that renders nothing is worse than a missing one — see
    /// `MacReaderRootScreen.layoutMode`, which reads a stored `horizontal` as Page rather than clobbering it.
    @AppStorage(ReaderGlobalSettingsKey.layoutMode)
    private var layoutModeRaw: String = ReaderLayoutMode.page.rawValue

    var body: some Commands {
        // Import lands beside the system's own New/Open items rather than in a menu of its own.
        CommandGroup(after: .newItem) {
            Button {
                presentImportPanel()
            } label: {
                Text("mac.menu.import")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button {
                if let currentScoreID {
                    // A fresh `tabInstance` every time: `WindowGroup(for:)` reuses (refocuses) a window whose
                    // presented value already equals the one passed to `openWindow(value:)`, so a bare
                    // `ScoreItem.ID` here would just refocus the window this score is already showing in whenever
                    // that happens to be the frontmost one. See `MacWindowScore`'s doc comment.
                    openWindow(value: MacWindowScore(scoreID: currentScoreID))
                }
            } label: {
                Text("mac.menu.openInNewTab")
            }
            .disabled(currentScoreID == nil)
        }
        CommandGroup(before: .toolbar) {
            Picker(selection: $layoutModeRaw) {
                Text("mac.menu.displayMode.page")
                    .tag(ReaderLayoutMode.page.rawValue)
                Text("mac.menu.displayMode.vertical")
                    .tag(ReaderLayoutMode.vertical.rawValue)
            } label: {
                Text("mac.menu.displayMode")
            }
            Divider()
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
            } label: {
                Text("mac.menu.toggleLibrary")
            }
            .keyboardShortcut("0", modifiers: .command)
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
    private struct CurrentScoreIDKey: FocusedValueKey {
        typealias Value = ScoreItem.ID
    }

    private struct LibraryImportActionKey: FocusedValueKey {
        typealias Value = (URL) async -> Void
    }

    var macCurrentScoreID: ScoreItem.ID? {
        get { self[CurrentScoreIDKey.self] }
        set { self[CurrentScoreIDKey.self] = newValue }
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
