import SwiftUI

/// The editing half of the menu bar, generated from `AppCommandCatalog`. Every command has a home here (umbrella
/// §2.3, "the menu bar is the complete index"); which ones are enabled is asked of the key window's editor through
/// the focused value.
struct AppCommandMenus: Commands {
    @FocusedValue(\.appCommandContext) private var target
    /// Scene-independent, so this reads even with no window key — exactly what `effectiveTarget`'s fallback needs.
    /// Cross-platform (`OpenWindowAction` exists on iOS too); only its use below is Mac-only.
    @Environment(\.openWindow) private var openWindow

    /// The context every row actually reads: the focused one if a screen published it, otherwise an app-level
    /// fallback (final review F2) so Show Library and the whole Display Mode submenu still answer with nothing
    /// focused — the Settings window key, or every window closed, both states the old `MacCommands` survived
    /// (`git show 9ab26f47:App/Mac/MacCommands.swift`). Never `nil`: every row's own `isEnabled` decides its state
    /// from here, instead of a blanket disable that would also take Import and every editing row down with it —
    /// which stay correctly disabled anyway, since their own rule reads `showLibrary`/`importScore`/`editor`/`host`,
    /// none of which this fallback fills.
    private var effectiveTarget: AppCommandContext {
        guard let target else {
            #if os(macOS)
            return .appLevelFallback(showLibrary: { openWindow(id: MacWindowID.library) })
            #else
            return .appLevelFallback(showLibrary: nil)
            #endif
        }
        return target
    }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu {
                items(in: .file, submenu: .revertTo)
            } label: {
                Text(AppCommandSubmenu.revertTo.title)
            }
        }
        CommandGroup(after: .newItem) {
            // Top-level `.file` rows only — Show Library and Import. The revert rows are in the submenu above.
            ForEach(AppCommandCatalog.topLevelCommands(in: .file)) { command in
                AppCommandMenuItem(command: command, target: effectiveTarget, hasFocusedTarget: target != nil)
            }
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            items(in: .edit)
        }
        // `commandMenuTitle` (`AppCommand.swift`), not a string literal here — final review F5: the search sheet's
        // breadcrumb (`AppCommandSearch.menuPath`) reads the very same `AppCommandMenu.title`, so the two cannot
        // name a menu two different ways.
        CommandMenu(Text(AppCommandMenu.notes.commandMenuTitle)) {
            items(in: .notes)
        }
        CommandMenu(Text(AppCommandMenu.measures.commandMenuTitle)) {
            items(in: .measures)
        }
        CommandMenu(Text(AppCommandMenu.score.commandMenuTitle)) {
            items(in: .score)
        }
        // Lands in the system's own View menu, not a menu of its own — matches where `MacCommands`'s Display Mode
        // picker used to sit.
        CommandGroup(before: .toolbar) {
            items(in: .view)
            Divider()
        }
    }

    /// One menu's rows: its top-level commands first, then a submenu per `▸` group design §5.1 names.
    @ViewBuilder
    private func items(in menu: AppCommandMenu) -> some View {
        ForEach(AppCommandCatalog.topLevelCommands(in: menu)) { command in
            AppCommandMenuItem(command: command, target: effectiveTarget, hasFocusedTarget: target != nil)
        }
        ForEach(AppCommandCatalog.submenus(in: menu), id: \.self) { submenu in
            Menu {
                items(in: menu, submenu: submenu)
            } label: {
                Text(submenu.title)
            }
        }
    }

    /// Just one submenu's rows — the File menu's Revert To needs this on its own, since the File menu's top level
    /// also holds a second kind of row (`shell`'s Show Library / Import) that `items(in:)` would otherwise mix in.
    private func items(in menu: AppCommandMenu, submenu: AppCommandSubmenu) -> some View {
        ForEach(AppCommandCatalog.commands(in: menu, submenu: submenu)) { command in
            AppCommandMenuItem(command: command, target: effectiveTarget, hasFocusedTarget: target != nil)
        }
    }
}

private struct AppCommandMenuItem: View {
    let command: AppCommand
    /// The real focused context, or `AppCommandMenus`'s app-level fallback — never `nil` (final review F2).
    let target: AppCommandContext
    /// Whether a screen actually published a focused context — kept apart from `target` (which is never nil now)
    /// because `AppCommandShortcut`'s provisional delivery-A branch means something narrower: a view-scoped editing
    /// target actually being focused, not merely "some context, possibly the app-level fallback, answers".
    let hasFocusedTarget: Bool

    var body: some View {
        let enabled = command.isEnabled(target)
        Button {
            // `isEnabled` is asked again here, not just for `.disabled` above — the same rule, and for the same
            // reason, as `AppCommandKeyMap`: a disabled control is a rendering fact and the guard is a correctness
            // one. `.disabled` holds only if this `Commands` body is re-evaluated when the `@Observable` editor's
            // `isPlaybackActive` flips, which is unverified for a menu bar, and §6.2 is not a claim to leave
            // resting on that.
            if command.isEnabled(target) {
                command.perform(target)
            }
        } label: {
            // Draws the checkmark in the View ▸ Display Mode submenu — the affordance `MacCommands`'s `Picker`
            // used to give the same three rows, now with one source of truth instead of two (design note in
            // `AppCommandCatalog+Shell.swift`).
            if AppCommandCatalog.isDisplayModeCurrent(command) {
                Label {
                    Text(command.title)
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text(command.title)
            }
        }
        .disabled(!enabled)
        .modifier(AppCommandShortcut(command: command, hasTarget: hasFocusedTarget))
    }
}

/// Where a command's key equivalent is attached — the bench's answer (see
/// `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md`).
///
/// **A:** every shortcut sits on the menu item; a BARE key only while a target is focused, so a text field that has
/// taken focus (the target reads `nil`) gets the letter. A additionally requires the view-scoped `focusedValue`
/// publication the bench file describes — today only `focusedSceneValue` exists (`MacEditableReaderScreen`), which
/// is not enough: it follows scene focus, not view focus, so a sheet's text field would not read `nil`.
/// **B:** modifier-bearing shortcuts sit on the menu item; bare keys are delivered by `AppCommandKeyMap` and the
/// item shows none.
private struct AppCommandShortcut: ViewModifier {
    let command: AppCommand
    let hasTarget: Bool

    func body(content: Content) -> some View {
        if let key = command.key, !command.isBareKey {
            content.keyboardShortcut(key, modifiers: command.modifiers)
        } else if let key = command.key, AppCommandKeyDelivery.current == .menuWhileFocused, hasTarget {
            content.keyboardShortcut(key, modifiers: [])
        } else {
            content
        }
    }
}

/// The bench decision, as a constant the two delivery sites read. Change ONLY with a re-run of Task 1's bench.
///
/// **B, provisional.** A view-level `.keyboardShortcut` is focus-aware — a focused `TextField` keeps the letter —
/// where an `NSMenuItem` key equivalent is not; that is the mechanism `MacTransportBar.playPauseButton` already
/// measured for Space. A is unmeasured. Flipping to A later means setting `.menuWhileFocused` here and adding the
/// view-scoped `focusedValue` publication the bench file describes.
enum AppCommandKeyDelivery {
    /// A: the bare key is the menu item's own equivalent, live only while an editing target is focused.
    case menuWhileFocused
    /// B: the bare key is delivered by `AppCommandKeyMap`, inside the score window's view tree.
    case viewLevel

    static let current: AppCommandKeyDelivery = .viewLevel
}
