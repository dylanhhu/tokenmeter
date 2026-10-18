import Foundation
import Testing
@testable import TokenMeterKit

/// Token and request usage for one slice, kept as a struct so test helpers stay
/// under the tuple and parameter lint limits.
private struct Usage {
    var prompt: Int
    var completion: Int
    var requests: Int
}

@Suite("Token measures")
struct TokenMeasureTests {
    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    private static func now() -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
    }

    private static func slice(
        _ bucketing: Bucketing,
        bucket: Int,
        model: String,
        amount: String,
        usage: Usage
    ) -> SpendSlice {
        let interval = bucketing.displayBuckets[bucket]
        return SpendSlice(
            start: interval.start,
            end: interval.end,
            providerID: "openrouter",
            providerName: "OpenRouter",
            model: model,
            upstreamProvider: "OpenAI",
            amount: Decimal(string: amount)!,
            promptTokens: usage.prompt,
            completionTokens: usage.completion,
            requests: usage.requests
        )
    }

    /// Model A dominates the window; model B dominates today. Both spend and
    /// token volume disagree about which one matters, which is the case the
    /// measure switch exists to expose.
    private static func report(extra: [SpendSlice] = []) -> SpendReport {
        let bucketing = Bucketing(window: .daily, calendar: calendar(), now: now())
        let slices = [
            slice(
                bucketing,
                bucket: 10,
                model: "vendor/model-a",
                amount: "10.00",
                usage: Usage(prompt: 900, completion: 100, requests: 10)
            ),
            slice(bucketing, bucket: 13, model: "vendor/model-a", amount: "1.00", usage: Usage(prompt: 70, completion: 30, requests: 2)),
            slice(bucketing, bucket: 13, model: "vendor/model-b", amount: "3.00", usage: Usage(prompt: 200, completion: 50, requests: 3)),
        ] + extra
        return SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: slices,
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
    }

    @Test("Token rows share the headline's denominator, not the window's")
    func currentTokenBreakdown() {
        let report = Self.report()
        let current = report.totals(for: .current)
        #expect(report.currentTokens == 350)
        #expect(report.denominator(for: .tokens, in: current) == 350)
        #expect(report.denominator(for: .spend, in: current) == 4)

        let rows = report.currentBreakdown(measure: .tokens)
        // Ranked by today's tokens, which reverses the spend ranking.
        #expect(rows.map(\.series.label) == ["model-b", "model-a"])
        #expect(rows.map(\.tokens) == [250, 100])
        #expect(rows.map { $0.share ?? 0 } == [250.0 / 350.0, 100.0 / 350.0])
        // Spend share stays on the same period, so the divergence is visible.
        #expect(rows[0].spendShare == 0.75)
        #expect(rows[1].spendShare == 0.25)
        #expect(rows[0].measure == .tokens)
    }

    @Test("Window token rows rank across every bucket")
    func windowTokenBreakdown() {
        let report = Self.report()
        #expect(report.totalTokens == 1350)
        let rows = report.windowBreakdown(measure: .tokens)
        #expect(rows.map(\.series.label) == ["model-a", "model-b"])
        #expect(rows.map(\.tokens) == [1100, 250])
        #expect(rows[0].share == 1100.0 / 1350.0)
    }

    @Test("Request measure ranks and shares by request count")
    func requestMeasure() {
        let report = Self.report()
        #expect(report.currentRequests == 5)
        let rows = report.currentBreakdown(measure: .requests)
        #expect(rows.map(\.series.label) == ["model-b", "model-a"])
        #expect(rows.map(\.requests) == [3, 2])
        #expect(rows[0].share == 0.6)
    }

    @Test("Tokens and requests survive folding into Other")
    func otherFoldingPreservesCounters() throws {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let slices = (0 ..< 8).map { index in
            Self.slice(
                bucketing,
                bucket: 13,
                model: "vendor/model-\(index)",
                amount: "\(8 - index).00",
                usage: Usage(prompt: 100 * (index + 1), completion: 10, requests: index + 1)
            )
        }
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(slices: slices, capabilities: ProviderCapabilities(hasModelBreakdown: true))
                ),
            ],
            bucketing: bucketing,
            grouping: .model,
            seriesLimit: 2
        )

        let other = try #require(report.series.last)
        #expect(other.isOther)
        // Models 2...7 are folded: prompts 300…800 sum to 3300, completions 60.
        #expect(other.promptTokens == 3300)
        #expect(other.completionTokens == 60)
        #expect(other.requests == 33)
        #expect(other.totalTokens == 3360)
        #expect(report.totalTokens == 3680)
        // Series still reconcile with the report totals.
        #expect(report.series.map(\.totalTokens).reduce(0, +) == report.totalTokens)
    }

    @Test("Token counters follow the headline interval, not the last bucket")
    func headlineTokensTrailTheHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 5))
        )
        let bucketing = Bucketing(window: .hourly, calendar: calendar, now: now)

        func minuteSlice(_ date: Date, tokens: (Int, Int), requests: Int) -> SpendSlice {
            SpendSlice(
                start: date,
                end: date.addingTimeInterval(60),
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "vendor/model-a",
                upstreamProvider: "Vendor",
                amount: 1,
                promptTokens: tokens.0,
                completionTokens: tokens.1,
                requests: requests
            )
        }

        let previousHour = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8, minute: 20))
        )
        let thisHour = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 1))
        )
        let beforeWindow = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 7, minute: 59))
        )

        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: [
                            minuteSlice(previousHour, tokens: (60, 20), requests: 2),
                            minuteSlice(thisHour, tokens: (30, 10), requests: 1),
                            minuteSlice(beforeWindow, tokens: (900, 100), requests: 9),
                        ],
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )

        // The trailing hour reaches into the previous clock-hour bar.
        #expect(previousHour >= bucketing.headlineRange.start)
        #expect(previousHour < bucketing.headlineRange.end)
        #expect(!bucketing.headlineRange.contains(beforeWindow))
        #expect(report.currentTokens == 120)
        #expect(report.currentRequests == 3)

        let series = try #require(report.series.first)
        #expect(series.currentPromptTokens == 90)
        #expect(series.currentCompletionTokens == 30)
        #expect(series.currentRequests == 3)

        let rows = report.currentBreakdown(measure: .tokens)
        #expect(rows.first?.tokens == 120)
        #expect(rows.first?.share == 1)
    }

    @Test("Without token or request data only spend is offered")
    func supportedMeasures() {
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(providerID: "openrouter", result: SpendFetchResult(slices: [], capabilities: .unavailable)),
            ],
            bucketing: Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now()),
            grouping: .model
        )
        #expect(report.supportedMeasures == [.spend])
        #expect(report.efficiency.hasData == false)
        #expect(Self.report().supportedMeasures == [.spend, .tokens, .requests])
    }

    @Test("Row labels carry the measure's unit and the other reading")
    func rowLabels() {
        let rows = Self.report().currentBreakdown(measure: .tokens)
        #expect(rows[0].valueLabel == "250 tok")
        #expect(rows[0].shareLabel == "71.4%")
        #expect(rows[0].crossShareLabel == "75.0% of spend")

        let spendRows = Self.report().currentBreakdown()
        #expect(spendRows[0].valueLabel == "$3.00")
        #expect(spendRows[0].crossShareLabel?.hasSuffix("/M") == true)
    }
}

@Suite("Token efficiency")
struct TokenEfficiencyTests {
    private static func report(extra: [SpendSlice] = []) -> SpendReport {
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }()
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        func slice(bucket: Int, model: String, amount: String, tokens: (Int, Int), requests: Int) -> SpendSlice {
            let interval = bucketing.displayBuckets[bucket]
            return SpendSlice(
                start: interval.start,
                end: interval.end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: model,
                upstreamProvider: "Vendor",
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
                            slice(bucket: 10, model: "vendor/model-a", amount: "10.00", tokens: (900, 100), requests: 10),
                            slice(bucket: 13, model: "vendor/model-a", amount: "1.00", tokens: (70, 30), requests: 2),
                            slice(bucket: 13, model: "vendor/model-b", amount: "3.00", tokens: (200, 50), requests: 3),
                        ] + extra,
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
    }

    @Test("Blended rate, output ratio, and per-request cost come from window totals")
    func accountFigures() throws {
        let efficiency = Self.report().efficiency
        // 14 USD across 1350 tokens.
        let rate = try #require(efficiency.costPerMillionTokens)
        #expect(abs(rate.doubleValue - 10370.370_370) < 0.001)
        let label = try #require(efficiency.costPerMillionTokensLabel)
        #expect(label.hasPrefix("$") && label.hasSuffix("/M"))

        #expect(efficiency.outputRatio == 180.0 / 1170.0)
        #expect(efficiency.tokensPerRequest == 90)
        #expect(efficiency.costPerRequest.map { abs($0.doubleValue - 14.0 / 15.0) < 0.0001 } == true)
        #expect(efficiency.tokens == 1350)
        #expect(efficiency.hasData)
    }

    @Test("Per-series rates are relative to the window's blended rate")
    func seriesRates() throws {
        let efficiency = Self.report().efficiency
        let modelA = try #require(efficiency.rows.first { $0.label == "model-a" })
        let modelB = try #require(efficiency.rows.first { $0.label == "model-b" })

        #expect(modelA.costPerMillionTokens?.doubleValue == 10000)
        #expect(modelB.costPerMillionTokens?.doubleValue == 12000)
        #expect(modelA.tokenShare == 1100.0 / 1350.0)
        #expect(modelA.spendShare == 11.0 / 14.0)
        #expect(modelA.outputRatio == 130.0 / 970.0)
        #expect(modelA.tokensPerRequest == 1100.0 / 12.0)

        let blended = try #require(efficiency.costPerMillionTokens?.doubleValue)
        #expect(abs((modelA.rateMultiple ?? 0) - 10000 / blended) < 0.0001)
        #expect(abs((modelB.rateMultiple ?? 0) - 12000 / blended) < 0.0001)
    }

    @Test("The priciest series ignores volumes too small to price")
    func priciestSeries() throws {
        let report = Self.report()
        let priciest = try #require(report.efficiency.priciest)
        #expect(priciest.label == "model-b")

        // Forty tokens with a dollar of spend implies $25k/M, which is arithmetic,
        // not a rate anyone paid.
        let noisy = Self.report(extra: [
            SpendSlice(
                start: report.buckets[13].start,
                end: report.buckets[13].end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "vendor/tiny-sample",
                upstreamProvider: "Vendor",
                amount: 1,
                promptTokens: 30,
                completionTokens: 10,
                requests: 1
            ),
        ])
        #expect(noisy.efficiency.priciest?.label == "model-b")
    }

    @Test("The outlier note states both rates it compares")
    func priciestNoteCopy() throws {
        let efficiency = Self.report().efficiency
        let row = try #require(efficiency.rows.first { $0.label == "model-b" })
        let note = try #require(efficiency.priciestNote)
        let rowRate = try #require(row.costPerMillionTokensLabel)
        let blended = try #require(efficiency.costPerMillionTokensLabel)
        let multiple = try #require(row.rateMultiple)

        #expect(note.contains(row.label))
        #expect(note.contains(rowRate))
        #expect(note.contains(blended))
        #expect(note.contains(String(format: "%.1f×", multiple)))
        #expect(note.hasPrefix("Highest rate"))
        // "per token" without a denominator reads as a list price; the copy has
        // to keep the billed-average framing visible.
        #expect(!note.contains("most per token"))

        // Screen readers should not hear "/M".
        let spoken = try #require(efficiency.priciestNoteSpoken)
        #expect(!spoken.contains("/M"))
        #expect(spoken.contains("per million tokens"))
        #expect(spoken.contains("times the window's blended"))
    }

    @Test("A single series has no meaningful outlier to report")
    func singleSeriesHasNoOutlier() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: Date())
        let single = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: [
                            SpendSlice(
                                start: bucketing.displayBuckets[13].start,
                                end: bucketing.displayBuckets[13].end,
                                providerID: "openrouter",
                                providerName: "OpenRouter",
                                model: "vendor/only",
                                amount: 2,
                                promptTokens: 900,
                                completionTokens: 100,
                                requests: 4
                            ),
                        ],
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
        #expect(single.series.count == 1)
        #expect(single.efficiency.priciest == nil)
    }

    @Test("Efficiency is captioned by the window it covers, not the headline")
    func windowCaption() {
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar
        }()
        let daily = Bucketing(window: .daily, calendar: calendar, now: Date())
        let hourly = Bucketing(window: .hourly, calendar: calendar, now: Date())
        let monthly = Bucketing(window: .monthly, calendar: calendar, now: Date())
        func span(_ bucketing: Bucketing) -> String {
            SpendAggregator.makeReport(contributions: [], bucketing: bucketing, grouping: .model).windowSpanLabel
        }
        #expect(span(daily) == "last 14 days")
        #expect(span(hourly) == "last 24h")
        #expect(span(monthly) == "last 6 months")
    }
}
