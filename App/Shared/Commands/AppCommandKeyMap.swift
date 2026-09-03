import SwiftUI

/// Bare-key delivery, shape B: one invisible `Button` per bare-key command, inside the score window's view tree.
/// SwiftUI's view-level `.keyboardShortcut` is focus-aware — a focused text field keeps the letter — where an
/// `NSMenuItem` key equivalent is not (measured in `MacTransportBar.playPauseButton`).
///
/// Each button is `.disabled` exactly when its command is, so a key the editor cannot use is not swallowed here
/// either; `perform` still re-checks, because a disabled control is a rendering fact and the guard is a
/// correctness one.
struct AppCommandKeyMap: View {
    let target: AppCommandContext

    /// One bare key, with the command it fires. A row can contribute more than one (design §6's `⌫ / ⌦`), and
    /// unwrapping the key here keeps a force-unwrap — or a fallback that would collide with the transport's Space —
    /// out of the body. Not `private`: `AppCommandCatalogTests` exercises `keyBindings(in:)` directly, so both it
    /// and `KeyBinding` need to be reachable from the test target.
    struct KeyBinding: Identifiable {
        let command: AppCommand
        let key: KeyEquivalent
        var id: String {
            "\(command.id)/\(key.character)"
        }
    }

    /// The bare-key computation, pulled out as a pure function of `commands` so a test can feed it a small fixture
    /// table instead of the real `AppCommandCatalog.current` — see that property's doc comment for why testing
    /// against the real table can't tell a correct filter from a deleted one. `bindings` below is the one and only
    /// call site that actually reads `.current`.
    static func keyBindings(in commands: [AppCommand]) -> [KeyBinding] {
        commands.flatMap { command in
            command.bareKeys.map { KeyBinding(command: command, key: $0) }
        }
    }

    /// `.current`, not `.allIncludingOtherPlatforms` — the menu (`AppCommandMenus`) and this key map have to read
    /// the same platform-filtered population, or a platform-restricted row would stay hidden from the menu while
    /// its bare key kept firing here. Not `private`, for the same reason `KeyBinding` above is not.
    var bindings: [KeyBinding] {
        Self.keyBindings(in: AppCommandCatalog.current)
    }

    var body: some View {
        if AppCommandKeyDelivery.current == .viewLevel {
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
