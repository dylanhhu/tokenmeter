import Foundation

/// Static, non-secret description of a provider. Used to render configuration UI
/// before any credentials exist.
public struct ProviderDescriptor: Sendable, Identifiable, Hashable {
    public var id: ProviderID
    public var displayName: String
    /// One line describing what the adapter reads.
    public var summary: String
    public var credentialLabel: String
    public var credentialPlaceholder: String
    /// Where the user creates the credential.
    public var credentialURL: URL?
    /// Where the relevant API docs live.
    public var documentationURL: URL?
    /// Explains what an upgraded credential unlocks, when applicable.
    public var upgradeHint: String?
    /// True for the synthetic provider used for UI development.
    public var isSynthetic: Bool

    public init(
        id: ProviderID,
        displayName: String,
        summary: String,
        credentialLabel: String,
        credentialPlaceholder: String,
        credentialURL: URL? = nil,
        documentationURL: URL? = nil,
        upgradeHint: String? = nil,
        isSynthetic: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.credentialLabel = credentialLabel
        self.credentialPlaceholder = credentialPlaceholder
        self.credentialURL = credentialURL
        self.documentationURL = documentationURL
        self.upgradeHint = upgradeHint
        self.isSynthetic = isSynthetic
    }
}

/// The single seam a new provider needs to implement.
///
/// Contract for `fetchSpend`:
/// - Return slices bucketed no more coarsely than `request.window`.
/// - Cover `request.range`, which includes the prior comparison period.
/// - When the provider can produce rows finer than hourly, refine the tail over
///   `request.headlineRange`: an hourly headline is a trailing 60 minutes and
///   cannot be reconstructed from clock-hour buckets.
/// - Report honest `capabilities` for the credentials in use; the app uses them
///   to gate window options and breakdown UI.
/// - Prefer `periodTotals` only when authoritative period figures exist and
///   cannot be reconstructed from slices.
public protocol SpendProvider: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Cheap credential + capability probe for the settings UI.
    func probe() async throws -> ProviderCapabilities

    func fetchSpend(_ request: SpendRequest) async throws -> SpendFetchResult
}

public extension SpendProvider {
    var id: ProviderID {
        descriptor.id
    }

    var displayName: String {
        descriptor.displayName
    }
}
