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

    /// Rows for the headline period, ranked by `measure` and sharing its
    /// denominator. For the hourly window that period is a trailing 60 minutes,
    /// which can overlap two clock-hour buckets.
    func currentBreakdown(measure: BreakdownMeasure = .spend) -> [BreakdownRow] {
        breakdown(measure: measure, current: true)
    }

    /// Rows for the headline period, ranked by spend. Kept as the default
    /// reading, since it explains the headline figure.
    var currentBreakdown: [BreakdownRow] {
        currentBreakdown(measure: .spend)
    }

    /// Rows summed across every displayed bucket, for "where did the last N
    /// buckets go" reading. Ranked by `measure` across the window.
    func windowBreakdown(measure: BreakdownMeasure = .spend) -> [BreakdownRow] {
        breakdown(measure: measure, current: false)
    }

    /// Rows summed across every displayed bucket, ranked by spend.
    var windowBreakdown: [BreakdownRow] {
        windowBreakdown(measure: .spend)
    }

    /// Denominator for the active measure over the requested period.
    func denominator(for measure: BreakdownMeasure, current: Bool) -> Double {
        switch measure {
        case .spend: (current ? currentPeriodTotal : grandTotal).doubleValue
        case .tokens: Double(current ? currentTokens : totalTokens)
        case .requests: Double(current ? currentRequests : requests)
        }
    }

    /// Builds rows for one period, ranking by the active measure while carrying
    /// all three readings so the view can show a row's share of tokens next to
    /// its share of the bill.
    ///
    /// The current and window denominators differ, and that difference is the
    /// whole point of the invariant: a token row under a "$9.50 today" headline
    /// must describe today's tokens, not the window's. "Current" means the
    /// headline interval, which for the hourly window spans two clock-hour
    /// buckets rather than aligning with the last bar.
    private func breakdown(measure: BreakdownMeasure, current: Bool) -> [BreakdownRow] {
        let spendDenominator = denominator(for: .spend, current: current)
        let tokenDenominator = denominator(for: .tokens, current: current)
        let requestDenominator = denominator(for: .requests, current: current)

        let rows = orderedSeries.enumerated().map { index, series -> BreakdownRow in
            let amount = current ? series.currentAmount : series.total
            let tokens = current
                ? series.currentPromptTokens + series.currentCompletionTokens
                : series.totalTokens
            let requestCount = current ? series.currentRequests : series.requests
            let value = measureValue(measure, amount: amount, tokens: tokens, requests: requestCount)
            let measureDenominator = denominator(for: measure, current: current)
            return BreakdownRow(
                series: series,
                measure: measure,
                amount: amount,
                tokens: tokens,
                requests: requestCount,
                share: fraction(value, of: measureDenominator),
                spendShare: fraction(amount.doubleValue, of: spendDenominator),
                tokenShare: fraction(Double(tokens), of: tokenDenominator),
                requestShare: fraction(Double(requestCount), of: requestDenominator),
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
}
