import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Spend result cache")
struct SpendResultCacheTests {
    static func calendar(_ zone: TimeZone = .gmt) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    static func request(
        _ window: SpendWindow,
        scope: WindowScope = .calendar,
        now: Date,
        zone: TimeZone = .gmt
    ) -> SpendRequest {
        SpendRequest(bucketing: Bucketing(window: window, scope: scope, calendar: calendar(zone), now: now))
    }

    static func result() -> SpendFetchResult {
        SpendFetchResult(slices: [], capabilities: .init())
    }

    @Test("A fresh result covering the requested range is served from the cache")
    func servesFreshEntry() async {
        let cache = SpendResultCache(ttl: 60)
        let request = Self.request(.daily, now: Self.date(12))
        let key = SpendResultCache.Key(providerID: "openrouter", request: request)
        await cache.store(Self.result(), for: key, request: request, at: Self.date(12))

        let hit = await cache.entry(for: key, request: request, now: Self.date(12, 1))
        #expect(hit != nil)
    }

    @Test("An entry older than the TTL is not served")
    func expiresAfterTTL() async {
        let cache = SpendResultCache(ttl: 60)
        let request = Self.request(.daily, now: Self.date(12))
        let key = SpendResultCache.Key(providerID: "openrouter", request: request)
        await cache.store(Self.result(), for: key, request: request, at: Self.date(12))

        let hit = await cache.entry(for: key, request: request, now: Self.date(12, 2))
        #expect(hit == nil)
    }

    @Test("An entry that no longer spans the requested range is not served")
    func rejectsMovedRange() async {
        let cache = SpendResultCache(ttl: 3600)
        // The hourly range ends at the top of the next hour, so crossing that
        // boundary must invalidate the entry even inside the TTL.
        let first = Self.request(.hourly, now: Self.date(12, 30))
        let key = SpendResultCache.Key(providerID: "openrouter", request: first)
        await cache.store(Self.result(), for: key, request: first, at: Self.date(12, 30))

        let later = Self.request(.hourly, now: Self.date(13, 10))
        let hit = await cache.entry(for: key, request: later, now: Self.date(13, 10))
        #expect(hit == nil)
    }

    @Test("Window and time zone are part of the key")
    func keysByWindowAndZone() async {
        let request = Self.request(.daily, now: Self.date(12))
        let key = SpendResultCache.Key(providerID: "openrouter", request: request)
        let cache = SpendResultCache(ttl: 600)
        await cache.store(Self.result(), for: key, request: request)

        let otherWindow = Self.request(.weekly, now: Self.date(12))
        let otherZone = Self.request(.daily, now: Self.date(12), zone: TimeZone(identifier: "Asia/Tokyo") ?? .gmt)

        #expect(await cache.entry(
            for: SpendResultCache.Key(providerID: "openrouter", request: otherWindow),
            request: otherWindow
        ) == nil)
        #expect(await cache.entry(
            for: SpendResultCache.Key(providerID: "openrouter", request: otherZone),
            request: otherZone
        ) == nil)
    }

    @Test("A calendar result is not served for a rolling headline")
    func keysByScope() async {
        // Both requests cover the same range, but only the rolling one contains
        // the fine rows its headline needs, so they cannot share an entry.
        let calendarRequest = Self.request(.daily, scope: .calendar, now: Self.date(12))
        let rollingRequest = Self.request(.daily, scope: .trailing, now: Self.date(12))
        #expect(calendarRequest.range == rollingRequest.range)

        let cache = SpendResultCache(ttl: 600)
        let calendarKey = SpendResultCache.Key(providerID: "openrouter", request: calendarRequest)
        await cache.store(Self.result(), for: calendarKey, request: calendarRequest)

        let rollingKey = SpendResultCache.Key(providerID: "openrouter", request: rollingRequest)
        #expect(await cache.entry(for: rollingKey, request: rollingRequest) == nil)
        #expect(await cache.entry(for: calendarKey, request: calendarRequest) != nil)
    }

    @Test("Invalidating one provider keeps the others")
    func invalidatesPerProvider() async {
        let request = Self.request(.daily, now: Self.date(12))
        let cache = SpendResultCache(ttl: 600)
        let openRouter = SpendResultCache.Key(providerID: "openrouter", request: request)
        let demo = SpendResultCache.Key(providerID: "demo", request: request)
        await cache.store(Self.result(), for: openRouter, request: request)
        await cache.store(Self.result(), for: demo, request: request)

        await cache.invalidate(providers: ["openrouter"])

        #expect(await cache.entry(for: openRouter, request: request) == nil)
        #expect(await cache.entry(for: demo, request: request) != nil)
    }
}
