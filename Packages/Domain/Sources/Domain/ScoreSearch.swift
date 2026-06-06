import Foundation

/// Shared score-list search predicate. Both the iOS `ScoreListViewModel` and the
/// Android `LibraryAndroidStore` bridge use this so the matching rules stay
/// identical across platforms (iOS/Android parity: share logic, never reimplement).
///
/// Mirrors the iOS `.searchable` behavior: the query is trimmed; an empty query
/// matches everything; otherwise the query must appear as a case- and
/// diacritic-insensitive substring of the title or the composer.
public enum ScoreSearch {
    public static func matches(title: String, composer: String?, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        if let composer, composer.range(of: trimmed, options: opts, locale: .current) != nil { return true }
        return false
    }
}
