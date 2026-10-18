import Foundation
import Testing
@testable import TokenMeterKit

/// Clicking a bar turns the breakdown into a single-slice reading. These tests
/// pin down that the rows, their denominators, and their colours all come from
/// the selected bucket rather than from the headline period or the window.
@Suite("Slice breakdowns")
struct BreakdownPeriodTests {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2
        return calendar
    }

    static func now() -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
    }

    /// 14 daily buckets ending 2026-03-10. Bucket 12 is March 9, bucket 13 is
    /// the in-progress March 10. Model A spans both; model B only today.
    private static func report() -> SpendReport {
        let bucketing = Bucketing(window: .daily, calendar: calendar(), now: now())

        func slice(_ bucket: Int, model: String, amount: String, tokens: (Int, Int), requests: Int) -> SpendSlice {
            let interval = bucketing.displayBuckets[bucket]
            return SpendSlice(
                start: interval.start,
                end: interval.end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: model,
                upstreamProvider: "OpenAI",
                amount: Decimal(string: amount)!,
                promptTokens: tokens.0,
                completionTokens: tokens.1,
                requests: requests
            )
        }

        return SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: [
                            slice(12, model: "vendor/model-a", amount: "1.00", tokens: (100, 20), requests: 3),
                            slice(13, model: "vendor/model-a", amount: "2.00", tokens: (200, 40), requests: 5),
                            slice(13, model: "vendor/model-b", amount: "6.00", tokens: (300, 60), requests: 10),
                        ],
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
    }

    private static func start(of bucket: Int) -> Date {
        report().buckets[bucket].start
    }

    @Test("A selected bar breaks down into its own slices only")
    func bucketBreakdown() {
        let report = Self.report()
        let rows = report.breakdown(for: .bucket(Self.start(of: 12)))

        // model-b has nothing in bucket 12, so it is not listed as a $0 row.
        #expect(rows.map(\.series.label) == ["model-a"])
        #expect(rows.map(\.amount) == [1])
        #expect(rows.map(\.tokens) == [120])
        #expect(rows.map(\.requests) == [3])
        #expect(rows[0].share == 1)
        // Colour still comes from the window ranking: model-a is second there.
        #expect(rows[0].colorIndex == 1)
    }

    @Test("A bucket's denominator is the bar's own height, tokens, and requests")
    func bucketTotals() {
        let report = Self.report()
        let totals = report.totals(for: .bucket(Self.start(of: 13)))

        #expect(totals.spend == 8)
        #expect(totals.spend == report.buckets[13].total)
        #expect(totals.tokens == 600)
        #expect(totals.requests == 15)
    }

    @Test("Token and request measures rank within the selected bucket")
    func bucketMeasureShares() {
        let report = Self.report()
        let rows = report.breakdown(for: .bucket(Self.start(of: 13)), measure: .tokens)

        #expect(rows.map(\.series.label) == ["model-b", "model-a"])
        #expect(rows.map(\.tokens) == [360, 240])
        #expect(rows.map(\.share) == [0.6, 0.4])
        // The token-ranked row still states its share of the bar's spend.
        #expect(rows.map(\.spendShare) == [0.75, 0.25])
        #expect(report.breakdown(for: .bucket(Self.start(of: 13)), measure: .requests).map(\.requests) == [10, 5])
    }

    @Test("Selecting a bucket does not disturb the headline or window periods")
    func periodsStayDistinct() {
        let report = Self.report()
        let selected = Self.start(of: 13)

        #expect(report.totals(for: .current).spend == 8)
        #expect(report.totals(for: .window).spend == 9)
        #expect(report.totals(for: .bucket(selected)).spend == 8)
        #expect(report.currentBreakdown.map(\.amount) == [6, 2])
        #expect(report.windowBreakdown.map(\.amount) == [6, 3])
        #expect(report.breakdown(for: .bucket(Self.start(of: 12))).map(\.amount) == [1])
    }

    @Test("A bucket that is no longer in the report yields no rows and zero totals")
    func staleSelection() {
        let report = Self.report()
        let stale = Date(timeIntervalSince1970: 0)

        #expect(report.bucket(startingAt: stale) == nil)
        #expect(report.breakdown(for: .bucket(stale)).isEmpty)
        #expect(report.totals(for: .bucket(stale)).spend == 0)
        #expect(report.totals(for: .bucket(stale)).tokens == 0)
    }

    @Test("Per-bucket counters travel with each series")
    func perBucketCounters() throws {
        let report = Self.report()
        let modelB = try #require(report.series.first { $0.label == "model-b" })

        #expect(modelB.amounts == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6])
        #expect(modelB.perBucket[13].tokens == 360)
        #expect(modelB.perBucket[13].requests == 10)
        #expect(modelB.perBucket[12].amount == 0)
        #expect(modelB.totalTokens == 360)
        #expect(modelB.currentTokens == 360)
    }
}

/// Labels are the only thing standing between a bar and an ambiguous reading, so
/// their boundaries get tested too.
@Suite("Bucket interval labels")
struct BucketRangeLabelTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func label(_ window: SpendWindow, _ start: Date, _ end: Date) -> String {
        window.bucketRangeLabel(
            start: start,
            end: end,
            calendar: calendar(),
            locale: Locale(identifier: "en_US")
        )
    }

    @Test("A single day does not read as a two-day span")
    func dailyLabel() {
        // The bucket end is exclusive, so March 10 runs to March 11 at 00:00.
        let label = Self.label(.daily, Self.date(2026, 3, 10), Self.date(2026, 3, 11))
        #expect(label == "Mar 10")
    }

    @Test("A week names both of its ends, and a week across months names both months")
    func weeklyLabel() {
        let label = Self.label(.weekly, Self.date(2026, 3, 2), Self.date(2026, 3, 9))
        #expect(label.hasPrefix("Mar 2"))
        #expect(label.hasSuffix("8"))

        let acrossMonths = Self.label(.weekly, Self.date(2026, 2, 23), Self.date(2026, 3, 2))
        #expect(acrossMonths.contains("Feb 23"))
        #expect(acrossMonths.contains("Mar 1"))
    }

    @Test("A month is named once")
    func monthlyLabel() {
        let label = Self.label(.monthly, Self.date(2026, 3, 1), Self.date(2026, 4, 1))
        #expect(label == "March 2026")
    }

    @Test("An hour keeps its end, because the bar is the hour between them")
    func hourlyLabel() {
        let label = Self.label(.hourly, Self.date(2026, 3, 10, 14), Self.date(2026, 3, 10, 15))
        #expect(label.contains("Tue"))
        #expect(label.contains("2:00"))
        #expect(label.contains("3:00"))
    }
}
