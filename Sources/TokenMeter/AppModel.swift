import AppKit
import Foundation
import Observation
import TokenMeterKit

/// A per-provider problem that did not stop the whole refresh.
struct ProviderIssue: Identifiable, Sendable, Equatable {
    var providerID: ProviderID
    var providerName: String
    var message: String
    var isCredentialProblem: Bool

    var id: String {
        "\(providerID.rawValue)|\(message)"
    }
}

/// Owns application state: settings, credentials, the latest provider results,
/// and the report derived from them.
///
/// Deliberately single-actor (main). Network work is spawned in tasks and hops
/// back; the only state that crosses isolation boundaries is `Sendable` value
/// types from `TokenMeterKit`.
@MainActor
@Observable
final class AppModel {
    /// Process-wide instance. The menu bar scene and the settings window are
    /// separate view hierarchies over the same state.
    static let shared = AppModel()

    private(set) var settings: AppSettings
    private(set) var report: SpendReport?
    private(set) var issues: [ProviderIssue] = []
    private(set) var capabilities: [ProviderID: ProviderCapabilities] = [:]
    private(set) var accountInfo: [ProviderID: ProviderAccountInfo] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Providers that have a usable credential.
    private(set) var connectedProviders: Set<ProviderID> = []
    /// Set when the most recent refresh produced nothing at all.
    private(set) var emptyStateMessage: String?

    private var contributions: [SpendAggregator.Contribution] = []
    /// Credentials are read from the Keychain at most once per process and then
    /// reused.
    ///
    /// A read can block on a system prompt — ad-hoc signed builds get a new code
    /// identity on every rebuild, so macOS no longer matches them to the keychain
    /// ACL and asks again. With the refresh loop running every 60 seconds, an
    /// uncached read per refresh becomes a prompt loop, and because the read used
    /// to happen on the main actor it also delayed the menu bar item.
    private var credentialCache: [ProviderID: String?] = [:]
    /// Recently fetched provider results, so navigating the popover does not
    /// re-query every vendor. Filled and read by `ProviderFetch.fetchAll`.
    private let resultCache: SpendResultCache
    private var reportBucketing: Bucketing
    private var refreshLoop: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var wakeObservers: [NSObjectProtocol] = []
    private var hasStarted = false
    private var isCoercingWindow = false

    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStore

    init(settingsStore: SettingsStore = SettingsStore(), credentialStore: CredentialStore = CredentialStore()) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        let loaded = settingsStore.load()
        settings = loaded
        resultCache = SpendResultCache(ttl: Self.cacheLifetime(for: loaded))
        reportBucketing = Bucketing(window: loaded.menuBarWindow, timeZoneMode: loaded.timeZoneMode)
        connectedProviders = ProviderFetch.syntheticProviders(in: loaded.enabledProviders)
    }

    /// How long a fetched result may be reused without asking the vendor again.
    ///
    /// This is the refresh interval, so a user who asked for infrequent refreshes
    /// is not refetched by clicking the menu bar icon or flipping window tabs.
    /// The floor keeps the default 5-minute interval from turning rapid UI
    /// navigation into a stream of API calls.
    static func cacheLifetime(for settings: AppSettings) -> TimeInterval {
        max(60, settings.refreshInterval)
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        restartRefreshLoop()
        refresh(reason: "launch")
        observeSleepAndWake()
    }

    func shutdown() {
        refreshLoop?.cancel()
        inFlight?.cancel()
        wakeObservers.forEach(NotificationCenter.default.removeObserver)
        wakeObservers.removeAll()
    }

    /// Refresh promptly after the machine wakes or the wall clock jumps, since a
    /// timer-driven refresh may have been suspended for hours.
    private func observeSleepAndWake() {
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            .NSSystemClockDidChange,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(reason: "wake") }
            }
            wakeObservers.append(token)
        }
    }

    func restartRefreshLoop() {
        refreshLoop?.cancel()
        let lifetime = Self.cacheLifetime(for: settings)
        Task { await resultCache.setTimeToLive(lifetime) }
        let interval = max(30, settings.refreshInterval)
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refresh(reason: "timer")
            }
        }
    }

    // MARK: - Derived state

    var bucketing: Bucketing {
        Bucketing(window: settings.menuBarWindow, timeZoneMode: settings.timeZoneMode)
    }

    /// Windows that at least one configured provider can fill.
    var availableWindows: [SpendWindow] {
        guard !settings.enabledProviders.isEmpty else { return SpendWindow.allCases }
        var supported: Set<SpendWindow> = []
        for id in settings.enabledProviders {
            if let capability = capabilities[id] {
                supported.formUnion(capability.windows)
            } else {
                // Unknown capabilities (first launch, failed probe): do not hide
                // options the user may legitimately want.
                supported.formUnion(SpendWindow.allCases)
            }
        }
        return SpendWindow.allCases.filter { supported.contains($0) }
    }

    /// Whether per-model attribution is available from any provider.
    var hasBreakdown: Bool {
        report?.hasBreakdown ?? capabilities.values.contains(where: \.hasBreakdown)
    }

    var menuBarText: String {
        guard let report else { return "—" }
        let amount = Money.menuBar(report.headlineTotal)
        switch settings.menuBarStyle {
        case .amount, .iconAndAmount: return amount
        case .amountAndWindow: return "\(amount) \(settings.menuBarWindow.shortTitle)"
        }
    }

    var menuBarTooltip: String {
        guard let report else { return "TokenMeter — no data yet" }
        return "\(Money.precise(report.headlineTotal)) \(report.headlineCaption)"
    }

    var descriptors: [ProviderDescriptor] {
        ProviderCatalog.descriptors
    }

    var enabledDescriptors: [ProviderDescriptor] {
        settings.enabledProviders.compactMap { ProviderCatalog.descriptor(for: $0) }
    }

    func capability(for id: ProviderID) -> ProviderCapabilities? {
        capabilities[id]
    }

    func hasCredential(_ id: ProviderID) -> Bool {
        connectedProviders.contains(id)
    }

    // MARK: - Settings

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        let previous = settings
        var updated = settings
        transform(&updated)
        guard updated != previous else { return }
        settings = updated
        settingsStore.save(updated)

        if updated.requiresRefetch(comparedTo: previous) {
            refresh(reason: "settings")
        } else if updated.requiresRebuild(comparedTo: previous) {
            rebuildReport()
        }
        if updated.refreshInterval != previous.refreshInterval {
            restartRefreshLoop()
        }
    }

    func setWindow(_ window: SpendWindow) {
        updateSettings { $0.menuBarWindow = window }
    }

    /// Awaits one refresh. Used by the snapshot renderer, which must not race
    /// against the fire-and-forget timer path.
    func refreshForSnapshot() async {
        refresh(reason: "snapshot", force: true)
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Refreshes only when the data is older than `maxAge`, so opening the popover
    /// repeatedly does not hammer provider APIs. Even a refresh inside that
    /// window would be answered by `resultCache`; skipping it also avoids
    /// rebuilding the report from slices whose in-progress bucket has moved on.
    func refreshIfStale(maxAge: TimeInterval? = nil) {
        guard !isRefreshing else { return }
        let age = maxAge ?? Self.cacheLifetime(for: settings)
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < age {
            return
        }
        refresh(reason: "popover")
    }

    /// Turns on the synthetic adapter so the interface can be explored without
    /// a credential.
    func enableDemoProvider() {
        updateSettings { settings in
            if !settings.enabledProviders.contains(DemoProvider.providerID) {
                settings.enabledProviders.append(DemoProvider.providerID)
            }
        }
    }

    // MARK: - Credentials

    func credential(for id: ProviderID) -> String? {
        guard !(ProviderCatalog.descriptor(for: id)?.isSynthetic ?? false) else { return nil }
        if let cached = credentialCache.first(where: { $0.key == id }) {
            return cached.value
        }
        let value = try? credentialStore.load(for: id)
        credentialCache.updateValue(value, forKey: id)
        return value
    }

    @discardableResult
    func saveCredential(_ secret: String, for id: ProviderID) -> String? {
        do {
            try credentialStore.save(secret, for: id)
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            remember(trimmed.isEmpty ? nil : trimmed, for: id)
            // A result fetched with the previous credential may carry different
            // capabilities, and the key is deliberately credential-free.
            let cache = resultCache
            Task { await cache.invalidate(providers: [id]) }
            return nil
        } catch {
            Log.credentials.error("Saving credential failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    func removeCredential(for id: ProviderID) {
        do {
            try credentialStore.delete(for: id)
        } catch {
            Log.credentials.error("Deleting credential failed: \(error.localizedDescription, privacy: .public)")
        }
        remember(nil, for: id)
        capabilities[id] = nil
        accountInfo[id] = nil
        contributions.removeAll { $0.providerID == id }
        rebuildReport()
        let cache = resultCache
        Task { await cache.invalidate(providers: [id]) }
        refresh(reason: "credential-removed", force: true)
    }

    /// Records what the Keychain returned for a provider and keeps the connected
    /// set in step. `nil` means "known to hold no credential", which is cached
    /// just as deliberately as a value so a removed key is not re-read forever.
    private func remember(_ secret: String?, for id: ProviderID) {
        credentialCache.updateValue(secret, forKey: id)
        if secret?.isEmpty == false {
            connectedProviders.insert(id)
        } else {
            connectedProviders.remove(id)
        }
    }

    /// Verifies a credential and reports what it unlocks. Does not persist it —
    /// the caller decides whether to save.
    func probe(_ id: ProviderID, credentialOverride: String? = nil) async -> Result<ProviderCapabilities, SpendProviderError> {
        let credential = credentialOverride ?? credential(for: id)
        guard let provider = ProviderCatalog.makeProvider(id: id, credential: credential) else {
            return .failure(.missingCredential)
        }
        do {
            let result = try await ProviderFetch.withTimeout(seconds: 20) {
                try await provider.probe()
            }
            capabilities[id] = result
            return .success(result)
        } catch let error as SpendProviderError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - Refresh

    /// - Parameter force: Bypasses `resultCache`, for a user-initiated refresh or
    ///   a fetch that follows a credential change. Ordinary triggers reuse recent
    ///   results.
    func refresh(reason: String, force: Bool = false) {
        inFlight?.cancel()
        if settings.enabledProviders.isEmpty {
            isRefreshing = false
            contributions = []
            report = nil
            return
        }
        let window = settings.menuBarWindow
        let timeZoneMode = settings.timeZoneMode
        let enabled = settings.enabledProviders
        let bucketing = Bucketing(window: window, timeZoneMode: timeZoneMode)
        reportBucketing = bucketing
        let request = SpendRequest(bucketing: bucketing)
        let keychain = credentialStore
        let cached = credentialCache
        let cache = resultCache
        let bypassCache = force

        isRefreshing = true
        inFlight = Task { [weak self] in
            let credentials = await ProviderFetch.loadCredentials(for: enabled, store: keychain, cached: cached)
            guard !Task.isCancelled else { return }
            let providers = ProviderFetch.makeProviders(for: enabled, credentials: credentials)
            let results = await ProviderFetch.fetchAll(
                providers: providers,
                request: request,
                cache: cache,
                bypassCache: bypassCache
            )
            guard !Task.isCancelled, let self else { return }
            apply(results: results, credentials: credentials, enabled: enabled, bucketing: bucketing)
        }
    }

    /// Falls back to the finest window the configured providers can actually
    /// fill, e.g. when a usable credential turns out to be an inference key.
    private func coerceWindowIfUnsupported() {
        guard !isCoercingWindow else { return }
        let available = availableWindows
        guard !available.isEmpty, !available.contains(settings.menuBarWindow),
              let best = available.min(by: { $0.rank < $1.rank }) else { return }
        let requested = settings.menuBarWindow.rawValue
        Log.app.notice("Window \(requested, privacy: .public) unsupported; using \(best.rawValue, privacy: .public)")
        isCoercingWindow = true
        updateSettings { $0.menuBarWindow = best }
        isCoercingWindow = false
    }

    private func apply(
        results: [ProviderFetch.Outcome],
        credentials: [ProviderID: String?],
        enabled: [ProviderID],
        bucketing: Bucketing
    ) {
        isRefreshing = false
        // Report the age of the data, not the age of this refresh: a cache hit
        // would otherwise make old numbers look freshly fetched.
        lastRefresh = results.map(\.fetchedAt).max() ?? .now
        let cachedCount = results.count(where: \.isCached)
        if cachedCount > 0 {
            Log.providers.debug("Served \(cachedCount, privacy: .public) of \(results.count, privacy: .public) results from cache")
        }

        var newContributions: [SpendAggregator.Contribution] = []
        var newIssues: [ProviderIssue] = []

        connectedProviders = ProviderFetch.syntheticProviders(in: enabled)
        for id in enabled where ProviderCatalog.requiresCredential(id: id) {
            let secret = ProviderFetch.credential(id, in: credentials)
            remember(secret, for: id)
            guard secret?.isEmpty != false else { continue }
            newIssues.append(
                ProviderIssue(
                    providerID: id,
                    providerName: ProviderCatalog.descriptor(for: id)?.displayName ?? id.rawValue,
                    message: "No API key configured.",
                    isCredentialProblem: true
                )
            )
        }

        for outcome in results {
            switch outcome.result {
            case let .success(result):
                newContributions.append(.init(providerID: outcome.providerID, result: result))
                capabilities[outcome.providerID] = result.capabilities
                if let account = result.account {
                    accountInfo[outcome.providerID] = account
                }
                for warning in result.warnings {
                    newIssues.append(
                        ProviderIssue(
                            providerID: outcome.providerID,
                            providerName: outcome.providerName,
                            message: warning,
                            isCredentialProblem: false
                        )
                    )
                }
            case let .failure(error):
                Log.providers
                    .error(
                        "\(outcome.providerID.rawValue, privacy: .public) refresh failed: \(error.localizedDescription, privacy: .public)"
                    )
                newIssues.append(
                    ProviderIssue(
                        providerID: outcome.providerID,
                        providerName: outcome.providerName,
                        message: error.errorDescription ?? "Unknown error.",
                        isCredentialProblem: error.isCredentialProblem
                    )
                )
            }
        }

        // A failed provider should not blank the chart; keep its last good data.
        let failedIDs = Set(results.filter {
            if case .failure = $0.result {
                true
            } else {
                false
            }
        }.map(\.providerID))
        let retained = contributions.filter { failedIDs.contains($0.providerID) }
        contributions = retained + newContributions
        issues = newIssues
        reportBucketing = bucketing

        emptyStateMessage = contributions.isEmpty && newIssues.isEmpty
            ? "No providers are enabled."
            : nil

        rebuildReport()
        coerceWindowIfUnsupported()
    }

    private func rebuildReport() {
        let bucketing = Bucketing(window: settings.menuBarWindow, timeZoneMode: settings.timeZoneMode)
        reportBucketing = bucketing
        let enabled = Set(settings.enabledProviders)
        let included = contributions.filter { enabled.contains($0.providerID) }
        if included.isEmpty {
            report = nil
            return
        }
        report = SpendAggregator.makeReport(
            contributions: included,
            bucketing: bucketing,
            grouping: settings.grouping,
            seriesLimit: settings.seriesLimit
        )
    }

    /// Bucketing the current report was built with, used by the views for labels.
    var currentBucketing: Bucketing {
        reportBucketing
    }
}
