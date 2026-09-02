import SwiftUI

/// The editing half of the menu bar, generated from `MacEditingCommands`. Every command has a home here (umbrella
/// §2.3, "the menu bar is the complete index"); which ones are enabled is asked of the key window's editor through
/// the focused value.
struct MacEditingMenus: Commands {
    @FocusedValue(\.macEditingTarget) private var target

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu {
                items(in: .file)
            } label: {
                Text("mac.menu.revertTo")
            }
            .disabled(target == nil)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            items(in: .edit)
        }
        CommandMenu(Text("mac.menu.notes")) {
            items(in: .notes)
        }
        CommandMenu(Text("mac.menu.measures")) {
            items(in: .measures)
        }
        CommandMenu(Text("mac.menu.score")) {
            items(in: .score)
        }
    }

    /// One menu's rows: its top-level commands first, then a submenu per `▸` group design §5.1 names.
    @ViewBuilder
    private func items(in menu: MacEditingMenu) -> some View {
        ForEach(MacEditingCommands.topLevelCommands(in: menu)) { command in
            MacEditingMenuItem(command: command, target: target)
        }
        ForEach(MacEditingCommands.submenus(in: menu), id: \.self) { submenu in
            Menu {
                ForEach(MacEditingCommands.commands(in: menu, submenu: submenu)) { command in
                    MacEditingMenuItem(command: command, target: target)
                }
            } label: {
                Text(submenu.title)
            }
            .disabled(target == nil)
        }
    }
}

private struct MacEditingMenuItem: View {
    let command: MacEditingCommand
    let target: MacEditingTarget?

    var body: some View {
        let enabled = target.map(command.isEnabled) ?? false
        Button {
            // `isEnabled` is asked again here, not just for `.disabled` above — the same rule, and for the same
            // reason, as `MacEditingKeyMap`: a disabled control is a rendering fact and the guard is a correctness
            // one. `.disabled` holds only if this `Commands` body is re-evaluated when the `@Observable` editor's
            // `isPlaybackActive` flips, which is unverified for a menu bar, and §6.2 is not a claim to leave
            // resting on that.
            if let target, command.isEnabled(target) {
                command.perform(target)
            }
        } label: {
            Text(command.title)
        }
        .disabled(!enabled)
        .modifier(MacEditingShortcut(command: command, hasTarget: target != nil))
    }
}

/// Where a command's key equivalent is attached — the bench's answer (see
/// `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md`).
///
/// **A:** every shortcut sits on the menu item; a BARE key only while a target is focused, so a text field that has
/// taken focus (the target reads `nil`) gets the letter. A additionally requires the view-scoped `focusedValue`
/// publication the bench file describes — today only `focusedSceneValue` exists (`MacEditableReaderScreen`), which
/// is not enough: it follows scene focus, not view focus, so a sheet's text field would not read `nil`.
/// **B:** modifier-bearing shortcuts sit on the menu item; bare keys are delivered by `MacEditingKeyMap` and the
/// item shows none.
private struct MacEditingShortcut: ViewModifier {
    let command: MacEditingCommand
    let hasTarget: Bool

    func body(content: Content) -> some View {
        if let key = command.key, !command.isBareKey {
            content.keyboardShortcut(key, modifiers: command.modifiers)
        } else if let key = command.key, MacEditingKeyDelivery.current == .menuWhileFocused, hasTarget {
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
enum MacEditingKeyDelivery {
    /// A: the bare key is the menu item's own equivalent, live only while an editing target is focused.
    case menuWhileFocused
    /// B: the bare key is delivered by `MacEditingKeyMap`, inside the score window's view tree.
    case viewLevel

    static let current: MacEditingKeyDelivery = .viewLevel
}
