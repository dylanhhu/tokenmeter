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
    }

    static let models: [SyntheticModel] = [
        .init(slug: "anthropic/claude-sonnet-4.5", provider: "Anthropic", weight: 0.34, inputRate: 3.0, outputRate: 15.0),
        .init(slug: "openai/gpt-5.1", provider: "OpenAI", weight: 0.24, inputRate: 1.25, outputRate: 10.0),
        .init(slug: "google/gemini-2.5-pro", provider: "Google", weight: 0.16, inputRate: 1.25, outputRate: 10.0),
        .init(slug: "deepseek/deepseek-v3.2", provider: "DeepSeek", weight: 0.12, inputRate: 0.28, outputRate: 0.42),
        .init(slug: "meta-llama/llama-4-maverick", provider: "Meta", weight: 0.08, inputRate: 0.27, outputRate: 0.85),
        .init(slug: "mistralai/mistral-large-2411", provider: "Mistral", weight: 0.04, inputRate: 2.0, outputRate: 6.0),
        .init(slug: "qwen/qwen3-coder", provider: "Qwen", weight: 0.02, inputRate: 0.3, outputRate: 1.2),
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
        let component = request.window.bucketComponent

        // Walk the requested range in whole buckets so slices always line up with
        // the caller's display buckets.
        var bucketStarts: [Date] = []
        var cursor = Bucketing.interval(component, containing: request.range.start, calendar: calendar)
        while cursor.start < request.range.end, bucketStarts.count < 400 {
            bucketStarts.append(cursor.start)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor.start) else { break }
            cursor = Bucketing.interval(component, containing: next, calendar: calendar)
        }

        let now = Date()
        var slices: [SpendSlice] = []

        for start in bucketStarts {
            let end = calendar.date(byAdding: component, value: 1, to: start) ?? start
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
                // Assume a 3:1 prompt:completion token split and price the tokens
                // at the model's own rates, so tokens and dollars agree.
                let blendedRate = (0.75 * model.inputRate) + (0.25 * model.outputRate)
                let totalTokens = blendedRate > 0 ? Int(amount * 1_000_000 / blendedRate) : 0
                let promptTokens = totalTokens * 3 / 4
                let completionTokens = totalTokens / 4
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
                        requests: max(1, Int(amount / 0.02))
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
