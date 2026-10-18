import Foundation

/// OpenRouter adapter.
///
/// Two credential tiers yield very different data:
///
/// - **Management key** — the analytics API answers arbitrary metric × dimension
///   × granularity queries, so we get account-wide spend with per-model and
///   per-upstream-provider attribution at hourly resolution.
/// - **Inference key** — only `/key` is readable, which reports this key's own
///   running totals for the current UTC day/week/month. No history, no
///   breakdown, so the chart collapses to the current period and the UI gates
///   windows accordingly.
public struct OpenRouterProvider: SpendProvider {
    public static let providerID: ProviderID = "openrouter"

    public static let descriptor = ProviderDescriptor(
        id: OpenRouterProvider.providerID,
        displayName: "OpenRouter",
        summary: "Account spend via the analytics API, with per-model and per-provider breakdown.",
        credentialLabel: "Management key",
        credentialPlaceholder: "sk-or-v1-…",
        credentialURL: URL(string: "https://openrouter.ai/settings/management-keys"),
        documentationURL: URL(string: "https://openrouter.ai/docs/guides/features/activity"),
        upgradeHint: """
        A normal inference key also works, but only exposes this key's own totals for the current \
        day, week, and month — no history and no model breakdown. Create a management key for the \
        full view.
        """
    )

    /// Ceiling on returned analytics rows. Personal usage sits far below this;
    /// if it is ever hit, the response is flagged truncated and we retry coarser.
    private static let rowLimit = 20_000

    private let apiKey: String
    private let client: OpenRouterClient

    public init(apiKey: String) {
        self.apiKey = apiKey
        client = OpenRouterClient(apiKey: apiKey)
    }

    public var descriptor: ProviderDescriptor {
        Self.descriptor
    }

    // MARK: - Probe

    public func probe() async throws -> ProviderCapabilities {
        let keyInfo = try await client.keyInfo()
        guard keyInfo.isManagementKey == true else {
            return Self.inferenceKeyCapabilities
        }
        let schema = try await client.schema()
        return Self.managementCapabilities(for: schema)
    }

    // MARK: - Fetch

    public func fetchSpend(_ request: SpendRequest) async throws -> SpendFetchResult {
        let keyInfo = try await client.keyInfo()
        guard keyInfo.isManagementKey == true else {
            return try Self.keyTotalsResult(request: request, keyInfo: keyInfo)
        }

        let schema: OpenRouterClient.Schema
        do {
            schema = try await client.schema()
        } catch {
            // Metadata is only needed to name metrics and dimensions. If it is
            // unavailable the documented defaults usually still work.
            throw error
        }

        var result = try await analyticsResult(request: request, schema: schema)
        result.account = await accountInfo(from: keyInfo)
        return result
    }

    // MARK: - Management-key path

    private func analyticsResult(
        request: SpendRequest,
        schema: OpenRouterClient.Schema
    ) async throws -> SpendFetchResult {
        let dimensions = Self.dimensions(for: schema)
        let granularity = Self.serverGranularity(for: request, schema: schema)

        var extraMetrics: [String] = []
        if let metric = schema.requestMetric {
            extraMetrics.append(metric)
        }
        if let metric = schema.tokenMetrics.prompt {
            extraMetrics.append(metric)
        }
        if let metric = schema.tokenMetrics.completion {
            extraMetrics.append(metric)
        }

        var warnings: [String] = []
        var rows: [[String: Any]]
        var usedGranularity = granularity
        var truncated: Bool

        (rows, truncated) = try await client.query(
            OpenRouterClient.Query(
                spendMetric: schema.spendMetric,
                extraMetrics: extraMetrics,
                dimensions: dimensions,
                granularity: granularity,
                range: request.range,
                limit: Self.rowLimit
            )
        )

        // A truncated result loses whole time buckets, so prefer a coarser
        // granularity over silently under-reporting.
        if truncated, granularity == "hour", request.window != .hourly {
            usedGranularity = "day"
            (rows, truncated) = try await client.query(
                OpenRouterClient.Query(
                    spendMetric: schema.spendMetric,
                    extraMetrics: extraMetrics,
                    dimensions: dimensions,
                    granularity: usedGranularity,
                    range: request.range,
                    limit: Self.rowLimit
                )
            )
            warnings.append("Hourly detail exceeded the API row limit; showing daily resolution.")
        }
        if truncated {
            warnings.append("Results were truncated by the API; totals may be incomplete.")
        }

        let slices = Self.slices(
            from: rows,
            granularity: usedGranularity,
            dimensions: dimensions,
            schema: schema
        )
        if slices.isEmpty {
            warnings.append("No activity returned for the selected range.")
        }

        var capabilities = Self.managementCapabilities(for: schema)
        capabilities.nativeGranularity = usedGranularity == "hour" ? .hourly : .daily

        return SpendFetchResult(
            slices: slices,
            capabilities: capabilities,
            periodTotals: [:],
            warnings: warnings
        )
    }

    /// Maps analytics rows to slices. Rows look like:
    /// `{"date__hour": "2026-02-11T04:00:00.000Z", "model": "openai/gpt-5.1",
    ///   "provider": "OpenAI", "total_usage": 0.0123, "request_count": "4"}`
    static func slices(
        from rows: [[String: Any]],
        granularity: String,
        dimensions: [String],
        schema: OpenRouterClient.Schema
    ) -> [SpendSlice] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let component: Calendar.Component = switch granularity {
        case "minute": .minute
        case "hour": .hour
        case "week": .weekOfYear
        case "month": .month
        default: .day
        }

        let tracksModel = dimensions.contains("model")
        let tracksProvider = dimensions.contains("provider")

        return rows.compactMap { row -> SpendSlice? in
            guard let timeEntry = FlexibleJSON.timeBucket(in: row),
                  let start = FlexibleDate.parse(timeEntry.value) else { return nil }
            let amount = FlexibleJSON.decimal(row[schema.spendMetric]) ?? 0

            let prompt = schema.tokenMetrics.prompt.flatMap { FlexibleJSON.int(row[$0]) } ?? 0
            let completion = schema.tokenMetrics.completion.flatMap { FlexibleJSON.int(row[$0]) } ?? 0
            let requests = schema.requestMetric.flatMap { FlexibleJSON.int(row[$0]) } ?? 0

            if amount == 0, prompt == 0, completion == 0, requests == 0 {
                return nil
            }

            let end = Bucketing.bucketEnd(
                for: start,
                window: SpendWindow.allCases.first { $0.bucketComponent == component } ?? .daily,
                calendar: calendar
            )

            return SpendSlice(
                start: start,
                end: end,
                providerID: Self.providerID,
                providerName: Self.descriptor.displayName,
                model: tracksModel ? FlexibleJSON.string(row["model"]) : nil,
                upstreamProvider: tracksProvider ? FlexibleJSON.string(row["provider"]) : nil,
                amount: amount,
                promptTokens: prompt,
                completionTokens: completion,
                requests: requests
            )
        }
    }

    // MARK: - Inference-key path

    /// `/key` reports this key's own totals for the current UTC period. Emit one
    /// slice for the in-progress bucket so the chart shows something truthful,
    /// and hand the exact period totals to the headline figure.
    static func keyTotalsResult(request: SpendRequest, keyInfo: OpenRouterClient.KeyInfo) throws -> SpendFetchResult {
        var capabilities = inferenceKeyCapabilities
        // Hourly is not reportable from period totals.
        capabilities.windows.remove(.hourly)

        var totals: [SpendWindow: Decimal] = [:]
        if let value = keyInfo.usageDaily {
            totals[.daily] = value
        }
        if let value = keyInfo.usageWeekly {
            totals[.weekly] = value
        }
        if let value = keyInfo.usageMonthly {
            totals[.monthly] = value
        }

        var slices: [SpendSlice] = []
        var warnings: [String] = []

        if capabilities.supports(request.window) {
            if let amount = totals[request.window], amount > 0 {
                // Anchor at "now" so the slice always lands in the current bucket
                // of the window being displayed.
                let start = request.range.end.addingTimeInterval(-1)
                slices.append(
                    SpendSlice(
                        start: start,
                        end: request.range.end,
                        providerID: providerID,
                        providerName: descriptor.displayName,
                        model: nil,
                        upstreamProvider: nil,
                        amount: amount
                    )
                )
            }
        } else {
            // Reporting a day total inside an hour bucket would misrepresent it,
            // so report nothing and let the app pick a supported window.
            warnings.append("\(request.window.title) spend requires a management key.")
        }

        return SpendFetchResult(
            slices: slices,
            capabilities: capabilities,
            periodTotals: totals,
            warnings: warnings
        )
    }

    // MARK: - Account info

    private func accountInfo(from keyInfo: OpenRouterClient.KeyInfo) async -> ProviderAccountInfo {
        var info = ProviderAccountInfo(
            credentialLabel: keyInfo.isManagementKey == true ? "Management key" : "Inference key",
            keyLabel: keyInfo.label,
            isManagementCredential: keyInfo.isManagementKey
        )
        if let credits = try? await client.credits() {
            if let total = credits.totalCredits, let used = credits.totalUsage {
                info.remainingCredit = total - used
                info.purchasedCredit = total
            }
        }
        if info.remainingCredit == nil, let remaining = keyInfo.limitRemaining {
            info.remainingCredit = remaining
        }
        return info
    }

    // MARK: - Capabilities

    static let inferenceKeyCapabilities = ProviderCapabilities(
        windows: [.daily, .weekly, .monthly],
        hasModelBreakdown: false,
        hasProviderBreakdown: false,
        nativeGranularity: .daily,
        notes: [
            "This is an inference key: only this key's own totals for the current day, week, and month are readable.",
            "Create a management key to unlock account-wide history and per-model breakdown.",
        ]
    )

    static func managementCapabilities(for schema: OpenRouterClient.Schema) -> ProviderCapabilities {
        var windows: Set<SpendWindow> = [.monthly, .weekly]
        if schema.granularities.contains("day") {
            windows.formUnion([.daily])
        }
        if schema.granularities.contains("hour") {
            windows.insert(.hourly)
        }
        return ProviderCapabilities(
            windows: windows,
            hasModelBreakdown: schema.dimensions.contains("model"),
            hasProviderBreakdown: schema.dimensions.contains("provider"),
            nativeGranularity: schema.granularities.contains("hour") ? .hourly : .daily,
            notes: []
        )
    }

    /// Prefers model and upstream provider. The query endpoint accepts at most
    /// two dimensions, and both are also usable as filters.
    static func dimensions(for schema: OpenRouterClient.Schema) -> [String] {
        var chosen: [String] = []
        for candidate in ["model", "provider"] where schema.dimensions.contains(candidate) {
            chosen.append(candidate)
        }
        return Array(chosen.prefix(2))
    }

    /// Picks the finest sensible server-side bucket.
    ///
    /// Hourly and daily windows need hour resolution because the app re-buckets
    /// into the user's time zone: a UTC day boundary does not line up with a
    /// local day boundary. Weekly and monthly windows span far too many hours for
    /// that, so they use day resolution and accept a sub-day boundary skew.
    static func serverGranularity(for request: SpendRequest, schema: OpenRouterClient.Schema) -> String {
        switch request.window {
        case .hourly, .daily:
            schema.granularities.contains("hour") ? "hour" : "day"
        case .weekly, .monthly:
            schema.granularities.contains("day") ? "day" : "week"
        }
    }
}
