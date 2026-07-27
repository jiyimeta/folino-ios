import Domain
import Foundation

/// Lets the Android persistence projection be ordered by the SAME `ScoreItemSort` comparators the iOS library uses,
/// rather than re-deriving "newest first" / "composer, nils last" in a second place (or, worse, in Kotlin).
///
/// The wire type marshals its instants as `Double` Unix times with `0` as the "absent" sentinel — it carries no
/// Optionals across JNI — so this is where those sentinels are mapped back to the Optional semantics the comparators
/// expect. `composer` is likewise `""` rather than nil when unknown.
extension ScoreRecordWire: ScoreSortFields {
    public var sortTitle: String {
        title
    }

    /// `""` is how the wire says "no composer"; the comparator wants nil so those rows sort last.
    public var sortComposer: String? {
        composer.isEmpty ? nil : composer
    }

    public var sortAddedAt: Date {
        Date(timeIntervalSince1970: addedAt)
    }

    /// `0` is the wire's "never opened" sentinel (see `ScoreRecordWire.lastOpenedAt`), which the comparator wants as
    /// nil so unopened scores sort last under `.lastOpenedDesc`.
    public var sortLastOpenedAt: Date? {
        lastOpenedAt > 0 ? Date(timeIntervalSince1970: lastOpenedAt) : nil
    }
}
