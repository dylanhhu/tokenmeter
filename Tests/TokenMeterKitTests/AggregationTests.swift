import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Spend aggregation")
struct AggregationTests {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }

    static func now() -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
    }

    static func slice(
        _ bucketing: Bucketing,
        bucketIndex: Int,
        model: String? = "openai/gpt-5.1",
        provider: String? = "OpenAI",
        amount: String,
        adapter: ProviderID = "openrouter",
        tokens: (Int, Int) = (0, 0),
        requests: Int = 0
    ) -> SpendSlice {
        let bucket = bucketing.displayBuckets[bucketIndex]
        return SpendSlice(
            start: bucket.start,
            end: bucket.end,
            providerID: adapter,
            providerName: "OpenRouter",
            model: model,
            upstreamProvider: provider,
            amount: Decimal(string: amount)!,
            promptTokens: tokens.0,
            completionTokens: tokens.1,
            requests: requests
        )
    }

    static func capabilities(breakdown: Bool = true) -> ProviderCapabilities {
        ProviderCapabilities(windows: Set(SpendWindow.allCases), hasModelBreakdown: breakdown, hasProviderBreakdown: breakdown)
    }

    @Test("Headline is the in-progress bucket, not the window total")
    func headlineIsCurrentBucket() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [
                Self.slice(bucketing, bucketIndex: 12, amount: "1.00"),
                Self.slice(bucketing, bucketIndex: 13, amount: "2.50"),
            ],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.headlineTotal == Decimal(string: "2.50"))
        #expect(report.grandTotal == Decimal(string: "3.50"))
        #expect(report.buckets.count == 14)
        #expect(report.buckets.last?.isCurrent == true)
    }

    @Test("Report is self-describing: window and buckets match the bucketing")
    func reportDescribesItsOwnWindow() {
        // Views derive axis configuration from `report.window` alone, so
        // the report must always carry the window it was aggregated for.
        // A chart rendered from a stale report against a newly selected
        // window's scale is what produced mid-refresh glitches.
        for window in SpendWindow.allCases {
            let bucketing = Bucketing(window: window, calendar: Self.calendar(), now: Self.now())
            let result = SpendFetchResult(
                slices: [Self.slice(bucketing, bucketIndex: 0, amount: "1.00")],
                capabilities: Self.capabilities()
            )
            let report = SpendAggregator.makeReport(
                contributions: [.init(providerID: "openrouter", result: result)],
                bucketing: bucketing,
                grouping: .model
            )

            #expect(report.window == window)
            #expect(report.buckets.count == bucketing.bucketCount)
            #expect(report.buckets.first?.start == bucketing.displayBuckets.first?.start)
        }
    }

    @Test("Provider-reported period totals win over bucket sums")
    func providerReportedTotals() throws {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = try SpendFetchResult(
            slices: [Self.slice(bucketing, bucketIndex: 13, model: nil, provider: nil, amount: "2.50")],
            capabilities: Self.capabilities(breakdown: false),
            periodTotals: [.daily: #require(Decimal(string: "9.99"))]
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.headlineTotal == Decimal(string: "9.99"))
        #expect(report.headlineIsProviderReported)
    }

    @Test("Model grouping labels models and falls back to unattributed")
    func modelGrouping() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [
                Self.slice(bucketing, bucketIndex: 13, model: "anthropic/claude-sonnet-4.5", provider: "Anthropic", amount: "1.00"),
                Self.slice(bucketing, bucketIndex: 13, model: "openai/gpt-5.1", provider: "OpenAI", amount: "3.00"),
                Self.slice(bucketing, bucketIndex: 12, model: "openai/gpt-5.1", provider: "OpenAI", amount: "2.00"),
                Self.slice(bucketing, bucketIndex: 13, model: nil, provider: nil, amount: "0.50"),
            ],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.series.count == 3)
        let labels = report.series.map(\.label)
        #expect(labels == ["gpt-5.1", "claude-sonnet-4.5", "Unattributed"])
        #expect(report.series[0].total == 5)
        #expect(report.series[0].detail == "OpenAI")
        #expect(report.series[0].amounts[12] == 2)
        #expect(report.series[0].amounts[13] == 3)
    }

    @Test("Provider grouping collapses models to their upstream provider")
    func providerGrouping() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [
                Self.slice(bucketing, bucketIndex: 13, model: "anthropic/claude-sonnet-4.5", provider: "Anthropic", amount: "1.00"),
                Self.slice(bucketing, bucketIndex: 13, model: "anthropic/claude-haiku-4.5", provider: "Anthropic", amount: "0.25"),
                Self.slice(bucketing, bucketIndex: 13, model: "openai/gpt-5.1", provider: "OpenAI", amount: "3.00"),
            ],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .provider
        )

        #expect(report.series.map(\.label) == ["OpenAI", "Anthropic"])
        #expect(report.series[1].total == Decimal(string: "1.25"))
    }

    @Test("Slices without an upstream provider fall back to the adapter name")
    func providerFallback() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [Self.slice(bucketing, bucketIndex: 13, model: nil, provider: nil, amount: "1.00")],
            capabilities: Self.capabilities(breakdown: false)
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .provider
        )
        #expect(report.series.map(\.label) == ["OpenRouter"])
    }

    @Test("Surplus series fold into a trailing Other row")
    func otherFolding() throws {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let slices = (0 ..< 10).map { index in
            Self.slice(bucketing, bucketIndex: 13, model: "vendor/model-\(index)", provider: "Vendor", amount: "\(10 - index).00")
        }
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(slices: slices, capabilities: Self.capabilities())
                ),
            ],
            bucketing: bucketing,
            grouping: .model,
            seriesLimit: 3
        )

        #expect(report.series.count == 4)
        #expect(report.series.first?.label == "model-0")
        let other = try #require(report.series.last)
        #expect(other.isOther)
        #expect(other.foldedCount == 7)
        // 7 + 6 + 5 + 4 + 3 + 2 + 1
        #expect(other.total == 28)
        #expect(report.series.map(\.total).reduce(0, +) == report.grandTotal)
    }

    @Test("Prior-period comparison uses the same elapsed duration")
    func comparablePriorPeriod() throws {
        let calendar = Self.calendar()
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: Self.now()) // 12:00 local
        let priorDays = try #require(bucketing.priorRange)
        let firstPriorDay = try #require(calendar.dateInterval(of: .day, for: priorDays.start))

        // Prior period: one full day of spend at 4.00, then a second day at 4.00.
        let slices = [
            Self.slice(bucketing, bucketIndex: 13, amount: "6.00"),
            SpendSlice(
                start: firstPriorDay.start,
                end: firstPriorDay.end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "openai/gpt-5.1",
                upstreamProvider: "OpenAI",
                amount: 4
            ),
            SpendSlice(
                start: firstPriorDay.start.addingTimeInterval(86_400),
                end: firstPriorDay.end.addingTimeInterval(86_400),
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "openai/gpt-5.1",
                upstreamProvider: "OpenAI",
                amount: 8
            ),
        ]
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(slices: slices, capabilities: Self.capabilities())
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )

        #expect(report.priorPeriodTotal == 12)
        // 12:00 elapsed means the first prior day (00:00–24:00) is only half covered.
        #expect(report.priorComparableTotal == 4)
        let change = try #require(report.priorPeriodChange)
        #expect(abs(change - 0.5) < 0.0001)
    }

    @Test("No comparable baseline yields no delta")
    func noDeltaWithoutBaseline() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [Self.slice(bucketing, bucketIndex: 13, amount: "2.00")],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )
        #expect(report.priorPeriodChange == nil)
        #expect(report.priorComparableTotal == nil)
        #expect(report.priorPeriodTotal == 0)
    }

    @Test("Multiple providers merge into one report")
    func multiProviderMerge() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let first = SpendFetchResult(
            slices: [Self.slice(bucketing, bucketIndex: 13, model: "openai/gpt-5.1", provider: "OpenAI", amount: "1.00")],
            capabilities: Self.capabilities()
        )
        let second = SpendFetchResult(
            slices: [
                Self.slice(
                    bucketing,
                    bucketIndex: 13,
                    model: "anthropic/claude-sonnet-4.5",
                    provider: "Anthropic",
                    amount: "2.00",
                    adapter: "second"
                ),
            ],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(providerID: "openrouter", result: first),
                .init(providerID: "second", result: second),
            ],
            bucketing: bucketing,
            grouping: .provider
        )

        #expect(report.headlineTotal == 3)
        #expect(report.series.count == 2)
        #expect(report.capabilities.count == 2)
    }

    @Test("Tokens and requests are summed for attribution")
    func tokensAndRequests() {
        let bucketing = Bucketing(window: .daily, calendar: Self.calendar(), now: Self.now())
        let result = SpendFetchResult(
            slices: [
                Self.slice(bucketing, bucketIndex: 13, amount: "1.00", tokens: (100, 50), requests: 3),
                Self.slice(bucketing, bucketIndex: 12, amount: "1.00", tokens: (10, 5), requests: 1),
            ],
            capabilities: Self.capabilities()
        )
        let report = SpendAggregator.makeReport(
            contributions: [.init(providerID: "openrouter", result: result)],
            bucketing: bucketing,
            grouping: .model
        )
        #expect(report.promptTokens == 110)
        #expect(report.completionTokens == 55)
        #expect(report.totalTokens == 165)
        #expect(report.requests == 4)
    }

    @Test("Empty input produces an empty but well-formed report")
    func emptyReport() {
        let bucketing = Bucketing(window: .weekly, calendar: Self.calendar(), now: Self.now())
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(slices: [], capabilities: .unavailable)
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
        #expect(report.isEmpty)
        #expect(report.buckets.count == 8)
        #expect(report.series.isEmpty)
        #expect(report.hasBreakdown == false)
    }

    @Test("Model labels strip vendor prefixes and title-case vendors")
    func modelLabelFormatting() {
        #expect(ModelLabel.shortName(for: "anthropic/claude-sonnet-4.5") == "claude-sonnet-4.5")
        #expect(ModelLabel.shortName(for: "gpt-5.1") == "gpt-5.1")
        #expect(ModelLabel.vendor(for: "meta-llama/llama-4") == "Meta")
        #expect(ModelLabel.vendor(for: "x-ai/grok-4") == "xAI")
        #expect(ModelLabel.vendor(for: "unknown-vendor/model") == "Unknown-vendor")
    }
}

@Suite("Breakdown rows")
struct BreakdownRowsTests {
    private static func report() -> SpendReport {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        func slice(bucket: Int, model: String, amount: String) -> SpendSlice {
            let interval = bucketing.displayBuckets[bucket]
            return SpendSlice(
                start: interval.start,
                end: interval.end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: model,
                upstreamProvider: "OpenAI",
                amount: Decimal(string: amount)!
            )
        }

        return SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: [
                            // Model A dominates the window, model B dominates today.
                            slice(bucket: 10, model: "vendor/model-a", amount: "10.00"),
                            slice(bucket: 13, model: "vendor/model-a", amount: "1.00"),
                            slice(bucket: 13, model: "vendor/model-b", amount: "3.00"),
                        ],
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )
    }

    @Test("Current-period rows share the headline's denominator")
    func currentBreakdown() {
        let report = Self.report()
        #expect(report.headlineTotal == 4)
        #expect(report.currentPeriodTotal == 4)
        #expect(report.currentBreakdown.map(\.series.label) == ["model-b", "model-a"])
        #expect(report.currentBreakdown.map(\.amount) == [3, 1])
        #expect(report.currentBreakdown[0].share == 0.75)
        #expect(report.currentBreakdownLabel == "today")
    }

    @Test("Window rows rank by window total and keep the chart's colour index")
    func windowBreakdown() {
        let report = Self.report()
        #expect(report.windowBreakdown.map(\.series.label) == ["model-a", "model-b"])
        #expect(report.windowBreakdown.map(\.amount) == [11, 3])
        // model-a ranks first across the window, so it keeps colour slot 0
        // even though it is listed second for today.
        #expect(report.windowBreakdown[0].colorIndex == 0)
        #expect(report.currentBreakdown.first { $0.series.label == "model-a" }?.colorIndex == 0)
        #expect(report.currentBreakdown.first { $0.series.label == "model-b" }?.colorIndex == 1)
    }

    @Test("Zero denominators produce nil shares rather than NaN")
    func zeroDenominator() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: Date())
        let report = SpendAggregator.makeReport(
            contributions: [
                .init(providerID: "openrouter", result: SpendFetchResult(slices: [], capabilities: .unavailable)),
            ],
            bucketing: bucketing,
            grouping: .model
        )
        #expect(report.currentBreakdown.isEmpty)
        #expect(report.currentPeriodTotal == 0)
    }
}

@Suite("Period-scoped counters")
struct PeriodCounterTests {
    @Test("Token and request counts reported alongside the headline cover the in-progress period only")
    func currentPeriodCounters() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)

        func slice(bucket: Int, tokens: (Int, Int), requests: Int) -> SpendSlice {
            let interval = bucketing.displayBuckets[bucket]
            return SpendSlice(
                start: interval.start,
                end: interval.end,
                providerID: "openrouter",
                providerName: "OpenRouter",
                model: "openai/gpt-5.1",
                upstreamProvider: "OpenAI",
                amount: 1,
                promptTokens: tokens.0,
                completionTokens: tokens.1,
                requests: requests
            )
        }

        let report = SpendAggregator.makeReport(
            contributions: [
                .init(
                    providerID: "openrouter",
                    result: SpendFetchResult(
                        slices: [
                            slice(bucket: 12, tokens: (900, 100), requests: 9),
                            slice(bucket: 13, tokens: (40, 10), requests: 2),
                        ],
                        capabilities: ProviderCapabilities(hasModelBreakdown: true)
                    )
                ),
            ],
            bucketing: bucketing,
            grouping: .model
        )

        // Window-wide totals remain available for other uses.
        #expect(report.totalTokens == 1050)
        #expect(report.requests == 11)
        // But the headline row must describe today, not the whole window.
        #expect(report.currentTokens == 50)
        #expect(report.currentPromptTokens == 40)
        #expect(report.currentRequests == 2)
        #expect(report.currentPeriodTotal == 1)
    }
}
