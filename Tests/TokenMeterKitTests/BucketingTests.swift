import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Bucketing")
struct BucketingTests {
    /// Los Angeles is useful for these tests: negative UTC offset, and it
    /// observes DST so transition days are not a uniform 24 hours.
    static func calendar(_ identifier: String = "America/Los_Angeles", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Daily window aligns to local midnight and shows one bucket per day")
    func dailyAlignment() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        #expect(bucketing.displayBuckets.count == 14)

        let last = try #require(bucketing.displayBuckets.last)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: last.start)
        #expect(components.day == 10)
        #expect(components.hour == 0)

        let current = try #require(bucketing.currentBucket)
        #expect(bucketing.bucketIndex(for: now) == 13)
        #expect(current.contains(now))

        // The in-progress bucket ends at the next local midnight, not 24h later
        // (this window includes the spring-forward day).
        let expectedEnd = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11)))
        #expect(current.end == expectedEnd)
    }

    @Test("Buckets remain contiguous across a DST transition")
    func dstContiguity() {
        let calendar = Self.calendar()
        // Spring forward in the US was 2026-03-08.
        let now = Self.date(calendar, 2026, 3, 10, 9)
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        for (previous, next) in zip(bucketing.displayBuckets, bucketing.displayBuckets.dropFirst()) {
            #expect(previous.end == next.start)
        }

        let lengths = bucketing.displayBuckets.map { $0.duration / 3600 }
        #expect(lengths.contains(23), "The spring-forward day should be 23 hours")
        #expect(lengths.filter { $0 == 24 }.count >= 10)
    }

    @Test("Prior period is equal length and directly precedes the display range")
    func priorRange() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10)
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        let prior = try #require(bucketing.priorRange)
        #expect(prior.end == bucketing.displayRange.start)
        // The 14 days before the visible range (Feb 11 - Feb 25) contain no DST
        // transition, so every bucket is a full day.
        #expect(prior.duration == 14 * 24 * 3600)
        #expect(bucketing.fetchRange.start == prior.start)
        #expect(bucketing.fetchRange.end == bucketing.displayRange.end)
    }

    @Test("Prior period can be omitted")
    func priorRangeOmitted() {
        let calendar = Self.calendar()
        let bucketing = Bucketing(
            window: .weekly,
            calendar: calendar,
            now: Self.date(calendar, 2026, 3, 10),
            includesPriorPeriod: false
        )
        #expect(bucketing.priorRange == nil)
        #expect(bucketing.fetchRange.start == bucketing.displayRange.start)
    }

    @Test("Weekly buckets start on the calendar's first weekday")
    func weeklyStart() {
        let calendar = Self.calendar(firstWeekday: 2)
        let now = Self.date(calendar, 2026, 3, 10) // a Tuesday
        let bucketing = Bucketing(window: .weekly, calendar: calendar, now: now)

        #expect(bucketing.displayBuckets.count == 8)
        for bucket in bucketing.displayBuckets {
            #expect(calendar.component(.weekday, from: bucket.start) == 2)
        }
    }

    @Test("Monthly buckets start on the first of the month")
    func monthlyStart() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 31)
        let bucketing = Bucketing(window: .monthly, calendar: calendar, now: now)

        #expect(bucketing.displayBuckets.count == 6)
        #expect(bucketing.displayBuckets.last?.start == calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        #expect(bucketing.displayBuckets.map { calendar.component(.day, from: $0.start) } == Array(repeating: 1, count: 6))
    }

    @Test("Hourly buckets cover the last 24 hours")
    func hourlyBuckets() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let bucketing = Bucketing(window: .hourly, calendar: calendar, now: now)

        #expect(bucketing.displayBuckets.count == 24)
        #expect(try #require(bucketing.displayBuckets.last?.contains(now)))
        #expect(try calendar.component(.minute, from: #require(bucketing.displayBuckets.last?.start)) == 0)
        #expect(bucketing.bucketIndex(for: now) == 23)
    }

    @Test("Hourly headline is the trailing 60 minutes, not the clock hour")
    func hourlyHeadlineTrailsNow() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let bucketing = Bucketing(window: .hourly, calendar: calendar, now: now)

        // The endpoint is the next whole minute, so an in-progress minute is
        // included; on an exact minute boundary it is the completed hour.
        let headline = bucketing.headlineRange
        #expect(headline.end == now)
        #expect(headline.start == Self.date(calendar, 2026, 3, 10, 13, 37))
        #expect(headline.duration == 3600)
        #expect(headline.contains(now))
        // The rolling figure still sits inside the chart's 24-hour history.
        #expect(bucketing.displayRange.start <= headline.start)
        #expect(headline.end <= bucketing.displayRange.end)

        let prior = try #require(bucketing.priorHeadlineRange)
        #expect(prior.end == headline.start)
        #expect(prior.duration == 3600)
    }

    @Test("Calendar windows headline the in-progress bucket")
    func calendarHeadlineIsCurrentBucket() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        for window in [SpendWindow.daily, .weekly, .monthly] {
            let bucketing = Bucketing(window: window, calendar: calendar, now: now)
            #expect(bucketing.headlineRange == bucketing.currentBucket)
        }
    }

    @Test("Timestamps outside the display range map to no bucket")
    func outOfRange() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10)
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        #expect(bucketing.bucketIndex(for: bucketing.displayRange.start.addingTimeInterval(-1)) == nil)
        #expect(bucketing.bucketIndex(for: bucketing.displayRange.end) == nil)
        #expect(bucketing.bucketIndex(for: bucketing.displayRange.start) == 0)

        let priorDate = try #require(bucketing.priorRange?.start.addingTimeInterval(60))
        #expect(bucketing.bucketIndex(for: priorDate) == nil)
        #expect(bucketing.containsInPriorPeriod(priorDate))
    }

    @Test("UTC mode buckets on UTC boundaries regardless of local zone")
    func utcMode() throws {
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let bucketing = Bucketing(window: .daily, timeZoneMode: .utc, now: now)
        #expect(bucketing.calendar.timeZone.secondsFromGMT() == 0)
        #expect(try bucketing.calendar.component(.hour, from: #require(bucketing.currentBucket?.start)) == 0)
    }

    @Test("Bucket labels are non-empty for every window")
    func labels() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10)
        for window in SpendWindow.allCases {
            let bucketing = Bucketing(window: window, calendar: calendar, now: now)
            for index in bucketing.displayBuckets.indices {
                #expect(!bucketing.label(for: index).isEmpty)
            }
        }
    }

    @Test("Axis labels are evenly spread and pin both ends of the chart")
    func axisLabelIndices() {
        // Fourteen daily buckets, five labels: both ends labelled, no crowding.
        #expect(SpendWindow.daily.axisLabelIndices(bucketCount: 14, tickCount: 5) == [0, 3, 7, 10, 13])
        // One label per bucket when the axis has room for them all.
        #expect(SpendWindow.monthly.axisLabelIndices(bucketCount: 6, tickCount: 6) == [0, 1, 2, 3, 4, 5])
        // Never fewer than the two ends, however small the tick budget.
        #expect(SpendWindow.hourly.axisLabelIndices(bucketCount: 24, tickCount: 1) == [0, 23])
        // Degenerate charts still label every bar they have.
        #expect(SpendWindow.daily.axisLabelIndices(bucketCount: 1, tickCount: 5) == [0])
        #expect(SpendWindow.daily.axisLabelIndices(bucketCount: 2, tickCount: 5) == [0, 1])
        #expect(SpendWindow.daily.axisLabelIndices(bucketCount: 0, tickCount: 5).isEmpty)
    }

    @Test("Any instant lands in exactly one bucket")
    func partition() throws {
        let calendar = Self.calendar()
        for window in SpendWindow.allCases {
            let now = Self.date(calendar, 2026, 6, 15, 7, 15)
            let bucketing = Bucketing(window: window, calendar: calendar, now: now)
            var seen = Set<Int>()
            var cursor = bucketing.displayRange.start
            while cursor < bucketing.displayRange.end {
                let index = try #require(bucketing.bucketIndex(for: cursor))
                seen.insert(index)
                cursor = bucketing.displayBuckets[index].end
            }
            #expect(seen.count == bucketing.displayBuckets.count)
        }
    }
}
