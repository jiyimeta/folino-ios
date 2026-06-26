import Foundation

/// `UserDefaults` keys for persisted analytics-derived state shared across features (read at launch to populate user
/// properties, written by the feature that observes the behaviour). Do not rename — raw strings are persisted state.
public enum AnalyticsStateKey {
    /// Bool. Flipped to `true` the first time the user commits Apple Pencil ink in the Reader. Drives the
    /// `has_used_annotation` user property. Defaults to `false`.
    public static let hasUsedAnnotation = "analytics.hasUsedAnnotation"
}
