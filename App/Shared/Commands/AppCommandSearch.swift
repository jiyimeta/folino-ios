import SwiftUI

/// Matching and ranking for the command sheet, kept out of the view so it can be tested without one.
enum AppCommandSearch {
    /// Rows whose localized title or stable id contains `query`, prefix matches first and table order within a
    /// tier. An empty query is the whole table — that is what makes the sheet a readable index of the app on a
    /// device with no menu bar (spec §6).
    static func results(matching query: String, in commands: [AppCommand]) -> [AppCommand] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return commands }
        var prefix: [AppCommand] = []
        var substring: [AppCommand] = []
        for command in commands {
            let haystacks = [normalized(command.localizedTitle), normalized(command.id)]
            if haystacks.contains(where: { $0.hasPrefix(needle) }) {
                prefix.append(command)
            } else if haystacks.contains(where: { $0.contains(needle) }) {
                substring.append(command)
            }
        }
        return prefix + substring
    }

    /// The command's place in the menu bar, as a breadcrumb for the search sheet row's subtitle (Ⅳb Task 5) — the
    /// row's menu name, if its menu has one (`AppCommandMenu.titleKey` is `nil` for `.file` / `.edit` / `.view`,
    /// which merge into the system's own menus rather than carrying an app-owned title), followed by the submenu
    /// name, if the row is in one. A row with neither — e.g. a top-level Edit or File row — has an empty path.
    static func menuPath(of command: AppCommand) -> [LocalizedStringKey] {
        [command.menu.title, command.submenu?.title].compactMap(\.self)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
