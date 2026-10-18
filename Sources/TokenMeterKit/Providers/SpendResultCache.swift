import Foundation

/// Memoizes provider fetch results so navigating the interface — opening the
/// popover, flipping through window tabs — does not re-query the vendor.
///
/// An entry is keyed by the inputs that change the shape of a response:
/// provider, window, and bucketing time zone. It is served only while it is
/// younger than the TTL *and* still covers the range being requested. The second
/// condition matters because a result stops describing the current hour or day
/// as the clock advances, even if it was fetched seconds ago.
///
/// The cache stores only fetch results; it never holds a credential, and it
/// lives in memory for the process lifetime. The app treats a hit as slightly
/// old data rather than as fresh data: callers still see `fetchedAt`.
public actor SpendResultCache {
    public struct Key: Hashable, Sendable {
        public var providerID: ProviderID
        public var window: SpendWindow
        /// Identifier rather than a `TimeZone`, whose equality includes DST
        /// state and would needlessly split entries.
        public var timeZoneIdentifier: String

        public init(providerID: ProviderID, window: SpendWindow, timeZoneIdentifier: String) {
            self.providerID = providerID
            self.window = window
            self.timeZoneIdentifier = timeZoneIdentifier
        }

        /// Derives the key from a request, so callers cannot forget one of the
        /// dimensions that make two results incompatible.
        public init(providerID: ProviderID, request: SpendRequest) {
            self.init(
                providerID: providerID,
                window: request.window,
                timeZoneIdentifier: request.calendar.timeZone.identifier
            )
        }
    }

    public struct Entry: Sendable {
        public var result: SpendFetchResult
        /// When the provider actually answered, not when the entry was applied.
        public var fetchedAt: Date
        /// The range the provider was asked for, used to reject entries that no
        /// longer cover the range now being requested.
        public var range: DateInterval
    }

    private var entries: [Key: Entry] = [:]
    private var ttl: TimeInterval

    public init(ttl: TimeInterval = 60) {
        self.ttl = max(0, ttl)
    }

    /// How long an entry may be reused, in seconds. Tying this to the refresh
    /// interval means a user who chose infrequent refreshes is not refetched
    /// merely because they clicked around.
    public func setTimeToLive(_ seconds: TimeInterval) {
        ttl = max(0, seconds)
    }

    public var timeToLive: TimeInterval {
        ttl
    }

    /// The reusable entry for this key and request, or nil when there is none,
    /// it has expired, or it no longer spans the requested range.
    public func entry(for key: Key, request: SpendRequest, now: Date = .now) -> Entry? {
        guard let entry = entries[key],
              now.timeIntervalSince(entry.fetchedAt) <= ttl,
              entry.range.start <= request.range.start,
              entry.range.end >= request.range.end
        else { return nil }
        return entry
    }

    public func store(
        _ result: SpendFetchResult,
        for key: Key,
        request: SpendRequest,
        at date: Date = .now
    ) {
        entries[key] = Entry(result: result, fetchedAt: date, range: request.range)
    }

    /// Drops entries for a credential that has changed or been removed.
    public func invalidate(providers: Set<ProviderID>) {
        guard !providers.isEmpty else { return }
        entries = entries.filter { !providers.contains($0.key.providerID) }
    }

    public func invalidateAll() {
        entries.removeAll()
    }
}
