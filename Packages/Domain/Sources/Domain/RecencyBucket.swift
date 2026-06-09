import Foundation

/// Recency partition for "recently opened" surfaces. Shared so iOS and Android classify identically.
public enum RecencyBucket: Sendable, Equatable {
    case today
    case thisWeek
    case earlier
}

extension RecencyBucket {
    /// Classify `date` relative to `now` using `calendar`. `today` = same calendar day; `thisWeek` = same
    /// `.weekOfYear` (respects `calendar.firstWeekday`) but a different day; `earlier` = neither. Callers pass the
    /// device's current date and `Calendar.current`; both are injected for testability.
    public static func classify(_ date: Date, now: Date, calendar: Calendar) -> RecencyBucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        return .earlier
    }
}
