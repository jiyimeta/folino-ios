import Foundation

/// Layout modes the Reader exposes to the user. Stored globally via
/// `@AppStorage(ReaderLayoutMode.appStorageKey)` — the user's choice
/// persists across all scores.
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case page

    public static let appStorageKey = "reader.layoutMode"
    public static let appStorageDefault = ReaderLayoutMode.vertical.rawValue
}
