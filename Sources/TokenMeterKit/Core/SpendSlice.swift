import Foundation

/// Stable identifier for a provider adapter, e.g. `openrouter`.
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, Comparable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // Encode as a bare string so settings files stay readable.
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One provider's contribution to one time bucket, attributed as finely as that
/// provider allows.
///
/// This is the only shape adapters need to produce: they do not know about
/// charts, grouping, or formatting. Anything a provider cannot attribute stays
/// `nil` and the aggregator labels it accordingly.
public struct SpendSlice: Sendable, Hashable {
    /// Start of the period this slice covers. Providers must bucket this at
    /// least as finely as the requested window.
    public var start: Date
    /// End of the period (exclusive).
    public var end: Date
    /// Which adapter produced this slice.
    public var providerID: ProviderID
    /// Human-facing adapter name, e.g. `OpenRouter`.
    public var providerName: String
    /// Model slug when the provider exposes it, e.g. `anthropic/claude-sonnet-4.5`.
    public var model: String?
    /// Upstream inference provider when exposed, e.g. `Anthropic`.
    public var upstreamProvider: String?
    public var amount: Decimal
    public var promptTokens: Int
    public var completionTokens: Int
    public var requests: Int

    public init(
        start: Date,
        end: Date,
        providerID: ProviderID,
        providerName: String,
        model: String? = nil,
        upstreamProvider: String? = nil,
        amount: Decimal,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        requests: Int = 0
    ) {
        self.start = start
        self.end = end
        self.providerID = providerID
        self.providerName = providerName
        self.model = model
        self.upstreamProvider = upstreamProvider
        self.amount = amount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.requests = requests
    }

    public var totalTokens: Int {
        promptTokens + completionTokens
    }
}

/// What the app asks a provider for.
public struct SpendRequest: Sendable {
    /// Window being displayed; providers should bucket their output at least this
    /// finely.
    public var window: SpendWindow
    /// The full range to fetch, including the prior comparison period.
    public var range: DateInterval
    /// Calendar the caller will bucket with, so providers can align time ranges
    /// to their own server-side buckets if needed.
    public var calendar: Calendar
    /// The interval the headline will cover. For `.hourly` this is a trailing
    /// 60 minutes rather than a clock hour, so a provider that can report finer
    /// than hourly rows should refine its fetch over this range.
    public var headlineRange: DateInterval?

    public init(
        window: SpendWindow,
        range: DateInterval,
        calendar: Calendar,
        headlineRange: DateInterval? = nil
    ) {
        self.window = window
        self.range = range
        self.calendar = calendar
        self.headlineRange = headlineRange
    }

    public init(bucketing: Bucketing) {
        self.init(
            window: bucketing.window,
            range: bucketing.fetchRange,
            calendar: bucketing.calendar,
            headlineRange: bucketing.headlineRange
        )
    }
}

/// What a provider can do for the credentials currently supplied. This varies by
/// account (for OpenRouter, a management key unlocks history and breakdown), so
/// it travels with each fetch rather than being a static property.
public struct ProviderCapabilities: Sendable, Equatable {
    /// Windows the provider can fill with correctly sized buckets.
    public var windows: Set<SpendWindow>
    /// Whether slices carry a model dimension.
    public var hasModelBreakdown: Bool
    /// Whether slices carry an upstream provider dimension.
    public var hasProviderBreakdown: Bool
    /// Coarsest-to-finest note about native resolution, used in copy.
    public var nativeGranularity: SpendWindow?
    /// Human-readable caveats worth surfacing in the UI.
    public var notes: [String]

    public init(
        windows: Set<SpendWindow> = Set(SpendWindow.allCases),
        hasModelBreakdown: Bool = false,
        hasProviderBreakdown: Bool = false,
        nativeGranularity: SpendWindow? = nil,
        notes: [String] = []
    ) {
        self.windows = windows
        self.hasModelBreakdown = hasModelBreakdown
        self.hasProviderBreakdown = hasProviderBreakdown
        self.nativeGranularity = nativeGranularity
        self.notes = notes
    }

    public static let unavailable = ProviderCapabilities(windows: [], notes: ["No data available."])

    public var hasBreakdown: Bool {
        hasModelBreakdown || hasProviderBreakdown
    }

    public func supports(_ window: SpendWindow) -> Bool {
        windows.contains(window)
    }

    public var bestWindow: SpendWindow? {
        windows.min { $0.rank < $1.rank }
    }
}

/// Account-level details a provider may be able to report alongside spend, such
/// as remaining credit or which credential tier is in use.
public struct ProviderAccountInfo: Sendable, Equatable {
    /// Remaining prepaid credit, when the provider exposes one.
    public var remainingCredit: Decimal?
    /// Lifetime purchased credit, for context in the popover footer.
    public var purchasedCredit: Decimal?
    /// Label of the credential in use, e.g. `Management key`.
    public var credentialLabel: String?
    /// Provider-side name of the credential, e.g. `prod-pipeline`.
    public var keyLabel: String?
    /// True when the credential unlocks the provider's full analytics surface.
    public var isManagementCredential: Bool?

    public init(
        remainingCredit: Decimal? = nil,
        purchasedCredit: Decimal? = nil,
        credentialLabel: String? = nil,
        keyLabel: String? = nil,
        isManagementCredential: Bool? = nil
    ) {
        self.remainingCredit = remainingCredit
        self.purchasedCredit = purchasedCredit
        self.credentialLabel = credentialLabel
        self.keyLabel = keyLabel
        self.isManagementCredential = isManagementCredential
    }
}

/// Everything one provider returned for one refresh.
public struct SpendFetchResult: Sendable {
    public var slices: [SpendSlice]
    public var capabilities: ProviderCapabilities
    /// Provider-reported totals for the *current* period of a window. When
    /// present these are authoritative for the headline figure, which matters
    /// for providers that can only report period totals (no history).
    public var periodTotals: [SpendWindow: Decimal]
    /// Non-fatal problems, e.g. "results truncated, try a coarser window".
    public var warnings: [String]
    /// Optional account details, surfaced in the popover footer.
    public var account: ProviderAccountInfo?

    public init(
        slices: [SpendSlice],
        capabilities: ProviderCapabilities,
        periodTotals: [SpendWindow: Decimal] = [:],
        warnings: [String] = [],
        account: ProviderAccountInfo? = nil
    ) {
        self.slices = slices
        self.capabilities = capabilities
        self.periodTotals = periodTotals
        self.warnings = warnings
        self.account = account
    }
}

public enum SpendProviderError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidCredential(String)
    case insufficientPermissions(String)
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case decoding(String)
    case requestRejected(String)
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            "No API key configured."
        case let .invalidCredential(message):
            "Key rejected: \(message)"
        case let .insufficientPermissions(message):
            "Key lacks permission: \(message)"
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "Rate limited. Retrying in \(Int(retryAfter))s."
            } else {
                "Rate limited by the provider."
            }
        case let .network(message):
            "Network error: \(message)"
        case let .decoding(message):
            "Unexpected response: \(message)"
        case let .requestRejected(message):
            "Request rejected: \(message)"
        case let .server(status, message):
            "Server error \(status): \(message)"
        }
    }

    /// Whether the app should keep showing the last good data or clear it.
    public var isCredentialProblem: Bool {
        switch self {
        case .missingCredential, .invalidCredential, .insufficientPermissions: true
        default: false
        }
    }
}
