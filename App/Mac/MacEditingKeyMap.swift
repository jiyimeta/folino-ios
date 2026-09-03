import SwiftUI

/// Bare-key delivery, shape B: one invisible `Button` per bare-key command, inside the score window's view tree.
/// SwiftUI's view-level `.keyboardShortcut` is focus-aware — a focused text field keeps the letter — where an
/// `NSMenuItem` key equivalent is not (measured in `MacTransportBar.playPauseButton`).
///
/// Each button is `.disabled` exactly when its command is, so a key the editor cannot use is not swallowed here
/// either; `perform` still re-checks, because a disabled control is a rendering fact and the guard is a
/// correctness one.
struct MacEditingKeyMap: View {
    let target: MacEditingTarget

    /// One bare key, with the command it fires. A row can contribute more than one (design §6's `⌫ / ⌦`), and
    /// unwrapping the key here keeps a force-unwrap — or a fallback that would collide with the transport's Space —
    /// out of the body.
    private struct KeyBinding: Identifiable {
        let command: MacEditingCommand
        let key: KeyEquivalent
        var id: String {
            "\(command.id)/\(key.character)"
        }
    }

    private var bindings: [KeyBinding] {
        MacEditingCommands.all.flatMap { command in
            command.bareKeys.map { KeyBinding(command: command, key: $0) }
        }
    }

    var body: some View {
        if MacEditingKeyDelivery.current == .viewLevel {
            ForEach(bindings) { binding in
                Button("") {
                    if binding.command.isEnabled(target) {
                        binding.command.perform(target)
                    }
                }
                .keyboardShortcut(binding.key, modifiers: [])
                .disabled(!binding.command.isEnabled(target))
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}
