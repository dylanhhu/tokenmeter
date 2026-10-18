import Foundation

/// Breakdown rows and the measure machinery that ranks them.
///
/// Kept out of `Aggregation.swift` because a row carries the same period at
/// three resolutions — spend, tokens, and requests — and that is enough detail
/// to deserve its own file.
public extension SpendReport {
    /// One row in the ranked breakdown. It carries spend, tokens, and requests
    /// for the same period so the view can switch measure without re-deriving
    /// anything, and so a token-ranked row can state the share of the bill it
    /// represents.
    struct BreakdownRow: Sendable, Identifiable, Hashable {
        public var series: Series
        /// Quantity this row is measured and ranked by.
        public var measure: BreakdownMeasure
        /// Spend for this row: the current period, or the whole window.
        public var amount: Decimal
        /// Tokens for the same period as `amount`.
        public var tokens: Int
        /// Requests for the same period as `amount`.
        public var requests: Int
        /// Share of the active measure's denominator, 0...1. Nil when that
        /// denominator is zero.
        public var share: Double?
        /// Spend, token, and request shares of the same period, regardless of the
        /// active measure. A token-ranked row uses `spendShare` to show where the
        /// money went.
        public var spendShare: Double?
        public var tokenShare: Double?
        public var requestShare: Double?
        /// Position in the window-wide spend ranking, so a row keeps the same
        /// colour as its stack segment even when the list is re-sorted.
        public var colorIndex: Int

        public var id: String {
            series.id
        }

        /// Value used for ranking; doubles because tokens and requests are
        /// integers and ordering only needs relative magnitude.
        public var measureValue: Double {
            switch measure {
            case .spend: amount.doubleValue
            case .tokens: Double(tokens)
            case .requests: Double(requests)
            }
        }

        public var costPerMillionTokens: Decimal? {
            guard tokens > 0 else { return nil }
            return amount / Decimal(tokens) * 1_000_000
        }

        /// Primary figure for the row, e.g. `$1.24`, `18.3k tok`, `412 req`.
        public var valueLabel: String {
            switch measure {
            case .spend: Money.precise(amount)
            case .tokens: "\(tokens.compactTokens) tok"
            case .requests: "\(requests.compactTokens) req"
            }
        }

        /// Secondary figure: the share of whichever total the row is part of.
        public var shareLabel: String {
            Money.percent(share)
        }

        /// The other reading that makes the row interpretable: the effective rate
        /// when looking at spend, and the share of the bill when looking at token
        /// or request volume.
        public var crossShareLabel: String? {
            switch measure {
            case .spend:
                costPerMillionTokens.map(Money.perMillion)
            case .tokens, .requests:
                spendShare.map { "\(Money.percent($0)) of spend" }
            }
        }
    }

    /// Which interval a set of breakdown rows describes.
    ///
    /// A share is only meaningful against the denominator it was divided by, so
    /// the period travels with the rows instead of being inferred from the
    /// headline. `.bucket` is the one the user picked by clicking a bar; it is
    /// deliberately distinct from `.current`, which stays the in-progress period
    /// behind the headline.
    enum BreakdownPeriod: Hashable, Sendable {
        /// The in-progress period the headline reports.
        case current
        /// Every displayed bucket.
        case window
        /// One chart bucket, identified by its start so it survives a refresh.
        case bucket(Date)
    }

    /// Totals for one breakdown period, the denominator behind every share shown
    /// against it.
    struct PeriodTotals: Sendable, Hashable {
        public var spend: Decimal
        public var tokens: Int
        public var requests: Int
    }

    /// Rows for the headline period, ranked by `measure` and sharing its
    /// denominator. For the hourly window that period is a trailing 60 minutes,
    /// which can overlap two clock-hour buckets.
    func currentBreakdown(measure: BreakdownMeasure = .spend) -> [BreakdownRow] {
        breakdown(for: .current, measure: measure)
    }

    /// Rows for the headline period, ranked by spend. Kept as the default
    /// reading, since it explains the headline figure.
    var currentBreakdown: [BreakdownRow] {
        currentBreakdown(measure: .spend)
    }

    /// Rows summed across every displayed bucket, for "where did the last N
    /// buckets go" reading. Ranked by `measure` across the window.
    func windowBreakdown(measure: BreakdownMeasure = .spend) -> [BreakdownRow] {
        breakdown(for: .window, measure: measure)
    }

    /// Rows summed across every displayed bucket, ranked by spend.
    var windowBreakdown: [BreakdownRow] {
        windowBreakdown(measure: .spend)
    }

    /// The bucket starting at `start`, when the report still holds it.
    func bucket(startingAt start: Date) -> Bucket? {
        bucketIndex(startingAt: start).map { buckets[$0] }
    }

    /// Index of the bucket starting at `start`. A selection is a start date
    /// rather than an index so it survives a refresh that re-cuts the buckets.
    func bucketIndex(startingAt start: Date) -> Int? {
        buckets.firstIndex { $0.start == start }
    }

    /// Caption for the denominator behind a set of rows, e.g. `today`, `14 daily
    /// buckets`, or `2:00 – 3:00 PM` for a selected bar.
    func caption(for period: BreakdownPeriod) -> String {
        switch period {
        case .current: currentBreakdownLabel
        case .window: windowBreakdownLabel
        case let .bucket(start):
            bucket(startingAt: start).map(label(for:)) ?? window.title.lowercased()
        }
    }

    /// Human label for one bucket's interval, in the report's own time zone.
    func label(for bucket: Bucket) -> String {
        window.bucketRangeLabel(start: bucket.start, end: bucket.end, calendar: calendar)
    }

    /// Spend, tokens, and requests for one period. For `.bucket` the spend comes
    /// from the bar itself, so the denominator always equals its height.
    func totals(for period: BreakdownPeriod) -> PeriodTotals {
        switch period {
        case .current:
            return PeriodTotals(spend: currentPeriodTotal, tokens: currentTokens, requests: currentRequests)
        case .window:
            return PeriodTotals(spend: grandTotal, tokens: totalTokens, requests: requests)
        case let .bucket(start):
            guard let index = bucketIndex(startingAt: start) else {
                return PeriodTotals(spend: 0, tokens: 0, requests: 0)
            }
            var totals = PeriodTotals(spend: buckets[index].total, tokens: 0, requests: 0)
            for series in series where series.perBucket.indices.contains(index) {
                totals.tokens += series.perBucket[index].tokens
                totals.requests += series.perBucket[index].requests
            }
            return totals
        }
    }

    /// Denominator for the active measure over the requested period.
    func denominator(for measure: BreakdownMeasure, in totals: PeriodTotals) -> Double {
        switch measure {
        case .spend: totals.spend.doubleValue
        case .tokens: Double(totals.tokens)
        case .requests: Double(totals.requests)
        }
    }

    /// Builds rows for one period, ranking by the active measure while carrying
    /// all three readings so the view can show a row's share of tokens next to
    /// its share of the bill.
    ///
    /// Every period has its own denominator, and that difference is the whole
    /// point of the invariant: a token row under a "$9.50 today" headline must
    /// describe today's tokens, not the window's. `.current` means the headline
    /// interval, which for the hourly window spans two clock-hour buckets rather
    /// than aligning with the last bar. `.bucket` narrows all of that to one bar.
    func breakdown(for period: BreakdownPeriod, measure: BreakdownMeasure = .spend) -> [BreakdownRow] {
        let totals = totals(for: period)
        let measureDenominator = denominator(for: measure, in: totals)

        let rows = orderedSeries.enumerated().compactMap { index, series -> BreakdownRow? in
            guard let values = values(of: series, in: period) else { return nil }
            // A single bar is usually empty for most series; listing them at $0
            // would bury the rows that make up the bar.
            if case .bucket = period, values.amount == 0, values.tokens == 0, values.requests == 0 {
                return nil
            }
            let value = measureValue(measure, amount: values.amount, tokens: values.tokens, requests: values.requests)
            return BreakdownRow(
                series: series,
                measure: measure,
                amount: values.amount,
                tokens: values.tokens,
                requests: values.requests,
                share: fraction(value, of: measureDenominator),
                spendShare: fraction(values.amount.doubleValue, of: totals.spend.doubleValue),
                tokenShare: fraction(Double(values.tokens), of: Double(totals.tokens)),
                requestShare: fraction(Double(values.requests), of: Double(totals.requests)),
                colorIndex: index
            )
        }

        // Ranked by the measure being explained, with "Other" pinned last so a
        // folded row never lands in the middle of the list.
        return rows.sorted { lhs, rhs in
            if lhs.series.isOther != rhs.series.isOther {
                return !lhs.series.isOther
            }
            if lhs.measureValue == rhs.measureValue {
                return lhs.series.label < rhs.series.label
            }
            return lhs.measureValue > rhs.measureValue
        }
    }

    private func measureValue(_ measure: BreakdownMeasure, amount: Decimal, tokens: Int, requests: Int) -> Double {
        switch measure {
        case .spend: amount.doubleValue
        case .tokens: Double(tokens)
        case .requests: Double(requests)
        }
    }

    /// One series' contribution to `period`, or nil when the period cannot
    /// describe it (a bucket that no longer exists).
    private func values(of series: Series, in period: BreakdownPeriod) -> PeriodValues? {
        switch period {
        case .current:
            return PeriodValues(
                amount: series.currentAmount,
                tokens: series.currentTokens,
                requests: series.currentRequests
            )
        case .window:
            return PeriodValues(amount: series.total, tokens: series.totalTokens, requests: series.requests)
        case let .bucket(start):
            guard let index = bucketIndex(startingAt: start), series.perBucket.indices.contains(index) else {
                return nil
            }
            let bucket = series.perBucket[index]
            return PeriodValues(amount: bucket.amount, tokens: bucket.tokens, requests: bucket.requests)
        }
    }
}

/// One series' spend, tokens, and requests for the period being described.
private struct PeriodValues {
    var amount: Decimal
    var tokens: Int
    var requests: Int
}
