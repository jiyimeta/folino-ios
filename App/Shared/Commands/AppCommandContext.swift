import Editor
import Reader
import SwiftUI

/// What the menus act on: the editor behind the key score window, and the two confirmations the File menu's
/// Revert To items arm. Published as a `focusedSceneValue` by every score window so `AppCommandMenus` reads the
/// right editor when several score windows are open — and reads `nil` when none is key.
///
/// A class, and one instance per screen: the focused value has to be the SAME object on every body pass, or each
/// pass republishes a new value and the menus rebuild for nothing. `MacEditableReaderScreen` holds it in `@State`
/// and fills the two closures in `wireOnce()`.
@MainActor
final class AppCommandContext {
    /// `nil` when no score is on screen — the library window on the Mac, the library screen on iOS.
    let editor: EditorViewModel?
    let host: ReaderEditingHost?
    /// File ▸ Revert To ▸ Last Opened; the screen owns the confirmation this arms.
    var confirmDiscard: () -> Void = {}
    /// File ▸ Revert To ▸ Original.
    var confirmRevert: () -> Void = {}
    /// Filled by the Mac's shell only — iOS has no library window and no reachable importer (spec §3.2).
    var showLibrary: (() -> Void)?
    var importScore: (() -> Void)?
    /// Raises the command search sheet. Filled by whichever screen owns the sheet's presentation state.
    var presentSearch: () -> Void = {}

    init(editor: EditorViewModel?, host: ReaderEditingHost?) {
        self.editor = editor
        self.host = host
    }
}

private struct AppCommandContextKey: FocusedValueKey {
    typealias Value = AppCommandContext
}

extension FocusedValues {
    var appCommandContext: AppCommandContext? {
        get { self[AppCommandContextKey.self] }
        set { self[AppCommandContextKey.self] = newValue }
    }
}
