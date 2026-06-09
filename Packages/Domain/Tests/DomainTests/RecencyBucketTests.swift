@testable import Domain
import Foundation
import Testing

struct RecencyBucketTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1 // Sunday
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        // swiftlint:disable:next force_unwrapping
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    /// now = Wednesday 2026-06-10 12:00 UTC; that week (Sun-start) is 06-07 … 06-13.
    private var now: Date {
        at(2026, 6, 10)
    }

    @Test func `same instant is today`() {
        #expect(RecencyBucket.classify(now, now: now, calendar: calendar) == .today)
    }

    @Test func `earlier same day is today`() {
        #expect(RecencyBucket.classify(at(2026, 6, 10, 6), now: now, calendar: calendar) == .today)
    }

    @Test func `yesterday same week is this week`() {
        #expect(RecencyBucket.classify(at(2026, 6, 9), now: now, calendar: calendar) == .thisWeek)
    }

    @Test func `week start sunday is this week`() {
        #expect(RecencyBucket.classify(at(2026, 6, 7), now: now, calendar: calendar) == .thisWeek)
    }

    @Test func `previous saturday is earlier`() {
        #expect(RecencyBucket.classify(at(2026, 6, 6), now: now, calendar: calendar) == .earlier)
    }

    @Test func `eight days ago is earlier`() {
        #expect(RecencyBucket.classify(at(2026, 6, 2), now: now, calendar: calendar) == .earlier)
    }
}
