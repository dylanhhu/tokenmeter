import Foundation

/// Synthetic provider used to exercise the UI without credentials, and as a
/// reference implementation of `SpendProvider`.
///
/// Values are derived from a hash of (model, bucket) so refreshes are stable and
/// history fills in immediately.
public struct DemoProvider: SpendProvider {
    public static let providerID: ProviderID = "demo"

    public static let descriptor = ProviderDescriptor(
        id: DemoProvider.providerID,
        displayName: "Sample data",
        summary: "Synthetic spend for previewing the interface. No network access.",
        credentialLabel: "None required",
        credentialPlaceholder: "",
        isSynthetic: true
    )

    struct SyntheticModel {
        var slug: String
        var provider: String
        var weight: Double
        var inputRate: Double // USD per million prompt tokens
        var outputRate: Double // USD per million completion tokens
        /// Share of the model's tokens spent on prompts; the rest are completions.
        /// Varying it per model keeps the efficiency readings from looking uniform.
        var promptShare: Double
        /// Average prompt plus completion size of one request.
        var tokensPerRequest: Int
    }

    static let models: [SyntheticModel] = [
        .init(
            slug: "anthropic/claude-sonnet-4.5",
            provider: "Anthropic",
            weight: 0.34,
            inputRate: 3.0,
            outputRate: 15.0,
            promptShare: 0.86,
            tokensPerRequest: 4_200
        ),
        .init(
            slug: "openai/gpt-5.1",
            provider: "OpenAI",
            weight: 0.24,
            inputRate: 1.25,
            outputRate: 10.0,
            promptShare: 0.82,
            tokensPerRequest: 3_100
        ),
        .init(
            slug: "google/gemini-2.5-pro",
            provider: "Google",
            weight: 0.16,
            inputRate: 1.25,
            outputRate: 10.0,
            promptShare: 0.88,
            tokensPerRequest: 6_800
        ),
        .init(
            slug: "deepseek/deepseek-v3.2",
            provider: "DeepSeek",
            weight: 0.12,
            inputRate: 0.28,
            outputRate: 0.42,
            promptShare: 0.74,
            tokensPerRequest: 2_400
        ),
        .init(
            slug: "meta-llama/llama-4-maverick",
            provider: "Meta",
            weight: 0.08,
            inputRate: 0.27,
            outputRate: 0.85,
            promptShare: 0.80,
            tokensPerRequest: 1_800
        ),
        .init(
            slug: "mistralai/mistral-large-2411",
            provider: "Mistral",
            weight: 0.04,
            inputRate: 2.0,
            outputRate: 6.0,
            promptShare: 0.62,
            tokensPerRequest: 1_500
        ),
        .init(
            slug: "qwen/qwen3-coder",
            provider: "Qwen",
            weight: 0.02,
            inputRate: 0.3,
            outputRate: 1.2,
            promptShare: 0.90,
            tokensPerRequest: 9_000
        ),
    ]

    /// Rough dollars per hour of total synthetic activity.
    private static let hourlyBudget = 0.85

    public init() {}

    public var descriptor: ProviderDescriptor {
        Self.descriptor
    }

    public func probe() async throws -> ProviderCapabilities {
        ProviderCapabilities(
            windows: Set(SpendWindow.allCases),
            hasModelBreakdown: true,
            hasProviderBreakdown: true,
            nativeGranularity: .hourly,
            notes: ["Synthetic data for interface preview; no API calls are made."]
        )
    }

    public func fetchSpend(_ request: SpendRequest) async throws -> SpendFetchResult {
        let calendar = request.calendar
        let steps = Self.steps(for: request, calendar: calendar)
        let now = Date()
        var slices: [SpendSlice] = []

        for (start, end) in steps {
            // Everything after "now" is zero, matching a real in-progress bucket.
            guard start < now else { continue }
            let coverage = min(now, end).timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
            let hours = end.timeIntervalSince(start) / 3600
            // Working hours carry more traffic than the small hours.
            let hourOfDay = calendar.component(.hour, from: start)
            let diurnal = 0.45 + 0.55 * max(0, sin(Double(hourOfDay - 3) / 24 * 2 * .pi))
            let bucketBudget = Self.hourlyBudget * hours * coverage * diurnal

            for model in Self.models {
                let noise = Self.noise(seed: "\(model.slug)@\(Int(start.timeIntervalSince1970))")
                let amount = bucketBudget * model.weight * noise
                guard amount > 0.000_01 else { continue }
                // Price the tokens at the model's own rates and per-model prompt
                // mix, so tokens and dollars agree and the efficiency readings
                // have something realistic to show.
                let unitRate = (model.promptShare * model.inputRate) + ((1 - model.promptShare) * model.outputRate)
                let totalTokens = unitRate > 0 ? Int(amount * 1_000_000 / unitRate) : 0
                let promptTokens = Int(Double(totalTokens) * model.promptShare)
                let completionTokens = totalTokens - promptTokens
                let requests = max(1, totalTokens / max(1, model.tokensPerRequest))
                slices.append(
                    SpendSlice(
                        start: start,
                        end: min(end, now),
                        providerID: Self.providerID,
                        providerName: Self.descriptor.displayName,
                        model: model.slug,
                        upstreamProvider: model.provider,
                        amount: Decimal(string: String(format: "%.6f", amount)) ?? 0,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens,
                        requests: requests
                    )
                )
            }
        }

        var capabilities = try await probe()
        capabilities.notes = ["Synthetic sample data — not real spend."]

        return SpendFetchResult(
            slices: slices,
            capabilities: capabilities,
            periodTotals: [:],
            warnings: ["Showing synthetic sample data."],
            account: ProviderAccountInfo(credentialLabel: "Sample data", isManagementCredential: true)
        )
    }

    /// Walks the requested range in whole buckets so slices always line up with
    /// the caller's display buckets.
    ///
    /// A rolling headline starts and ends mid-bucket, so — like a real provider —
    /// the synthetic one emits finer rows over the coarse buckets those two
    /// boundaries fall in; a coarse bucket cannot be split at that boundary.
    private static func steps(
        for request: SpendRequest,
        calendar: Calendar
    ) -> [(start: Date, end: Date)] {
        var steps: [(start: Date, end: Date)] = []
        func walk(_ component: Calendar.Component, from lower: Date, to upper: Date) {
            var cursor = Bucketing.interval(component, containing: lower, calendar: calendar).start
            while cursor < upper, steps.count < 1_200 {
                let end = min(calendar.date(byAdding: component, value: 1, to: cursor) ?? cursor, upper)
                steps.append((cursor, end))
                guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
                cursor = Bucketing.interval(component, containing: next, calendar: calendar).start
            }
        }

        let coarse: Calendar.Component = switch request.window {
        case .hourly, .daily: .hour
        case .weekly, .monthly: .day
        }
        let fine: Calendar.Component = switch request.window {
        case .hourly, .daily: .minute
        case .weekly, .monthly: .hour
        }

        var windows: [DateInterval] = []
        if request.scope == .trailing, let headline = request.headlineRange {
            for boundary in [headline.start.addingTimeInterval(-headline.duration), headline.start] {
                guard let bucket = calendar.dateInterval(of: coarse, for: boundary),
                      bucket.start != boundary else { continue }
                let start = max(bucket.start, request.range.start)
                let end = min(bucket.end, request.range.end)
                if start < end {
                    windows.append(DateInterval(start: start, end: end))
                }
            }
        }

        var cursor = request.range.start
        for window in windows.sorted(by: { $0.start < $1.start }) where window.start >= cursor {
            if cursor < window.start {
                walk(coarse, from: cursor, to: window.start)
            }
            walk(fine, from: window.start, to: window.end)
            cursor = window.end
        }
        if cursor < request.range.end {
            walk(coarse, from: cursor, to: request.range.end)
        }
        return steps
    }

    /// Deterministic value in roughly 0.7…1.6 so bars do not look uniform.
    private static func noise(seed: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let unit = Double(hash % 10_000) / 10_000.0
        return 0.7 + unit * 0.9
    }
}
