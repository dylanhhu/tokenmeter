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

    /// Ceiling on returned analytics rows.
    ///
    /// The analytics endpoint rejects a `limit` above 10,000 with a validation
    /// error ("limit: too big"), so this must not exceed the documented maximum.
    /// The server raises the effective limit on its own for time-series queries
    /// that carry dimensions, so a time bucket is never dropped for lack of
    /// rows; if a response still comes back flagged truncated we retry coarser.
    static let rowLimit = 10_000

    /// Longest time range the analytics endpoint accepts in one request.
    ///
    /// The server resolves a per-query cap from the requested metrics and
    /// dimensions. Minute/hour granularity and generations-only dimensions such
    /// as `provider` are capped at 31 days; going over is a hard 400. Weekly and
    /// monthly windows span months once the prior comparison period is
    /// included, so the range is issued as several segments.
    static let maxDaysPerQuery = 30

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
        var chunks: [(rows: [[String: Any]], granularity: String)] = []
        var truncated = false

        // The coarse query covers everything before the trailing clock hours; the
        // fine query covers those at minute resolution so the trailing-hour
        // boundary can be resolved.
        let split = Self.minuteRefinementStart(for: request, schema: schema)
        let plan: [(range: DateInterval, granularity: String)] = if let split {
            [
                (DateInterval(start: request.range.start, end: split), granularity),
                (DateInterval(start: split, end: request.range.end), "minute"),
            ]
        } else {
            [(request.range, granularity)]
        }
        for step in plan where step.range.duration > 0 {
            let page = try await rows(
                segments: Self.querySegments(for: step.range),
                granularity: step.granularity,
                spendMetric: schema.spendMetric,
                extraMetrics: extraMetrics,
                dimensions: dimensions
            )
            chunks.append((page.rows, step.granularity))
            truncated = truncated || page.truncated
            if page.truncated, step.granularity == "minute" {
                warnings.append("Minute detail for the last hour was truncated; the last-hour figure may be incomplete.")
            }
        }

        // A truncated result loses whole time buckets, so prefer a coarser
        // granularity over silently under-reporting.
        if truncated, granularity == "hour", request.window != .hourly, schema.granularities.contains("day") {
            let page = try await rows(
                segments: Self.querySegments(for: request.range),
                granularity: "day",
                spendMetric: schema.spendMetric,
                extraMetrics: extraMetrics,
                dimensions: dimensions
            )
            chunks = [(page.rows, "day")]
            truncated = page.truncated
            warnings.append("Hourly detail exceeded the API row limit; showing daily resolution.")
        }
        if truncated {
            warnings.append("Results were truncated by the API; totals may be incomplete.")
        }

        var slices = chunks.flatMap { chunk in
            Self.slices(from: chunk.rows, granularity: chunk.granularity, dimensions: dimensions, schema: schema)
        }
        let rowCount = chunks.reduce(0) { $0 + $1.rows.count }
        slices = Self.merged(slices)

        let granularities = chunks.map(\.granularity).joined(separator: "+")
        Log.providers.debug("openrouter analytics rows=\(rowCount, privacy: .public) granularity=\(granularities, privacy: .public)")

        if let warning = Self.rowReconciliationWarning(rowCount: rowCount, sliceCount: slices.count) {
            warnings.append(warning)
            let first = chunks.first?.rows.first
            let columns = first.map { $0.keys.sorted().joined(separator: ",") } ?? "-"
            let sample = first.flatMap(FlexibleJSON.timeBucket).map { "\($0.key)=\($0.value ?? "nil")" } ?? "no time column"
            Log.providers.notice("openrouter: \(warning, privacy: .public) columns=\(columns, privacy: .public)")
            Log.providers.notice("openrouter: time bucket sample \(sample, privacy: .public)")
        }

        var capabilities = Self.managementCapabilities(for: schema)
        let finest = chunks.contains { $0.granularity == "minute" } ? "minute" : granularity
        capabilities.nativeGranularity = finest == "hour" || finest == "minute" ? .hourly : .daily

        return SpendFetchResult(
            slices: slices,
            capabilities: capabilities,
            periodTotals: [:],
            warnings: warnings
        )
    }

    /// Where the minute-resolution tail begins, or nil when the whole range can
    /// be fetched coarse. Cutting on a UTC hour keeps the coarse query's last hour
    /// bucket complete and stops the two queries from overlapping.
    ///
    /// The tail starts an hour before the headline so the prior hour the delta
    /// compares against is resolved at the same granularity.
    static func minuteRefinementStart(for request: SpendRequest, schema: OpenRouterClient.Schema) -> Date? {
        guard request.window == .hourly,
              schema.granularities.contains("minute"),
              let headline = request.headlineRange
        else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let priorStart = headline.start.addingTimeInterval(-3600)
        guard let hourStart = utc.dateInterval(of: .hour, for: priorStart)?.start else { return nil }
        return max(hourStart, request.range.start)
    }

    /// Runs one query per segment and concatenates the rows.
    ///
    /// Segments are contiguous and half-open, so a bucket belongs to exactly one
    /// request; `merged(_:)` still folds any row the server reports twice, e.g.
    /// when a day bucket straddles a segment boundary.
    private func rows(
        segments: [DateInterval],
        granularity: String,
        spendMetric: String,
        extraMetrics: [String],
        dimensions: [String]
    ) async throws -> (rows: [[String: Any]], truncated: Bool) {
        var rows: [[String: Any]] = []
        var truncated = false
        for segment in segments {
            let page = try await client.query(
                OpenRouterClient.Query(
                    spendMetric: spendMetric,
                    extraMetrics: extraMetrics,
                    dimensions: dimensions,
                    granularity: granularity,
                    range: segment,
                    limit: Self.rowLimit
                )
            )
            rows.append(contentsOf: page.rows)
            truncated = truncated || page.truncated
        }
        return (rows, truncated)
    }

    /// Splits a fetch range into segments the endpoint will accept.
    ///
    /// Cuts land on UTC midnights so a day-granularity bucket is rarely split
    /// across two requests, which keeps per-segment rows complete.
    static func querySegments(for range: DateInterval, maxDays: Int = maxDaysPerQuery) -> [DateInterval] {
        let maxDuration = TimeInterval(max(maxDays, 1)) * 86_400
        guard range.duration > maxDuration else { return [range] }

        var segments: [DateInterval] = []
        var cursor = range.start
        while range.end.timeIntervalSince(cursor) > maxDuration {
            let naive = cursor.addingTimeInterval(maxDuration)
            let midnight = Date(timeIntervalSince1970: (naive.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400)
            let cut = midnight > cursor ? midnight : naive
            segments.append(DateInterval(start: cursor, end: cut))
            cursor = cut
        }
        segments.append(DateInterval(start: cursor, end: range.end))
        return segments
    }

    /// Folds slices that describe the same (bucket, model, upstream provider)
    /// triple, which happens only when a bucket spans a segment boundary.
    static func merged(_ slices: [SpendSlice]) -> [SpendSlice] {
        var merged: [SliceKey: SpendSlice] = [:]
        for slice in slices {
            let key = SliceKey(start: slice.start, model: slice.model, upstreamProvider: slice.upstreamProvider)
            guard var existing = merged[key] else {
                merged[key] = slice
                continue
            }
            existing.amount += slice.amount
            existing.promptTokens += slice.promptTokens
            existing.completionTokens += slice.completionTokens
            existing.requests += slice.requests
            merged[key] = existing
        }
        return merged.values.sorted { $0.start < $1.start }
    }

    private struct SliceKey: Hashable {
        var start: Date
        var model: String?
        var upstreamProvider: String?
    }

    /// Explains an empty chart instead of reporting a clean zero.
    ///
    /// A silent gap between "the API returned rows" and "the app has spend" is
    /// indistinguishable from a genuinely quiet account, which is how a parsing
    /// regression goes unnoticed.
    static func rowReconciliationWarning(rowCount: Int, sliceCount: Int) -> String? {
        guard sliceCount == 0 else { return nil }
        if rowCount == 0 {
            return "No activity returned for the selected range."
        }
        return "OpenRouter returned \(rowCount) rows but none carried a readable time bucket."
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

            let end = calendar.date(byAdding: component, value: 1, to: start) ?? start

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
        // The hourly headline is a trailing 60 minutes, which needs minute rows
        // to resolve its boundary; hour-only accounts fall back to daily.
        if schema.granularities.contains("hour"), schema.granularities.contains("minute") {
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
