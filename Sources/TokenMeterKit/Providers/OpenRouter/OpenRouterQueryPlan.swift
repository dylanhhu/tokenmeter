import Foundation

/// Request shaping for the analytics endpoint: how one fetch becomes a handful of
/// queries that keep the app's sums exact without blowing the row limit.
extension OpenRouterProvider {
    /// One contiguous stretch of the fetch range, requested at a single
    /// server-side granularity.
    struct QueryStep: Equatable {
        var range: DateInterval
        var granularity: String
    }

    /// Splits a fetch into coarse history plus fine segments around the headline
    /// boundaries.
    ///
    /// The aggregator only sums slices that *start* inside the headline, so a
    /// boundary that falls mid-bucket loses that bucket entirely. Refining the
    /// coarse bucket that contains each boundary is enough to make the sum exact
    /// to one fine bucket: a minute for hourly and daily windows, an hour for
    /// weekly and monthly ones. Segments are contiguous and half-open, so a
    /// bucket is never reported twice.
    static func queryPlan(
        for request: SpendRequest,
        coarse: String,
        schema: OpenRouterClient.Schema
    ) -> [QueryStep] {
        let whole = [QueryStep(range: request.range, granularity: coarse)]
        guard request.scope == .trailing,
              let headline = request.headlineRange,
              let fine = finerGranularity(than: coarse, in: schema.granularities)
        else { return whole }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let component = component(for: coarse)

        var windows: [DateInterval] = []
        let boundaries = [
            headline.start.addingTimeInterval(-headline.duration),
            headline.start,
        ]
        for boundary in boundaries {
            guard let bucket = calendar.dateInterval(of: component, for: boundary) else { continue }
            // A boundary that already sits on a coarse bucket edge needs no finer
            // rows; the coarse bucket is wholly inside or outside the range.
            guard bucket.start != boundary else { continue }
            let start = max(bucket.start, request.range.start)
            let end = min(bucket.end, request.range.end)
            guard start < end else { continue }
            windows.append(DateInterval(start: start, end: end))
        }
        guard !windows.isEmpty else { return whole }

        windows.sort { $0.start < $1.start }
        var refined: [DateInterval] = []
        for window in windows {
            if let last = refined.last, window.start <= last.end {
                refined[refined.count - 1] = DateInterval(start: last.start, end: max(last.end, window.end))
            } else {
                refined.append(window)
            }
        }

        var plan: [QueryStep] = []
        var cursor = request.range.start
        for window in refined {
            if cursor < window.start {
                plan.append(QueryStep(range: DateInterval(start: cursor, end: window.start), granularity: coarse))
            }
            plan.append(QueryStep(range: window, granularity: fine))
            cursor = max(cursor, window.end)
        }
        if cursor < request.range.end {
            plan.append(QueryStep(range: DateInterval(start: cursor, end: request.range.end), granularity: coarse))
        }
        return plan
    }

    /// Server granularities, finest first. The order is what makes "one step
    /// finer than the bucket" well defined.
    static let granularityOrder = ["minute", "hour", "day", "week", "month"]

    static func component(for granularity: String) -> Calendar.Component {
        switch granularity {
        case "minute": .minute
        case "hour": .hour
        case "week": .weekOfYear
        case "month": .month
        default: .day
        }
    }

    /// The display window a server granularity corresponds to, used to report
    /// what the credential actually returned.
    static func window(forGranularity granularity: String) -> SpendWindow? {
        switch granularity {
        case "minute", "hour": .hourly
        case "day": .daily
        case "week": .weekly
        case "month": .monthly
        default: nil
        }
    }

    /// The finest supported granularity strictly finer than `coarse`.
    static func finerGranularity(than coarse: String, in available: Set<String>) -> String? {
        guard let rank = granularityOrder.firstIndex(of: coarse) else { return nil }
        return granularityOrder.prefix(rank).reversed().first { available.contains($0) }
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
}
