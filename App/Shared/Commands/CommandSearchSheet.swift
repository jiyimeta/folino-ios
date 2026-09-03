import SwiftUI

/// The layer that carries umbrella §2.3's guarantee to a device with no menu bar: one searchable list of every
/// command the platform has. A sheet, not a floating panel — an `NSPanel` would mean hand-building focus behavior
/// for nothing this slice needs.
struct CommandSearchSheet: View {
    let context: AppCommandContext
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var results: [AppCommand] {
        AppCommandSearch.results(matching: query, in: AppCommandCatalog.current)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("mac.commandSearch.placeholder", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .padding()
                .onSubmit { run(results.first) }
            Divider()
            List(results) { command in
                CommandSearchRow(command: command, isEnabled: command.isEnabled(context))
                    .contentShape(.rect)
                    .onTapGesture { run(command) }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { isFieldFocused = true }
    }

    private func run(_ command: AppCommand?) {
        guard let command, command.isEnabled(context) else { return }
        isPresented = false
        command.perform(context)
    }
}

/// One result row: the title, the row's place in the menu bar as a caption ("Notes ▸ Tuplet"), and its key
/// equivalent right-aligned. Spec §6: a disabled row is shown, greyed, and not selectable — greyed is this view's
/// job (every piece of text renders `.secondary`); not-selectable is `CommandSearchSheet.run`'s job, which re-checks
/// `isEnabled` before doing anything, so a stale tap on a row that went disabled between renders still cannot fire.
private struct CommandSearchRow: View {
    let command: AppCommand
    let isEnabled: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                if let menuPathText {
                    menuPathText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let keyEquivalentLabel {
                Text(verbatim: keyEquivalentLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Notes ▸ Tuplet" — built as one `Text` by concatenating each breadcrumb piece with `+`, so every piece keeps
    /// resolving through SwiftUI's own localization (`AppCommandSearch.menuPath(of:)` hands back `LocalizedStringKey`
    /// values, which have no public way to read the key back out for a plain-`String` interpolation).
    private var menuPathText: Text? {
        let path = AppCommandSearch.menuPath(of: command)
        guard let first = path.first else { return nil }
        return path.dropFirst().reduce(Text(first)) { partial, key in
            partial + Text(verbatim: " ▸ ") + Text(key)
        }
    }

    /// The row's key equivalent as a menu-style glyph string ("⌘⇧Z"), or `nil` for a row with none. Not a
    /// localization key — a symbol string built from `command.key` / `command.modifiers` — so it is displayed with
    /// `Text(verbatim:)` rather than looked up in the string catalog.
    private var keyEquivalentLabel: String? {
        guard let key = command.key else { return nil }
        return Self.symbol(for: command.modifiers) + Self.symbol(for: key)
    }

    private static func symbol(for modifiers: EventModifiers) -> String {
        var symbol = ""
        if modifiers.contains(.control) {
            symbol += "⌃"
        }
        if modifiers.contains(.option) {
            symbol += "⌥"
        }
        if modifiers.contains(.shift) {
            symbol += "⇧"
        }
        if modifiers.contains(.command) {
            symbol += "⌘"
        }
        return symbol
    }

    private static func symbol(for key: KeyEquivalent) -> String {
        switch key {
        case .escape: "⎋"
        case .delete: "⌫"
        case .deleteForward: "⌦"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .return: "⏎"
        case .tab: "⇥"
        case .space: "Space"
        default: String(key.character).uppercased()
        }
    }
}
