import Foundation

/// A fully aggregated view of spend for one window, ready to render.
public struct SpendReport: Sendable {
    public struct Series: Sendable, Identifiable, Hashable {
        /// Stable key derived from the grouping mode, used for colour assignment.
        public var id: String
        public var label: String
        /// Secondary text, e.g. the vendor of a model or the adapter name.
        public var detail: String?
        public var total: Decimal
        /// One entry per bucket in `buckets`, aligned by index. Counters travel
        /// with the spend so a single bar can be broken down on its own.
        public var perBucket: [BucketValues]
        /// Bar heights only, for the chart.
        public var amounts: [Decimal] {
            perBucket.map(\.amount)
        }

        /// Amount inside `headlineRange`. This differs from `amounts.last` for
        /// the hourly window, whose headline is a trailing 60 minutes rather
        /// than the current clock-hour bucket.
        public var currentAmount: Decimal
        /// Token and request totals across the whole displayed window.
        public var promptTokens = 0
        public var completionTokens = 0
        public var requests = 0
        /// Tokens and requests inside `headlineRange`, aligned with
        /// `currentAmount`. The hourly headline can span two clock-hour buckets,
        /// so these cannot be read from a per-bucket array.
        public var currentPromptTokens = 0
        public var currentCompletionTokens = 0
        public var currentRequests = 0
        public var isOther: Bool
        /// Number of underlying series folded into an "Other" row.
        public var foldedCount: Int

        public var totalTokens: Int {
            promptTokens + completionTokens
        }

        public var currentTokens: Int {
            currentPromptTokens + currentCompletionTokens
        }

        public var share: Decimal {
            perBucket.reduce(0) { $0 + $1.amount }
        }
    }

    public var window: SpendWindow
    /// Calendar — and therefore time zone — the buckets were cut with. A
    /// bucket's interval has to be formatted in the same zone it was built in,
    /// or a UTC bucket renders in local time.
    public var calendar: Calendar
    public var scope: WindowScope
    public var grouping: SpendGrouping
    /// The interval the headline, the current breakdown, and the delta describe.
    /// Kept here so captions can state the span instead of assuming a calendar
    /// period.
    public var headlineRange: DateInterval
    public var buckets: [Bucket]
    public var series: [Series]
    /// Sum of every displayed bucket.
    public var grandTotal: Decimal
    /// The figure shown in the menu bar and popover header.
    public var headlineTotal: Decimal
    /// Slice-derived total for the interval the headline covers. `headlineTotal`
    /// may instead come from a provider-reported period total, but the breakdown
    /// always explains this figure.
    public var currentPeriodTotal: Decimal
    /// True when `headlineTotal` came from a provider-reported period total
    /// rather than being summed from buckets. Never true under a rolling scope.
    public var headlineIsProviderReported: Bool
    /// Same window, immediately before the displayed range.
    public var priorPeriodTotal: Decimal?
    /// Prior-period spend summed over the same elapsed duration as the
    /// in-progress period. Comparing a partial period against a whole one would
    /// overstate every improvement, so deltas use this figure instead.
    public var priorComparableTotal: Decimal?
    /// Tokens and requests across every displayed bucket.
    public var promptTokens: Int
    public var completionTokens: Int
    public var requests: Int
    /// Tokens and requests for the in-progress period, matching the headline.
    public var currentPromptTokens: Int
    public var currentCompletionTokens: Int
    public var currentRequests: Int
    /// True when at least one contributor could attribute spend to a model.
    public var hasBreakdown: Bool
    public var capabilities: [ProviderID: ProviderCapabilities]
    public var warnings: [String]
    public var generatedAt: Date

    public static func empty(
        window: SpendWindow,
        scope: WindowScope = .calendar,
        grouping: SpendGrouping,
        buckets: [Bucket],
        calendar: Calendar
    ) -> SpendReport {
        SpendReport(
            window: window,
            calendar: calendar,
            scope: scope,
            grouping: grouping,
            headlineRange: DateInterval(start: buckets.first?.start ?? .now, end: buckets.last?.end ?? .now),
            buckets: buckets,
            series: [],
            grandTotal: 0,
            headlineTotal: 0,
            currentPeriodTotal: 0,
            headlineIsProviderReported: false,
            priorPeriodTotal: nil,
            priorComparableTotal: nil,
            promptTokens: 0,
            completionTokens: 0,
            requests: 0,
            currentPromptTokens: 0,
            currentCompletionTokens: 0,
            currentRequests: 0,
            hasBreakdown: false,
            capabilities: [:],
            warnings: [],
            generatedAt: .now
        )
    }

    public var totalTokens: Int {
        promptTokens + completionTokens
    }

    public var isEmpty: Bool {
        grandTotal == 0 && headlineTotal == 0
    }

    /// Token count for the in-progress period, so the figure sits under the same
    /// denominator as the headline.
    public var currentTokens: Int {
        currentPromptTokens + currentCompletionTokens
    }

    /// Series ordered for display: descending by total, with "Other" last.
    public var orderedSeries: [Series] {
        series.sorted { lhs, rhs in
            if lhs.isOther != rhs.isOther {
                return !lhs.isOther
            }
            if lhs.total == rhs.total {
                return lhs.label < rhs.label
            }
            return lhs.total > rhs.total
        }
    }

    /// Fractional change versus the same elapsed slice of the previous period.
    /// Nil when there is no comparable baseline to divide by.
    public var priorPeriodChange: Double? {
        guard let priorComparableTotal, priorComparableTotal > 0 else { return nil }
        let current = headlineTotal.doubleValue
        return (current - priorComparableTotal.doubleValue) / priorComparableTotal.doubleValue
    }
}

public enum SpendAggregator {
    public struct Contribution: Sendable {
        public var providerID: ProviderID
        public var result: SpendFetchResult

        public init(providerID: ProviderID, result: SpendFetchResult) {
            self.providerID = providerID
            self.result = result
        }
    }

    /// Folds one or more provider results into a single report.
    ///
    /// Attribution rules are deliberately conservative: a slice with no model
    /// becomes "Unattributed" under model grouping, and a slice with no upstream
    /// provider falls back to the adapter name under provider grouping. That way
    /// totals always reconcile with what the providers reported.
    public static func makeReport(
        contributions: [Contribution],
        bucketing: Bucketing,
        grouping: SpendGrouping,
        seriesLimit: Int = 6
    ) -> SpendReport {
        let fold = fold(
            contributions: contributions,
            bucketing: bucketing,
            grouping: grouping
        )

        let buckets = bucketing.displayBuckets.enumerated().map { index, interval in
            SpendReport.Bucket(
                start: interval.start,
                end: interval.end,
                total: fold.bucketTotals[index],
                isCurrent: index == bucketing.displayBuckets.count - 1
            )
        }

        let grandTotal = fold.bucketTotals.reduce(0, +)
        // A provider-reported period total describes a calendar period, so it can
        // only stand in for a calendar headline. Rolling figures must come from
        // slices that the app can clip at the boundary.
        let reportedHeadline = bucketing.scope == .calendar ? fold.periodTotals[bucketing.window] : nil
        let headline = reportedHeadline ?? fold.headlineTotal

        return SpendReport(
            window: bucketing.window,
            calendar: bucketing.calendar,
            scope: bucketing.scope,
            grouping: grouping,
            headlineRange: bucketing.headlineRange,
            buckets: buckets,
            series: rankedSeries(from: fold.accumulator, limit: seriesLimit),
            grandTotal: grandTotal,
            headlineTotal: headline,
            currentPeriodTotal: fold.headlineTotal,
            headlineIsProviderReported: reportedHeadline != nil,
            priorPeriodTotal: fold.hasPriorData ? fold.priorTotal : (bucketing.includesPriorPeriod ? 0 : nil),
            priorComparableTotal: fold.hasPriorComparable ? fold.priorComparable : nil,
            promptTokens: fold.promptTokens,
            completionTokens: fold.completionTokens,
            requests: fold.requests,
            currentPromptTokens: fold.headlinePromptTokens,
            currentCompletionTokens: fold.headlineCompletionTokens,
            currentRequests: fold.headlineRequests,
            hasBreakdown: fold.hasBreakdown,
            capabilities: fold.capabilities,
            warnings: fold.warnings,
            generatedAt: .now
        )
    }

    // MARK: - Folding

    private struct Fold {
        var bucketTotals: [Decimal]
        var accumulator: [String: SeriesAccumulator]
        var periodTotals: [SpendWindow: Decimal]
        var capabilities: [ProviderID: ProviderCapabilities]
        var warnings: [String]
        var priorTotal: Decimal = 0
        var priorComparable: Decimal = 0
        var hasPriorData = false
        var hasPriorComparable = false
        var hasBreakdown = false
        var promptTokens = 0
        var completionTokens = 0
        var requests = 0
        var headlineTotal: Decimal = 0
        var headlinePromptTokens = 0
        var headlineCompletionTokens = 0
        var headlineRequests = 0
    }

    private static func fold(
        contributions: [Contribution],
        bucketing: Bucketing,
        grouping: SpendGrouping
    ) -> Fold {
        let bucketCount = bucketing.displayBuckets.count
        var fold = Fold(
            bucketTotals: [Decimal](repeating: 0, count: bucketCount),
            accumulator: [:],
            periodTotals: [:],
            capabilities: [:],
            warnings: []
        )

        for contribution in contributions {
            fold.capabilities[contribution.providerID] = contribution.result.capabilities
            fold.warnings.append(contentsOf: contribution.result.warnings)
            fold.hasBreakdown = fold.hasBreakdown || contribution.result.capabilities.hasBreakdown
            for (window, total) in contribution.result.periodTotals {
                fold.periodTotals[window] = (fold.periodTotals[window] ?? 0) + total
            }

            // Half-open comparisons rather than `DateInterval.contains`, which
            // includes its end date: a slice starting exactly at the end of the
            // headline window belongs to the next period.
            let headline = bucketing.headlineRange
            let priorHeadline = bucketing.priorHeadlineRange
            for slice in contribution.result.slices {
                let inHeadline = slice.start >= headline.start && slice.start < headline.end
                accumulate(
                    slice,
                    at: bucketing.bucketIndex(for: slice.start),
                    inHeadline: inHeadline,
                    grouping: grouping,
                    into: &fold
                )
                if bucketing.containsInPriorPeriod(slice.start) {
                    fold.priorTotal += slice.amount
                    fold.hasPriorData = true
                }
                if let priorHeadline, slice.start >= priorHeadline.start, slice.start < priorHeadline.end {
                    fold.priorComparable += slice.amount
                    fold.hasPriorComparable = true
                }
            }
        }

        return fold
    }

    /// Adds a slice to the chart buckets and, when it falls inside the headline
    /// window, to the headline itself. Keeping the two separate lets the hourly
    /// headline trail across two clock-hour bars.
    private static func accumulate(
        _ slice: SpendSlice,
        at index: Int?,
        inHeadline: Bool,
        grouping: SpendGrouping,
        into fold: inout Fold
    ) {
        // Prior slices feed the delta, never a series; do not create zero rows.
        guard index != nil || inHeadline else { return }

        let key = seriesKey(for: slice, grouping: grouping)
        var entry = fold.accumulator[key] ?? SeriesAccumulator(
            key: key,
            label: seriesLabel(for: slice, grouping: grouping),
            detail: seriesDetail(for: slice, grouping: grouping),
            bucketCount: fold.bucketTotals.count
        )
        if let index {
            fold.bucketTotals[index] += slice.amount
            fold.promptTokens += slice.promptTokens
            fold.completionTokens += slice.completionTokens
            fold.requests += slice.requests
            entry.perBucket[index].amount += slice.amount
            entry.perBucket[index].promptTokens += slice.promptTokens
            entry.perBucket[index].completionTokens += slice.completionTokens
            entry.perBucket[index].requests += slice.requests
            entry.total += slice.amount
            entry.promptTokens += slice.promptTokens
            entry.completionTokens += slice.completionTokens
            entry.requests += slice.requests
        }

        if inHeadline {
            fold.headlineTotal += slice.amount
            fold.headlinePromptTokens += slice.promptTokens
            fold.headlineCompletionTokens += slice.completionTokens
            fold.headlineRequests += slice.requests
            entry.currentAmount += slice.amount
            entry.currentPromptTokens += slice.promptTokens
            entry.currentCompletionTokens += slice.completionTokens
            entry.currentRequests += slice.requests
        }

        fold.accumulator[key] = entry
    }

    // MARK: - Ranking

    /// Sorts series by total and folds everything past `limit` into one "Other"
    /// row, so the chart stays legible without losing money off the top.
    private static func rankedSeries(
        from accumulator: [String: SeriesAccumulator],
        limit: Int
    ) -> [SpendReport.Series] {
        let sorted = accumulator.values.sorted { lhs, rhs in
            if lhs.total == rhs.total {
                return lhs.label < rhs.label
            }
            return lhs.total > rhs.total
        }

        let capped = max(1, limit)
        var series = sorted.prefix(capped).map { $0.series(isOther: false, foldedCount: 0) }

        let overflow = sorted.dropFirst(capped)
        guard !overflow.isEmpty else { return series }

        var other = SeriesAccumulator(
            key: "other",
            label: "Other",
            detail: "\(overflow.count) more",
            bucketCount: sorted.first?.perBucket.count ?? 0
        )
        for entry in overflow {
            other.total += entry.total
            other.currentAmount += entry.currentAmount
            other.promptTokens += entry.promptTokens
            other.completionTokens += entry.completionTokens
            other.requests += entry.requests
            other.currentPromptTokens += entry.currentPromptTokens
            other.currentCompletionTokens += entry.currentCompletionTokens
            other.currentRequests += entry.currentRequests
            for index in other.perBucket.indices where entry.perBucket.indices.contains(index) {
                other.perBucket[index].amount += entry.perBucket[index].amount
                other.perBucket[index].promptTokens += entry.perBucket[index].promptTokens
                other.perBucket[index].completionTokens += entry.perBucket[index].completionTokens
                other.perBucket[index].requests += entry.perBucket[index].requests
            }
        }
        series.append(other.series(isOther: true, foldedCount: overflow.count))
        return series
    }

    private struct SeriesAccumulator {
        var key: String
        var label: String
        var detail: String?
        var perBucket: [SpendReport.BucketValues]
        var total: Decimal = 0
        var currentAmount: Decimal = 0
        var promptTokens = 0
        var completionTokens = 0
        var requests = 0
        var currentPromptTokens = 0
        var currentCompletionTokens = 0
        var currentRequests = 0

        init(key: String, label: String, detail: String?, bucketCount: Int) {
            self.key = key
            self.label = label
            self.detail = detail
            perBucket = [SpendReport.BucketValues](repeating: .init(), count: bucketCount)
        }

        func series(isOther: Bool, foldedCount: Int) -> SpendReport.Series {
            SpendReport.Series(
                id: key,
                label: label,
                detail: detail,
                total: total,
                perBucket: perBucket,
                currentAmount: currentAmount,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                requests: requests,
                currentPromptTokens: currentPromptTokens,
                currentCompletionTokens: currentCompletionTokens,
                currentRequests: currentRequests,
                isOther: isOther,
                foldedCount: foldedCount
            )
        }
    }

    // MARK: - Attribution

    static func seriesKey(for slice: SpendSlice, grouping: SpendGrouping) -> String {
        switch grouping {
        case .model:
            if let model = slice.model, !model.isEmpty {
                return "model:\(slice.providerID.rawValue):\(model)"
            }
            return "model:\(slice.providerID.rawValue):unattributed"
        case .provider:
            if let upstream = slice.upstreamProvider, !upstream.isEmpty {
                return "provider:\(upstream.lowercased())"
            }
            return "provider:\(slice.providerID.rawValue)"
        }
    }

    static func seriesLabel(for slice: SpendSlice, grouping: SpendGrouping) -> String {
        switch grouping {
        case .model:
            guard let model = slice.model, !model.isEmpty else { return "Unattributed" }
            return ModelLabel.shortName(for: model)
        case .provider:
            if let upstream = slice.upstreamProvider, !upstream.isEmpty {
                return upstream
            }
            return slice.providerName
        }
    }

    static func seriesDetail(for slice: SpendSlice, grouping: SpendGrouping) -> String? {
        switch grouping {
        case .model:
            guard let model = slice.model, !model.isEmpty else { return slice.providerName }
            let vendor = ModelLabel.vendor(for: model)
            if let upstream = slice.upstreamProvider, !upstream.isEmpty, upstream.lowercased() != vendor.lowercased() {
                return "\(vendor) · \(upstream)"
            }
            return vendor
        case .provider:
            return nil
        }
    }
}
