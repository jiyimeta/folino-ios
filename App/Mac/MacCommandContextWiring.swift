// PARITY(macos): Finder document types — `.mscz` double-click and Open With do not reach folino; the open panel
//   below is the only import route. Needs `CFBundleDocumentTypes` in `App/Mac/Info.plist` plus an open handler in
//   the scene layer, which is why Ⅷ left it alone: that layer was being rewritten concurrently.

import AppKit
import Library
import UniformTypeIdentifiers

/// Where `MacShellView` and the library window wire `AppCommandContext.showLibrary` / `.importScore` — the two
/// rows `AppCommandCatalog` cannot answer on its own, since opening a native panel or a sibling window is not
/// something the shared, cross-platform table can do (was `MacCommands`).
enum MacCommandContextWiring {
    /// `LibraryRootScreen` owns its own `.fileImporter` (bound to the Library module's own, non-public
    /// `isFileImporterPresented`), so a File-menu command can't trigger that one from outside the module. This
    /// drives `NSOpenPanel` directly instead — the same mechanism `.fileImporter` uses under the hood on macOS —
    /// and hands each picked URL to the caller's own import action, exactly as `LibraryRootScreen`'s own importer
    /// does.
    ///
    /// `action` is a plain parameter, fixed at the call site — not read fresh from a focus-tracking value inside
    /// `panel.begin`'s completion handler: `@FocusedValue` tracks *scene* focus, and once `NSOpenPanel` becomes key
    /// window that tracking is no longer guaranteed to still resolve to the caller's scene. Taking the concrete
    /// action as a parameter removes that ambiguity outright instead of leaving File ▸ Import to silently import
    /// nothing.
    ///
    /// `@MainActor`: `MacCommands` got this for free by inferring `@MainActor` from its `Commands` conformance, so
    /// `panel.begin`'s completion closure inherited that isolation and the `Task { @MainActor in ... }` below was a
    /// same-actor hop. This plain `enum` has no such conformance to infer from, so the annotation is explicit here
    /// instead — every call site (`MacShellView`, `MacEditableReaderScreen`, `MacLibraryWindowContent`) is already
    /// on the main actor.
    @MainActor
    static func presentImportPanel(_ action: ((URL) async -> Void)?) {
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

/// Filters a drag-and-drop payload against Library's own `ScoreFileTypes.allowed` — the same list
/// `MacCommandContextWiring.presentImportPanel` uses above, and the same one `LibraryRootScreen`'s `.fileImporter`
/// uses on iOS. One shared list (lifted from Library, not copied) so a format Library ever adds is picked up here
/// automatically instead of silently going unaccepted.
enum ScoreImportContentTypes {
    static func isImportable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return ScoreFileTypes.allowed.contains { type.conforms(to: $0) }
    }
}
