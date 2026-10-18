import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Trailing hourly headline")
struct HourlyTrailingTests {
    @Test("Headline sums the trailing 60 minutes across clock hours")
    func trailingHeadline() {
        let calendar = AggregationTests.calendar()
        let bucketing = Bucketing(window: .hourly, scope: .trailing, calendar: calendar, now: AggregationTests.now()) // 12:00

        func minuteSlice(
            _ hour: Int,
            _ minute: Int,
            model: String,
            amount: String,
            tokens: (Int, Int) = (0, 0)
        ) -> SpendSlice {
            let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
            return SpendSlice(
                start: start,
                end: start.addingTimeInterval(60),
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: model,
                upstreamProvider: "OpenAI",
                amount: Decimal(string: amount)!,
                promptTokens: tokens.0,
                completionTokens: tokens.1
            )
        }

        let slices = [
            // Inside the trailing hour, which spans 11:00–12:00 here.
            minuteSlice(11, 15, model: "openai/gpt-5.1", amount: "2.00", tokens: (10, 5)),
            minuteSlice(11, 45, model: "anthropic/claude-sonnet-4.5", amount: "3.00", tokens: (20, 10)),
            minuteSlice(11, 59, model: "openai/gpt-5.1", amount: "1.00", tokens: (1, 0)),
            // In the next clock hour, so it belongs to the chart's in-progress
            // bucket but not to the trailing hour.
            minuteSlice(12, 0, model: "openai/gpt-5.1", amount: "9.00", tokens: (100, 100)),
            // The hour before the trailing window, for the delta.
            minuteSlice(10, 5, model: "openai/gpt-5.1", amount: "5.00"),
            minuteSlice(10, 55, model: "openai/gpt-5.1", amount: "4.00"),
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

        #expect(report.headlineTotal == 6)
        #expect(report.currentPeriodTotal == 6)
        #expect(report.priorComparableTotal == 9)
        #expect(report.currentPromptTokens == 31)
        #expect(report.currentCompletionTokens == 15)

        // The breakdown shares the trailing window's denominator...
        let rows = report.currentBreakdown
        #expect(rows.map(\.amount) == [3, 3])
        #expect(rows.allSatisfy { $0.share == 0.5 })
        // ...even though the rightmost chart bar is the clock hour.
        #expect(report.buckets.last?.total == 9)
        #expect(report.buckets[report.buckets.count - 2].total == 6)
    }
}
