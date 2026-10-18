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
        let calendar = Self.calendar()
        let bucketing = Bucketing(window: .daily, calendar: calendar, now: Date())
        let request = SpendRequest(bucketing: bucketing)
        #expect(OpenRouterProvider.serverGranularity(for: request, schema: Self.schema) == "hour")

        let monthly = SpendRequest(bucketing: Bucketing(window: .monthly, calendar: calendar, now: Date()))
        #expect(OpenRouterProvider.serverGranularity(for: monthly, schema: Self.schema) == "day")

        let coarse = OpenRouterClient.Schema(
            spendMetric: "total_usage",
            tokenMetrics: .init(total: nil, prompt: nil, completion: nil),
            requestMetric: nil,
            dimensions: ["model"],
            granularities: ["day"]
        )
        #expect(OpenRouterProvider.serverGranularity(for: request, schema: coarse) == "day")
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
