import Foundation

/// Thin, typed wrapper around the OpenRouter endpoints that expose spend.
///
/// Relevant surface (all under `https://openrouter.ai/api/v1`):
/// - `GET  /key`              key-scoped totals for the current UTC day/week/month
/// - `GET  /credits`          account credit balance (management key)
/// - `GET  /analytics/meta`   which metrics, dimensions, granularities exist now
/// - `POST /analytics/query`  arbitrary metric x dimension x granularity queries
///
/// The analytics endpoints require a management key; a normal inference key gets
/// a 403. That asymmetry is why capabilities are account-dependent.
struct OpenRouterClient: Sendable {
    struct KeyInfo: Decodable, Sendable {
        var label: String?
        var usage: Decimal?
        var usageDaily: Decimal?
        var usageWeekly: Decimal?
        var usageMonthly: Decimal?
        var limit: Decimal?
        var limitRemaining: Decimal?
        var isFreeTier: Bool?
        var isManagementKey: Bool?

        enum CodingKeys: String, CodingKey {
            case label, usage, limit
            case usageDaily = "usage_daily"
            case usageWeekly = "usage_weekly"
            case usageMonthly = "usage_monthly"
            case limitRemaining = "limit_remaining"
            case isFreeTier = "is_free_tier"
            case isManagementKey = "is_management_key"
        }
    }

    struct Credits: Decodable, Sendable {
        var totalCredits: Decimal?
        var totalUsage: Decimal?

        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }

    struct Schema: Sendable {
        struct TokenMetrics: Sendable {
            var total: String?
            var prompt: String?
            var completion: String?
        }

        var spendMetric: String
        var tokenMetrics: TokenMetrics
        var requestMetric: String?
        var dimensions: Set<String>
        var granularities: Set<String>
    }

    /// One analytics query. Bundled into a struct so the call site stays
    /// readable as the parameter list grows.
    struct Query: Sendable {
        var spendMetric: String
        var extraMetrics: [String]
        var dimensions: [String]
        var granularity: String
        var range: DateInterval
        var limit: Int
    }

    private struct KeyEnvelope: Decodable { var data: KeyInfo }
    private struct CreditsEnvelope: Decodable { var data: Credits }

    private static let baseURL = URL(string: "https://openrouter.ai/api/v1")!

    let apiKey: String
    let http: JSONHTTPClient

    init(apiKey: String) {
        self.apiKey = apiKey
        http = JSONHTTPClient(baseURL: Self.baseURL)
    }

    func keyInfo() async throws -> KeyInfo {
        let data = try await http.get("/key", bearer: apiKey)
        do {
            return try JSONDecoder().decode(KeyEnvelope.self, from: data).data
        } catch {
            throw SpendProviderError.decoding("Could not read key information: \(error.localizedDescription)")
        }
    }

    func credits() async throws -> Credits {
        let data = try await http.get("/credits", bearer: apiKey)
        do {
            return try JSONDecoder().decode(CreditsEnvelope.self, from: data).data
        } catch {
            throw SpendProviderError.decoding("Could not read credits: \(error.localizedDescription)")
        }
    }

    /// Discovers what the analytics endpoint accepts right now. Metrics and
    /// dimensions are documented as evolving, so names are resolved at runtime
    /// instead of being hard-coded.
    func schema() async throws -> Schema {
        let data = try await http.get("/analytics/meta", bearer: apiKey)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any]
        else {
            throw SpendProviderError.decoding("Analytics metadata was not an object")
        }

        let metrics = (payload["metrics"] as? [[String: Any]]) ?? []
        let dimensions = (payload["dimensions"] as? [[String: Any]]) ?? []
        let granularities = (payload["granularities"] as? [[String: Any]]) ?? []

        var spendMetric: String?
        var currencyFallback: String?
        var totalTokens: String?
        var promptTokens: String?
        var completionTokens: String?
        var requestMetric: String?

        for metric in metrics {
            guard let name = FlexibleJSON.string(metric["name"]) else { continue }
            let format = FlexibleJSON.string(metric["display_format"]) ?? "number"
            let lower = name.lowercased()

            if lower == "total_usage" || lower == "usage" || lower == "total_cost" || lower == "cost" {
                spendMetric = spendMetric ?? name
            } else if format == "currency", lower.contains("usage") || lower.contains("cost"), currencyFallback == nil {
                currencyFallback = name
            }

            switch lower {
            case "tokens_total", "total_tokens": totalTokens = totalTokens ?? name
            case "tokens_prompt", "prompt_tokens": promptTokens = promptTokens ?? name
            case "tokens_completion", "completion_tokens": completionTokens = completionTokens ?? name
            case "request_count", "requests": requestMetric = requestMetric ?? name
            default: break
            }
        }

        return Schema(
            spendMetric: spendMetric ?? currencyFallback ?? "total_usage",
            tokenMetrics: Schema.TokenMetrics(total: totalTokens, prompt: promptTokens, completion: completionTokens),
            requestMetric: requestMetric,
            dimensions: Set(dimensions.compactMap { FlexibleJSON.string($0["name"]) }),
            granularities: Set(granularities.compactMap { FlexibleJSON.string($0["name"]) })
        )
    }

    /// Runs an analytics query and returns the raw rows. Row keys are dynamic
    /// (`total_usage`, `model`, `date__hour`, ...) so parsing is left to the
    /// caller.
    func query(_ query: Query) async throws -> (rows: [[String: Any]], truncated: Bool) {
        var body: [String: Any] = [
            "metrics": [query.spendMetric] + query.extraMetrics,
            "time_range": [
                "start": FlexibleDate.iso8601(query.range.start),
                "end": FlexibleDate.iso8601(query.range.end),
            ],
            "granularity": query.granularity,
            "limit": query.limit,
        ]
        if !query.dimensions.isEmpty {
            body["dimensions"] = query.dimensions
        }

        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await http.post("/analytics/query", body: payload, bearer: apiKey)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpendProviderError.decoding("Analytics response was not an object")
        }
        guard let payloadObject = root["data"] as? [String: Any] else {
            throw SpendProviderError.decoding("Analytics response had no data envelope")
        }
        let rows = (payloadObject["data"] as? [[String: Any]]) ?? []
        let metadata = payloadObject["metadata"] as? [String: Any]
        let truncated = FlexibleJSON.bool(metadata?["truncated"]) ?? false
        return (rows, truncated)
    }
}
