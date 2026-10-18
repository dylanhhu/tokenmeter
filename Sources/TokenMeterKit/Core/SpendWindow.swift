import Foundation

/// The aggregation window the user is looking at. This drives three things: the
/// headline figure in the menu bar, how much history the chart shows, and how
/// much data is requested from providers.
public enum SpendWindow: String, CaseIterable, Codable, Sendable, Identifiable {
    case hourly
    case daily
    case weekly
    case monthly

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .hourly: "Hourly"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }

    /// Short form for segmented controls and the menu bar tooltip.
    public var shortTitle: String {
        switch self {
        case .hourly: "1h"
        case .daily: "1D"
        case .weekly: "1W"
        case .monthly: "1M"
        }
    }

    /// Describes the headline figure when it covers the calendar period in
    /// progress, e.g. "$1.24 **this week**".
    ///
    /// Rolling periods are labelled by `headlineLabel(scope:duration:)`, which
    /// knows how long the interval actually is.
    public var headlineNoun: String {
        switch self {
        case .hourly: "this hour"
        case .daily: "today"
        case .weekly: "this week"
        case .monthly: "this month"
        }
    }

    /// Noun for the headline period under a scope, e.g. "this week" or "last 7
    /// days".
    ///
    /// Rolling labels are derived from the interval rather than the window name
    /// because a rolling month is 28 to 31 days and a rolling day can be 23 or
    /// 25 hours across a DST change; the caption has to match the sum.
    public func headlineLabel(scope: WindowScope, duration: TimeInterval) -> String {
        guard scope == .trailing else { return headlineNoun }
        if self == .hourly {
            return "last hour"
        }
        let hours = max(1, Int((duration / 3600).rounded()))
        if hours < 48 {
            return "last \(hours) hours"
        }
        return "last \(hours / 24) days"
    }

    /// Compact suffix for `MenuBarStyle.amountAndWindow`, e.g. `1W` for the
    /// calendar week or `7D` for a rolling one.
    public func shortTitle(scope: WindowScope, duration: TimeInterval) -> String {
        guard scope == .trailing else { return shortTitle }
        let hours = max(1, Int((duration / 3600).rounded()))
        return hours < 48 ? "\(hours)H" : "\(hours / 24)D"
    }

    public var bucketComponent: Calendar.Component {
        switch self {
        case .hourly: .hour
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
    }

    /// How many buckets the chart shows by default.
    public var defaultBucketCount: Int {
        switch self {
        case .hourly: 24
        case .daily: 14
        case .weekly: 8
        case .monthly: 6
        }
    }

    /// Roughly how many days of data one bucket covers.
    public var approximateBucketDays: Double {
        switch self {
        case .hourly: 1.0 / 24.0
        case .daily: 1
        case .weekly: 7
        case .monthly: 30.44
        }
    }

    /// The finest data granularity a provider needs in order to fill this
    /// window's buckets without smearing values across boundaries.
    public var requiredGranularity: SpendWindow {
        self
    }

    /// Indices of the chart buckets that should carry an axis label. Labels are
    /// spread evenly and always include the first and last bucket, so the start
    /// of the range and the in-progress bucket the headline reports stay
    /// legible without crowding the axis.
    ///
    /// - Parameters:
    ///   - bucketCount: how many buckets the chart is drawing.
    ///   - tickCount: the most labels the axis should carry.
    public func axisLabelIndices(bucketCount: Int, tickCount: Int) -> [Int] {
        guard bucketCount > 2 else { return Array(0 ..< max(0, bucketCount)) }
        let labelCount = min(bucketCount, max(2, tickCount))
        let last = bucketCount - 1
        var indices: [Int] = []
        indices.reserveCapacity(labelCount)
        for step in 0 ..< labelCount {
            let index = Int((Double(step) * Double(last) / Double(labelCount - 1)).rounded())
            if indices.last != index {
                indices.append(index)
            }
        }
        return indices
    }

    /// Human label for one bucket's interval, e.g. `Tue, 2:00 – 3:00 PM` for an
    /// hour or `Aug 5 – 11` for a week.
    ///
    /// Bucket ends are exclusive, so calendar buckets are pulled back a second
    /// before formatting: otherwise a single day reads as "Aug 12 – 13". The
    /// hourly label keeps its end, because a bar labelled 2:00 – 3:00 is the
    /// hour between those two instants.
    public func bucketRangeLabel(
        start: Date,
        end: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        switch self {
        case .hourly:
            formatter.dateTemplate = "EEEj:mm"
            return formatter.string(from: start, to: max(start, end))
        case .daily, .weekly:
            formatter.dateTemplate = "MMMd"
            return formatter.string(from: start, to: max(start, end.addingTimeInterval(-1)))
        case .monthly:
            formatter.dateTemplate = "yMMMM"
            return formatter.string(from: start, to: max(start, end.addingTimeInterval(-1)))
        }
    }

    public func bucketLabel(for start: Date, calendar: Calendar) -> String {
        switch self {
        case .hourly:
            start.formatted(.dateTime.hour().locale(calendar.locale ?? .current))
        case .daily:
            start.formatted(.dateTime.month(.abbreviated).day().locale(calendar.locale ?? .current))
        case .weekly:
            start.formatted(.dateTime.month(.abbreviated).day().locale(calendar.locale ?? .current))
        case .monthly:
            start.formatted(.dateTime.month(.abbreviated).locale(calendar.locale ?? .current))
        }
    }
}

/// Which stretch of time the headline figure covers.
///
/// The chart always shows calendar buckets; only the headline, the breakdown's
/// denominator, and the period-over-period delta follow this. A rolling headline
/// ends mid-bucket, so it can span two bars.
public enum WindowScope: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The calendar period in progress: today so far, this week so far.
    case calendar
    /// An interval of one bucket's length ending now: the last 24 hours.
    case trailing

    public var id: String {
        rawValue
    }

    /// Name for the settings picker, where the window it applies to is a
    /// separate control and the period nouns would repeat it.
    public var title: String {
        switch self {
        case .calendar: "Period to date"
        case .trailing: "Rolling"
        }
    }
}

/// How spend is attributed to chart series.
public enum SpendGrouping: String, CaseIterable, Codable, Sendable, Identifiable {
    case model
    case provider

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .model: "By model"
        case .provider: "By provider"
        }
    }
}

public enum TimeZoneMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case local
    case utc

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .local: "Local time"
        case .utc: "UTC"
        }
    }

    public func calendar(now: Date = .now) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        let zone: TimeZone = switch self {
        case .local: .current
        case .utc: TimeZone(identifier: "UTC") ?? .gmt
        }
        calendar.timeZone = zone
        calendar.locale = .current
        // Use the user's idea of a week start; ISO weeks are not universal.
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    public var timeZone: TimeZone {
        switch self {
        case .local: .current
        case .utc: TimeZone(identifier: "UTC") ?? .gmt
        }
    }
}

/// Maps an instant onto the buckets of a window, and describes the range of
/// history that must be fetched to fill them.
///
/// Invariant relied on by `SpendAggregator`: every slice handed to it starts at
/// or after `fetchRange.start` and before `fetchRange.end`, and no slice is
/// coarser than one display bucket.
public struct Bucketing: Sendable {
    public let window: SpendWindow
    public let scope: WindowScope
    public let calendar: Calendar
    public let now: Date
    public let bucketCount: Int
    public let includesPriorPeriod: Bool

    /// Buckets currently visible in the chart, oldest first. The final bucket is
    /// the in-progress one that the headline figure reports.
    public let displayBuckets: [DateInterval]
    public let displayRange: DateInterval
    /// The equally sized range immediately before `displayRange`, for
    /// period-over-period comparison.
    public let priorRange: DateInterval?
    /// Everything a provider must return: prior period (when requested) plus the
    /// displayed buckets.
    public let fetchRange: DateInterval
    /// The interval the headline figure covers.
    ///
    /// Under `.calendar` this is the in-progress bucket. Under `.trailing` it is
    /// one bucket's length ending at `now`, aligned to minute boundaries so a
    /// provider that reports fine rows can sum it exactly.
    public let headlineRange: DateInterval
    /// The equal-length interval immediately before `headlineRange`, used for
    /// the period-over-period delta.
    public let priorHeadlineRange: DateInterval?

    public init(
        window: SpendWindow,
        scope: WindowScope = .calendar,
        timeZoneMode: TimeZoneMode = .local,
        now: Date = .now,
        bucketCount: Int? = nil,
        includesPriorPeriod: Bool = true
    ) {
        self.init(
            window: window,
            scope: scope,
            calendar: timeZoneMode.calendar(now: now),
            now: now,
            bucketCount: bucketCount,
            includesPriorPeriod: includesPriorPeriod
        )
    }

    public init(
        window: SpendWindow,
        scope: WindowScope = .calendar,
        calendar: Calendar,
        now: Date = .now,
        bucketCount: Int? = nil,
        includesPriorPeriod: Bool = true
    ) {
        self.window = window
        self.scope = scope
        self.calendar = calendar
        self.now = now
        self.bucketCount = max(1, bucketCount ?? window.defaultBucketCount)
        self.includesPriorPeriod = includesPriorPeriod

        let component = window.bucketComponent
        let currentStart = Self.interval(component, containing: now, calendar: calendar).start

        // Walk backwards from the current bucket rather than adding fixed
        // durations, so DST and variable-length months behave correctly.
        var starts: [Date] = [currentStart]
        var cursor = currentStart
        for _ in 1 ..< self.bucketCount {
            cursor = Self.interval(component, containing: cursor.addingTimeInterval(-1), calendar: calendar).start
            starts.append(cursor)
        }
        starts.reverse()

        var buckets: [DateInterval] = []
        buckets.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : Self.bucketEnd(for: currentStart, window: window, calendar: calendar)
            buckets.append(DateInterval(start: start, end: max(start, end)))
        }

        displayBuckets = buckets
        let first = buckets.first?.start ?? currentStart
        let last = buckets.last?.end ?? currentStart
        displayRange = DateInterval(start: first, end: last)

        var prior: DateInterval?
        if includesPriorPeriod {
            var priorCursor = first
            for _ in 0 ..< self.bucketCount {
                priorCursor = Self.interval(component, containing: priorCursor.addingTimeInterval(-1), calendar: calendar).start
            }
            prior = DateInterval(start: priorCursor, end: first)
        }
        priorRange = prior

        let fetchStart = prior?.start ?? first
        fetchRange = DateInterval(start: fetchStart, end: last)

        let current = buckets.last ?? DateInterval(start: currentStart, end: currentStart)
        switch scope {
        case .trailing:
            // One bucket's length ending now. End on the next minute so the
            // in-progress minute is included and the boundary lands on a provider
            // row boundary; the chart buckets stay calendar-aligned.
            let end = Self.minuteCeiling(now)
            let start = end.addingTimeInterval(-max(1, current.duration))
            headlineRange = DateInterval(start: start, end: end)
            priorHeadlineRange = includesPriorPeriod
                ? DateInterval(start: start.addingTimeInterval(-max(1, current.duration)), end: start)
                : nil
        case .calendar:
            headlineRange = current
            if let prior {
                let elapsed = max(0, now.timeIntervalSince(current.start))
                priorHeadlineRange = DateInterval(start: prior.start, end: prior.start.addingTimeInterval(elapsed))
            } else {
                priorHeadlineRange = nil
            }
        }
    }

    /// Rounds up to the next whole minute, so a range ending here contains every
    /// minute bucket that has started.
    static func minuteCeiling(_ date: Date) -> Date {
        let interval = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (interval / 60).rounded(.up) * 60)
    }

    /// Index into `displayBuckets` for an instant, or nil when outside them.
    public func bucketIndex(for date: Date) -> Int? {
        guard date >= displayRange.start, date < displayRange.end else { return nil }
        // Binary search over sorted, contiguous buckets.
        var low = 0
        var high = displayBuckets.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let bucket = displayBuckets[mid]
            if date < bucket.start {
                high = mid - 1
            } else if date >= bucket.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return displayBuckets.count - 1
    }

    public func containsInPriorPeriod(_ date: Date) -> Bool {
        guard let priorRange else { return false }
        return date >= priorRange.start && date < priorRange.end
    }

    public var currentBucket: DateInterval? {
        displayBuckets.last
    }

    public func label(for bucketIndex: Int) -> String {
        guard displayBuckets.indices.contains(bucketIndex) else { return "" }
        return window.bucketLabel(for: displayBuckets[bucketIndex].start, calendar: calendar)
    }

    static func interval(_ component: Calendar.Component, containing date: Date, calendar: Calendar) -> DateInterval {
        if let interval = calendar.dateInterval(of: component, for: date) {
            return interval
        }
        return DateInterval(start: date, duration: 0)
    }

    static func bucketEnd(for start: Date, window: SpendWindow, calendar: Calendar) -> Date {
        calendar.date(byAdding: window.bucketComponent, value: 1, to: start) ?? start
    }
}

/// The finest bucket a provider can produce, so the app can decide whether a
/// window is displayable at all.
public extension SpendWindow {
    var rank: Int {
        switch self {
        case .hourly: 0
        case .daily: 1
        case .weekly: 2
        case .monthly: 3
        }
    }
}
