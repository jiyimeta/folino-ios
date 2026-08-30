import EditorCore
import Foundation

/// Where the drum pad's key layout is remembered between sessions.
///
/// The layout is GLOBAL, not per-score: the user asked for a fixed core they can learn, and a layout that
/// reshuffles itself per file defeats that. What IS per-score is the voice preset, which the core pre-selects from
/// what the open file's bars actually do.
///
/// **Deliberately not `@AppStorage`.** Reading a layout through `@AppStorage` into a SwiftUI layout routes the
/// change through `UserDefaults` and lands it outside `withAnimation`, which is what once turned a single pad
/// animation into a two-stage bounce. The sheet drives the pad from local state and calls `save` separately; this
/// type is only the door to disk.
enum DrumPadLayoutStore {
    static let defaultsKey = "editor.drumPadLayout"

    /// The stored layout, or the default kit when nothing has been stored — or when what was stored no longer
    /// decodes, which is what a layout written by a future version looks like. A pad that falls back to the default
    /// is recoverable in one tap; one that fails to appear is not.
    static func load(from defaults: UserDefaults = .standard) -> DrumPadLayout {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(DrumPadLayout.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ layout: DrumPadLayout, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
