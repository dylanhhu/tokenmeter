import Foundation
import Testing
@testable import TokenMeterKit

@Suite("OpenRouter adapter")
struct OpenRouterTests {
    private static let schema = OpenRouterClient.Schema(
        spendMetric: "total_usage",
        tokenMetrics: .init(total: "tokens_total", prompt: "tokens_prompt", completion: "tokens_completion"),
        requestMetric: "request_count",
        dimensions: ["model", "provider", "api_key_id"],
        granularities: ["minute", "hour", "day", "week", "month"]
    )

    private static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("Analytics rows map to slices, tolerating string-encoded numbers")
    func rowParsing() {
        let rows: [[String: Any]] = [
            [
                "date__hour": "2026-02-11T04:00:00.000Z",
                "model": "openai/gpt-5.1",
                "provider": "OpenAI",
                "total_usage": 0.0123,
                "tokens_prompt": "1200",
                "tokens_completion": 300,
                "request_count": "4",
            ],
            [
                "date__hour": "2026-02-11T04:00:00.000Z",
                "model": "anthropic/claude-sonnet-4.5",
                "provider": "Anthropic",
                "total_usage": "0.5",
                "tokens_prompt": 10,
                "tokens_completion": 10,
                "request_count": 1,
            ],
        ]

        let slices = OpenRouterProvider.slices(from: rows, granularity: "hour", dimensions: ["model", "provider"], schema: Self.schema)

        #expect(slices.count == 2)
        let first = slices[0]
        #expect(first.model == "openai/gpt-5.1")
        #expect(first.upstreamProvider == "OpenAI")
        #expect(first.amount == Decimal(string: "0.0123"))
        #expect(first.promptTokens == 1200)
        #expect(first.completionTokens == 300)
        #expect(first.requests == 4)
        #expect(first.end.timeIntervalSince(first.start) == 3600)
        #expect(slices[1].amount == Decimal(string: "0.5"))
    }

    @Test("Time bucket columns are discovered regardless of prefix")
    func timeColumnVariants() {
        let row: [String: Any] = ["created_at__day": "2026-02-11T00:00:00Z", "total_usage": 1.0]
        let slices = OpenRouterProvider.slices(from: [row], granularity: "day", dimensions: [], schema: Self.schema)
        #expect(slices.count == 1)
        #expect(slices[0].model == nil)
        #expect(slices[0].upstreamProvider == nil)
        #expect(slices[0].end.timeIntervalSince(slices[0].start) == 86_400)
    }

    @Test("Rows without a usable timestamp are skipped, not zero-filled")
    func invalidRowsSkipped() {
        let rows: [[String: Any]] = [
            ["total_usage": 5.0],
            ["date__day": "not-a-date", "total_usage": 2.0],
        ]
        let slices = OpenRouterProvider.slices(from: rows, granularity: "day", dimensions: [], schema: Self.schema)
        #expect(slices.isEmpty)
    }

    @Test("All-zero rows are dropped")
    func zeroRowsDropped() {
        let rows: [[String: Any]] = [["date__day": "2026-02-11T00:00:00Z", "total_usage": 0, "request_count": "0"]]
        #expect(OpenRouterProvider.slices(from: rows, granularity: "day", dimensions: [], schema: Self.schema).isEmpty)
    }

    @Test("Model attribution is dropped when the query did not group by model")
    func attributionRespectsDimensions() {
        let rows: [[String: Any]] = [["date__day": "2026-02-11T00:00:00Z", "total_usage": 1.0, "model": "openai/gpt-5.1"]]
        let slices = OpenRouterProvider.slices(from: rows, granularity: "day", dimensions: [], schema: Self.schema)
        #expect(slices[0].model == nil)
    }

    @Test("Server granularity is fine enough to re-bucket local days")
    func granularityChoice() {
        #expect(OpenRouterProvider.serverGranularity(for: .daily, schema: Self.schema) == "hour")
        #expect(OpenRouterProvider.serverGranularity(for: .monthly, schema: Self.schema) == "day")

        let coarse = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: ["model"],
            granularities: ["day"]
        )
        #expect(OpenRouterProvider.serverGranularity(for: .daily, schema: coarse) == "day")
    }

    @Test("Minute rows map to one-minute slices")
    func minuteRows() {
        let rows: [[String: Any]] = [
            [
                "date__minute": "2026-02-11T04:31:00Z",
                "model": "openai/gpt-5.1",
                "total_usage": 0.02,
            ],
        ]
        let slices = OpenRouterProvider.slices(from: rows, granularity: "minute", dimensions: ["model"], schema: Self.schema)
        #expect(slices.count == 1)
        #expect(slices[0].end.timeIntervalSince(slices[0].start) == 60)
    }

    @Test("A rolling headline refines only the buckets its boundaries fall in")
    func rollingQueryPlan() throws {
        let calendar = Self.calendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 25)))
        let bucketing = Bucketing(window: .hourly, scope: .trailing, calendar: calendar, now: now)
        let request = SpendRequest(bucketing: bucketing)

        // The headline runs 08:26–09:26 and its comparison period 07:26–08:26,
        // so the 07:00 and 08:00 clock hours need minute rows and everything else
        // stays hourly.
        let plan = OpenRouterProvider.queryPlan(for: request, coarse: "hour", schema: Self.schema)
        let fine = plan.filter { $0.granularity == "minute" }
        #expect(fine.count == 1)
        #expect(fine.first?.range.start == calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 7)))
        // Adjacent boundary buckets merge into one contiguous minute segment.
        #expect(fine.first?.range.end == calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)))

        // The segments partition the fetch range: no gap, no overlap, so no bucket
        // is dropped or counted twice.
        #expect(plan.first?.range.start == request.range.start)
        #expect(plan.last?.range.end == request.range.end)
        for (previous, next) in zip(plan, plan.dropFirst()) {
            #expect(previous.range.end == next.range.start)
        }

        // Calendar headlines already line up with the buckets.
        let calendarRequest = SpendRequest(bucketing: Bucketing(window: .hourly, calendar: calendar, now: now))
        #expect(OpenRouterProvider.queryPlan(for: calendarRequest, coarse: "hour", schema: Self.schema).count == 1)

        let hourOnly = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: ["model"],
            granularities: ["hour", "day"]
        )
        // Without minute rows the rolling boundary cannot be resolved, so neither
        // the plan nor the capability may claim it.
        #expect(OpenRouterProvider.queryPlan(for: request, coarse: "hour", schema: hourOnly).count == 1)
        #expect(!OpenRouterProvider.managementCapabilities(for: hourOnly).supports(.hourly))
        #expect(!OpenRouterProvider.managementCapabilities(for: hourOnly).supports(.hourly, scope: .trailing))
    }

    @Test("Rolling weekly and monthly headlines refine one day at a time")
    func rollingPlanForLongWindows() throws {
        let calendar = Self.calendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 25)))

        for window in [SpendWindow.weekly, .monthly] {
            let request = SpendRequest(bucketing: Bucketing(window: window, scope: .trailing, calendar: calendar, now: now))
            let plan = OpenRouterProvider.queryPlan(for: request, coarse: "day", schema: Self.schema)

            // Day rows cover the history; only the days the boundaries fall in are
            // refetched hourly, which keeps the request count and row count flat.
            let fine = plan.filter { $0.granularity == "hour" }
            #expect(fine.isEmpty == false)
            #expect(fine.allSatisfy { $0.range.duration <= 86_400 })
            #expect(plan.first?.range.start == request.range.start)
            #expect(plan.last?.range.end == request.range.end)
            for (previous, next) in zip(plan, plan.dropFirst()) {
                #expect(previous.range.end == next.range.start)
            }
        }
    }

    @Test("Rolling capability follows the granularity needed at the boundary")
    func rollingCapabilities() {
        let full = OpenRouterProvider.managementCapabilities(for: Self.schema)
        #expect(full.rollingWindows == Set(SpendWindow.allCases))

        // Day rows and coarser: no rolling boundary can be resolved, so the
        // calendar readings stay available and the rolling ones do not.
        let dayOnly = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: ["model"],
            granularities: ["day", "week", "month"]
        )
        let dayCapabilities = OpenRouterProvider.managementCapabilities(for: dayOnly)
        #expect(dayCapabilities.supports(.daily))
        #expect(dayCapabilities.rollingWindows.isEmpty)

        // `/key` reports calendar totals only.
        #expect(OpenRouterProvider.inferenceKeyCapabilities.supports(.daily))
        #expect(OpenRouterProvider.inferenceKeyCapabilities.rollingWindows.isEmpty)
    }

    @Test("Dimensions prefer model then provider, capped at two")
    func dimensionSelection() {
        #expect(OpenRouterProvider.dimensions(for: Self.schema) == ["model", "provider"])

        let providerOnly = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: ["provider"],
            granularities: ["day"]
        )
        #expect(OpenRouterProvider.dimensions(for: providerOnly) == ["provider"])

        let none = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: [],
            granularities: ["day"]
        )
        #expect(OpenRouterProvider.dimensions(for: none).isEmpty)
    }

    @Test("A management key advertises every window and both dimensions")
    func managementCapabilities() {
        let capabilities = OpenRouterProvider.managementCapabilities(for: Self.schema)
        #expect(capabilities.supports(.hourly))
        #expect(capabilities.supports(.daily))
        #expect(capabilities.hasModelBreakdown)
        #expect(capabilities.hasProviderBreakdown)
        #expect(capabilities.notes.isEmpty)
    }

    @Test("An inference key advertises no hourly window and no breakdown")
    func inferenceCapabilities() {
        let capabilities = OpenRouterProvider.inferenceKeyCapabilities
        #expect(!capabilities.supports(.hourly))
        #expect(capabilities.supports(.daily))
        #expect(!capabilities.hasBreakdown)
        #expect(!capabilities.notes.isEmpty)
    }

    @Test("Inference-key fallback anchors a slice in the current bucket and reports exact totals")
    func inferenceKeyResult() throws {
        let calendar = Self.calendar()
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)))
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: now)
        let request = SpendRequest(bucketing: bucketing)
        let keyInfo = OpenRouterClient.KeyInfo(
            label: "sk-or-v1-…abcd",
            usage: 100,
            usageDaily: Decimal(string: "1.75"),
            usageWeekly: Decimal(string: "9.10"),
            usageMonthly: Decimal(string: "42.00"),
            limit: nil,
            limitRemaining: Decimal(string: "58.00"),
            isFreeTier: false,
            isManagementKey: false
        )

        let result = try OpenRouterProvider.keyTotalsResult(request: request, keyInfo: keyInfo)

        #expect(result.slices.count == 1)
        #expect(result.slices[0].amount == Decimal(string: "1.75"))
        #expect(bucketing.bucketIndex(for: result.slices[0].start) == bucketing.displayBuckets.count - 1)
        #expect(result.periodTotals[.daily] == Decimal(string: "1.75"))
        #expect(result.periodTotals[.weekly] == Decimal(string: "9.10"))
        #expect(result.periodTotals[.monthly] == Decimal(string: "42.00"))
        #expect(result.capabilities.hasBreakdown == false)
    }

    @Test("Hourly request from an inference key reports no slices and a warning")
    func inferenceKeyHourlyDegrades() throws {
        let bucketing = Bucketing(window: .hourly, calendar: Self.calendar(), now: Date())
        let keyInfo = OpenRouterClient.KeyInfo(
            label: nil,
            usage: nil,
            usageDaily: Decimal(string: "0.20"),
            usageWeekly: nil,
            usageMonthly: nil,
            limit: nil,
            limitRemaining: nil,
            isFreeTier: nil,
            isManagementKey: false
        )
        let result = try OpenRouterProvider.keyTotalsResult(request: SpendRequest(bucketing: bucketing), keyInfo: keyInfo)

        // A day total must not be placed inside an hour bucket.
        #expect(result.slices.isEmpty)
        #expect(result.warnings.isEmpty == false)
        #expect(result.periodTotals[.daily] == Decimal(string: "0.20"))
        #expect(result.capabilities.supports(.hourly) == false)
    }

    @Test("Analytics row limit stays inside the endpoint's accepted range")
    func rowLimitWithinAPICeiling() {
        // OpenRouter rejects a query whose `limit` exceeds 10,000 with
        // "Request rejected: limit: too big", which surfaces as a banner.
        #expect(OpenRouterProvider.rowLimit <= 10_000)
        #expect(OpenRouterProvider.rowLimit > 0)
    }

    @Test("Long windows are split into segments the endpoint will accept")
    func longRangesAreSegmented() {
        // The API rejects a `time_range` wider than 31 days for hour granularity
        // and for generations-only dimensions such as `provider`, which every
        // management-key query asks for. Weekly and monthly windows exceed that
        // as soon as the prior comparison period is included.
        let limit = TimeInterval(OpenRouterProvider.maxDaysPerQuery) * 86_400
        #expect(limit < 31 * 86_400)

        for window in SpendWindow.allCases {
            let bucketing = Bucketing(window: window, timeZoneMode: .local, now: Date())
            let range = bucketing.fetchRange
            let segments = OpenRouterProvider.querySegments(for: range)

            #expect(segments.isEmpty == false)
            #expect(segments.first?.start == range.start)
            #expect(segments.last?.end == range.end)
            for (index, segment) in segments.enumerated() {
                #expect(segment.duration > 0)
                #expect(segment.duration <= limit)
                if index > 0 {
                    #expect(segment.start == segments[index - 1].end)
                }
            }
        }
    }

    @Test("Daily-range fetches still fit in a single request")
    func dailyWindowIsOneRequest() {
        let bucketing = Bucketing(window: .daily, timeZoneMode: .local, now: Date())
        #expect(OpenRouterProvider.querySegments(for: bucketing.fetchRange).count == 1)
    }

    @Test("Segments cut on UTC midnights so day buckets are not split")
    func segmentCutsLandOnUTCMidnight() {
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let range = DateInterval(start: start.addingTimeInterval(3_600), duration: 100 * 86_400)
        let segments = OpenRouterProvider.querySegments(for: range)
        for segment in segments.dropLast() {
            #expect(segment.end.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0)
        }
    }

    @Test("A bucket reported twice is folded into one slice")
    func duplicateSlicesAreMerged() throws {
        let quarter = try #require(Decimal(string: "0.25"))
        let threeQuarters = try #require(Decimal(string: "0.75"))
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let first = SpendSlice(
            start: start,
            end: start.addingTimeInterval(86_400),
            providerID: OpenRouterProvider.providerID,
            providerName: "OpenRouter",
            model: "openai/gpt-5.1",
            upstreamProvider: "OpenAI",
            amount: quarter,
            promptTokens: 10,
            completionTokens: 5,
            requests: 2
        )
        var second = first
        second.amount = threeQuarters
        second.promptTokens = 1

        let merged = OpenRouterProvider.merged([first, second])
        #expect(merged.count == 1)
        #expect(merged[0].amount == 1)
        #expect(merged[0].promptTokens == 11)
        #expect(merged[0].requests == 4)
    }

    @Test("An empty chart explains itself instead of reporting a clean zero")
    func reconciliationWarning() {
        #expect(OpenRouterProvider.rowReconciliationWarning(rowCount: 0, sliceCount: 0)?.contains("No activity") == true)
        #expect(
            OpenRouterProvider.rowReconciliationWarning(rowCount: 12, sliceCount: 0)?.contains("12 rows") == true
        )
        #expect(OpenRouterProvider.rowReconciliationWarning(rowCount: 12, sliceCount: 3) == nil)
    }

    @Test("Key info decodes OpenRouter's snake_case payload")
    func keyInfoDecoding() throws {
        let json = """
        {"data":{"label":"prod","usage":12.5,"usage_daily":0.42,"usage_weekly":3.1,
        "usage_monthly":12.5,"limit":100,"limit_remaining":87.5,"is_free_tier":false,
        "is_management_key":true}}
        """
        let envelope = try JSONDecoder().decode(OpenRouterClient.KeyEnvelopeProxy.self, from: Data(json.utf8))
        #expect(envelope.data.isManagementKey == true)
        #expect(envelope.data.usageDaily == Decimal(string: "0.42"))
        #expect(envelope.data.limitRemaining == Decimal(string: "87.5"))
    }
}

/// Test-only mirror of the client's private envelope so decoding can be checked
/// without exposing the type publicly.
extension OpenRouterClient {
    struct KeyEnvelopeProxy: Decodable {
        var data: KeyInfo
    }
}
