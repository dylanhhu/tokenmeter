import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Rolling period scope")
struct RollingScopeTests {
    static func calendar(_ identifier: String = "UTC", firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    static func date(
        _ calendar: Calendar,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test("Rolling headlines end now and are one bucket long")
    func rollingHeadlineLengths() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)

        let hourly = Bucketing(window: .hourly, scope: .trailing, calendar: calendar, now: now)
        #expect(hourly.headlineRange.end == now)
        #expect(hourly.headlineRange.start == Self.date(calendar, 2026, 3, 10, 13, 37))

        let daily = Bucketing(window: .daily, scope: .trailing, calendar: calendar, now: now)
        #expect(daily.headlineRange.end == now)
        #expect(daily.headlineRange.start == Self.date(calendar, 2026, 3, 9, 14, 37))
        #expect(daily.headlineRange.duration == 86_400)

        let weekly = Bucketing(window: .weekly, scope: .trailing, calendar: calendar, now: now)
        #expect(weekly.headlineRange.start == Self.date(calendar, 2026, 3, 3, 14, 37))
        #expect(weekly.headlineRange.duration == TimeInterval(7 * 86_400))

        // A rolling month is as long as the month in progress, so March gives 31
        // days and February would give 28.
        let march = Bucketing(window: .monthly, scope: .trailing, calendar: calendar, now: now)
        #expect(march.headlineRange.start == Self.date(calendar, 2026, 2, 7, 14, 37))
        #expect(march.headlineRange.duration == TimeInterval(31 * 86_400))

        let february = Bucketing(
            window: .monthly,
            scope: .trailing,
            calendar: calendar,
            now: Self.date(calendar, 2026, 2, 20, 9, 5)
        )
        #expect(february.headlineRange.duration == TimeInterval(28 * 86_400))
    }

    @Test("The comparison period is the equal-length interval before the headline")
    func rollingPriorPeriod() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let bucketing = Bucketing(window: .daily, scope: .trailing, calendar: calendar, now: now)

        let prior = try #require(bucketing.priorHeadlineRange)
        #expect(prior.end == bucketing.headlineRange.start)
        #expect(prior.duration == bucketing.headlineRange.duration)
        // Both lie inside the fetched range, so the provider can resolve them.
        #expect(bucketing.fetchRange.start <= prior.start)
        #expect(bucketing.headlineRange.end <= bucketing.fetchRange.end)
    }

    @Test("Rolling labels follow the actual interval, not the window name")
    func rollingLabels() {
        #expect(SpendWindow.hourly.headlineLabel(scope: .trailing, duration: 3600) == "last hour")
        #expect(SpendWindow.daily.headlineLabel(scope: .trailing, duration: TimeInterval(86_400)) == "last 24 hours")
        #expect(SpendWindow.weekly.headlineLabel(scope: .trailing, duration: TimeInterval(7 * 86_400)) == "last 7 days")
        #expect(SpendWindow.monthly.headlineLabel(scope: .trailing, duration: TimeInterval(31 * 86_400)) == "last 31 days")

        // A spring-forward day is 23 hours long, and the caption says so.
        #expect(SpendWindow.daily.headlineLabel(scope: .trailing, duration: TimeInterval(23 * 3600)) == "last 23 hours")

        #expect(SpendWindow.weekly.headlineLabel(scope: .calendar, duration: TimeInterval(86_400)) == "this week")
        #expect(SpendWindow.hourly.headlineLabel(scope: .calendar, duration: 3600) == "this hour")

        #expect(SpendWindow.weekly.shortTitle(scope: .calendar, duration: 0) == "1W")
        #expect(SpendWindow.weekly.shortTitle(scope: .trailing, duration: TimeInterval(7 * 86_400)) == "7D")
        #expect(SpendWindow.daily.shortTitle(scope: .trailing, duration: TimeInterval(86_400)) == "24H")
    }

    @Test("Calendar scope still headlines the in-progress bucket, including hourly")
    func calendarHourlyHeadline() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let bucketing = Bucketing(window: .hourly, scope: .calendar, calendar: calendar, now: now)

        #expect(bucketing.headlineRange.start == Self.date(calendar, 2026, 3, 10, 14))
        #expect(bucketing.headlineRange.end == Self.date(calendar, 2026, 3, 10, 15))
        // The delta compares the same 37 minutes of the previous window.
        let prior = bucketing.priorHeadlineRange
        #expect(prior?.duration == TimeInterval(37 * 60))
        #expect(prior?.start == bucketing.priorRange?.start)
    }

    @Test("Chart buckets stay calendar-aligned under a rolling headline")
    func chartBucketsDoNotMove() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 14, 37)
        let calendarScope = Bucketing(window: .daily, scope: .calendar, calendar: calendar, now: now)
        let rolling = Bucketing(window: .daily, scope: .trailing, calendar: calendar, now: now)

        #expect(rolling.displayBuckets == calendarScope.displayBuckets)
        #expect(rolling.fetchRange == calendarScope.fetchRange)
        // The rolling headline straddles the last two bars.
        #expect(rolling.bucketIndex(for: rolling.headlineRange.start) == 12)
        #expect(rolling.bucketIndex(for: rolling.headlineRange.end.addingTimeInterval(-1)) == 13)
    }

    @Test("A rolling daily headline sums fine slices across both calendar days")
    func rollingHeadlineSumsAcrossBuckets() throws {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 12)
        let bucketing = Bucketing(window: .daily, scope: .trailing, calendar: calendar, now: now)

        func slice(_ day: Int, _ hour: Int, _ amount: String, tokens: (Int, Int) = (0, 0)) -> SpendSlice {
            let start = Self.date(calendar, 2026, 3, day, hour)
            return SpendSlice(
                start: start,
                end: start.addingTimeInterval(3600),
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "openai/gpt-5.1",
                upstreamProvider: "OpenAI",
                amount: Decimal(string: amount)!,
                promptTokens: tokens.0,
                completionTokens: tokens.1,
                requests: 1
            )
        }

        let slices = [
            // Before both the rolling window and its comparison period.
            slice(8, 10, "50.00"),
            // Inside the rolling window, spread over two calendar days.
            slice(9, 12, "2.00", tokens: (100, 50)),
            slice(9, 23, "3.00", tokens: (200, 100)),
            slice(10, 0, "1.50", tokens: (300, 150)),
            // Inside the comparison window (Mar 8 12:00 – Mar 9 12:00).
            slice(8, 13, "4.00"),
            slice(9, 6, "1.00"),
        ]
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(slices: slices, capabilities: AggregationTests.capabilities())
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.scope == .trailing)
        #expect(report.headlineTotal == Decimal(string: "6.50"))
        #expect(report.currentPeriodTotal == Decimal(string: "6.50"))
        #expect(report.headlineCaption == "last 24 hours")
        #expect(report.currentBreakdownLabel == "last 24 hours")
        #expect(report.priorComparableTotal == 5)
        #expect(report.currentTokens == 900)
        #expect(report.currentRequests == 3)

        // The breakdown's denominator is the rolling window, so the row's share
        // matches the headline rather than the last bar.
        let row = try #require(report.currentBreakdown.first)
        #expect(row.share == 1)

        // The chart still draws calendar days, so the rolling headline straddles
        // two bars: Mar 9 holds 2 + 3 + 1 and Mar 10 holds 1.50.
        #expect(report.buckets[12].total == 6)
        #expect(report.buckets[13].total == Decimal(string: "1.50"))
        #expect(report.grandTotal == Decimal(string: "61.50"))
        #expect(report.priorComparisonCaption == "Versus the previous 24 hours")
    }

    @Test("The synthetic provider refines boundaries without overlapping buckets")
    func demoProviderPartitionsItsRange() async throws {
        for window in SpendWindow.allCases {
            let bucketing = Bucketing(window: window, scope: .trailing, timeZoneMode: .utc)
            let result = try await DemoProvider().fetchSpend(SpendRequest(bucketing: bucketing))
            #expect(result.slices.isEmpty == false)

            // Two slices for the same series that overlap would be counted twice
            // in the headline, so the walk must stay contiguous and half-open.
            var bySeries: [String: [(Date, Date)]] = [:]
            for slice in result.slices {
                let key = "\(slice.model ?? "-")|\(slice.upstreamProvider ?? "-")"
                bySeries[key, default: []].append((slice.start, slice.end))
            }
            for (key, intervals) in bySeries {
                let sorted = intervals.sorted { $0.0 < $1.0 }
                for (previous, next) in zip(sorted, sorted.dropFirst()) {
                    #expect(previous.1 <= next.0, "overlap in \(key) for \(window.rawValue)")
                }
            }

            // No row straddles a boundary the aggregator sums at by more than one
            // refinement bucket, so the rolling total is exact to a minute for
            // hourly and daily windows and to an hour for weekly and monthly ones.
            let resolution: TimeInterval = switch window {
            case .hourly, .daily: 60
            case .weekly, .monthly: 3600
            }
            let boundaries = [bucketing.headlineRange.start, bucketing.priorHeadlineRange?.start]
                .compactMap(\.self)
            for slice in result.slices {
                for boundary in boundaries where slice.start < boundary && slice.end > boundary {
                    #expect(
                        slice.end.timeIntervalSince(slice.start) <= resolution,
                        "\(window.rawValue) slice \(slice.start)–\(slice.end) straddles \(boundary)"
                    )
                }
            }

            let headline = result.slices.filter {
                $0.start >= bucketing.headlineRange.start && $0.start < bucketing.headlineRange.end
            }
            #expect(headline.isEmpty == false)
        }
    }

    @Test("A provider-reported period total never stands in for a rolling headline")
    func periodTotalsDoNotOverrideRolling() {
        let calendar = Self.calendar()
        let now = Self.date(calendar, 2026, 3, 10, 12)
        let bucketing = Bucketing(window: .daily, scope: .trailing, calendar: calendar, now: now)

        let inside = Self.date(calendar, 2026, 3, 10, 9)
        let result = SpendFetchResult(
            slices: [
                SpendSlice(
                    start: inside,
                    end: inside.addingTimeInterval(3600),
                    providerID: "openrouter",
                    providerName: "OpenRouter",
                    model: "openai/gpt-5.1",
                    amount: 2
                ),
            ],
            capabilities: ProviderCapabilities(windows: [.daily], rollingWindows: [.daily]),
            // What an inference key reports: this key's own calendar-day total.
            periodTotals: [.daily: 40]
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.headlineTotal == 2)
        #expect(report.headlineIsProviderReported == false)

        // The same total still wins for the calendar reading, where it is exact.
        let calendarReport = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: Bucketing(window: .daily, calendar: calendar, now: now),
            grouping: .model
        )
        #expect(calendarReport.headlineTotal == 40)
        #expect(calendarReport.headlineIsProviderReported)
    }

    @Test("Rolling scope needs finer rows than the bucket it sits in")
    func rollingCapabilityGating() {
        // Calendar support says nothing about rolling support: a credential that
        // only reports day rows can fill a daily window but cannot resolve a
        // rolling one.
        let capabilities = ProviderCapabilities(windows: [.daily, .weekly], rollingWindows: [.weekly])
        #expect(capabilities.supports(.daily))
        #expect(!capabilities.supports(.daily, scope: .trailing))
        #expect(capabilities.supports(.weekly, scope: .trailing))
        #expect(capabilities.supportedWindows(for: .trailing) == [.weekly])

        // Adapters that do not distinguish the two inherit the calendar set.
        #expect(ProviderCapabilities(windows: [.daily]).rollingWindows == [.daily])
    }
}
