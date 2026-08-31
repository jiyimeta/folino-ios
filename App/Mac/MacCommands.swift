import SwiftUI

/// The menu-bar skeleton. Sub-project Ⅳ fills in the editing commands and the full key map; this is only what the
/// shell itself needs, plus the two toggles a reader wants on day one.
struct MacCommands: Commands {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some Commands {
        // Import lands beside the system's own New/Open items rather than in a menu of its own.
        CommandGroup(after: .newItem) {
            Button {
                // Task 6 wires this to the importer.
            } label: {
                Text("mac.menu.import")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
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
}
