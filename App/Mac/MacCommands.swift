import AppKit
import Domain
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
                    openWindow(value: currentScoreID)
                }
            } label: {
                Text("mac.menu.openInNewTab")
            }
            .disabled(currentScoreID == nil)
        }
        CommandGroup(before: .toolbar) {
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScoreImportContentTypes.allowed
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls {
                    await libraryImportAction?(url)
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

/// The same score-file UTTypes `App/Info.plist`'s `CFBundleDocumentTypes` / `UTImportedTypeDeclarations` register
/// for iOS, computed the same way Library's own (module-internal, so not reachable from here) `ScoreFileTypes`
/// does — kept in one place so `MacCommands`'s import panel and `MacShellView`'s sidebar drop target agree on what
/// counts as a score file.
enum ScoreImportContentTypes {
    static let allowed: [UTType] = {
        let specific = ["mscx", "mscz", "musicxml", "mxl"]
            .compactMap { UTType(filenameExtension: $0) }
        return specific + [.xml, .zip, .midi, .pdf]
    }()

    static func isImportable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowed.contains { type.conforms(to: $0) }
    }
}
