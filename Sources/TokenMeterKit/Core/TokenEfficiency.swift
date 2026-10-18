import Foundation

/// What the money bought, per series and across the window.
///
/// Deliberately not a price list: the blended rate is one reading among several,
/// and it only means something next to the token volume and the prompt/output
/// mix that produced it. A model at twice the blended rate is not necessarily
/// wasteful — it may be doing the reasoning while a cheap model handles bulk
/// summarisation.
///
/// Figures cover the whole displayed window rather than the in-progress bucket.
/// A partial hour rarely holds enough tokens for a blended rate or an output
/// ratio to be meaningful, and a number that lurches on every refresh is not a
/// statistic.
public struct TokenEfficiency: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public var detail: String?
        public var isOther: Bool
        public var amount: Decimal
        public var promptTokens: Int
        public var completionTokens: Int
        public var requests: Int
        /// Share of the window's tokens, 0...1.
        public var tokenShare: Double?
        /// Share of the window's spend, 0...1.
        public var spendShare: Double?
        /// Effective rate relative to the window's blended rate. 1.0 means the
        /// series costs exactly the average rate.
        public var rateMultiple: Double?

        public var tokens: Int {
            promptTokens + completionTokens
        }

        /// Blended effective price per million tokens. Blended because the
        /// provider gives prompt and completion volume, not a price per side;
        /// that makes it comparable between models with different output ratios
        /// only approximately, which is why the ratio sits next to it.
        public var costPerMillionTokens: Decimal? {
            guard tokens > 0 else { return nil }
            return amount / Decimal(tokens) * 1_000_000
        }

        public var costPerMillionTokensLabel: String? {
            costPerMillionTokens.map(Money.perMillion)
        }

        public var tokensPerRequest: Double? {
            guard requests > 0 else { return nil }
            return Double(tokens) / Double(requests)
        }

        public var tokensPerRequestLabel: String? {
            tokensPerRequest.map { Int($0.rounded()).compactTokens }
        }

        public var costPerRequest: Decimal? {
            guard requests > 0 else { return nil }
            return amount / Decimal(requests)
        }

        public var costPerRequestLabel: String? {
            costPerRequest.map(Money.precise)
        }

        /// Completion tokens per prompt token. Low means long prompts and short
        /// answers (retrieval, long-context chat); high means the model is doing
        /// most of the writing.
        public var outputRatio: Double? {
            guard promptTokens > 0 else { return nil }
            return Double(completionTokens) / Double(promptTokens)
        }

        /// Share of spend minus share of tokens, in fractional units. Positive
        /// means the series takes a bigger bite of the bill than of the token
        /// volume.
        public var spendTokenGap: Double? {
            guard let spendShare, let tokenShare else { return nil }
            return spendShare - tokenShare
        }
    }

    public var rows: [Row]
    public var amount: Decimal
    public var promptTokens: Int
    public var completionTokens: Int
    public var requests: Int

    public var tokens: Int {
        promptTokens + completionTokens
    }

    /// False when no contributor reported token counts for the window, in which
    /// case the efficiency block and the token measure are both meaningless.
    public var hasData: Bool {
        tokens > 0
    }

    public var costPerMillionTokens: Decimal? {
        guard tokens > 0 else { return nil }
        return amount / Decimal(tokens) * 1_000_000
    }

    public var costPerMillionTokensLabel: String? {
        costPerMillionTokens.map(Money.perMillion)
    }

    public var outputRatio: Double? {
        guard promptTokens > 0 else { return nil }
        return Double(completionTokens) / Double(promptTokens)
    }

    /// "0.29 out : in" reads as one completion token per 3.4 prompt tokens.
    public var outputRatioLabel: String? {
        outputRatio.map { String(format: "%.2f out : in", $0) }
    }

    /// Value only, for dense layouts that supply their own caption.
    public var outputRatioValueLabel: String? {
        outputRatio.map { String(format: "%.2f", $0) }
    }

    public var tokensPerRequest: Double? {
        guard requests > 0 else { return nil }
        return Double(tokens) / Double(requests)
    }

    public var tokensPerRequestLabel: String? {
        tokensPerRequest.map { Int($0.rounded()).compactTokens }
    }

    public var costPerRequest: Decimal? {
        guard requests > 0 else { return nil }
        return amount / Decimal(requests)
    }

    public var costPerRequestLabel: String? {
        costPerRequest.map(Money.precise)
    }

    /// The series paying the highest effective rate, excluding "Other" and
    /// series too small to price reliably.
    ///
    /// A model with a handful of tokens can show an absurd rate purely from
    /// rounding, so a series must hold at least 1% of the window's tokens before
    /// it is eligible to be named.
    public var priciest: Row? {
        guard rows.count > 1 else { return nil }
        let floor = max(100, tokens / 100)
        return rows
            .filter { !$0.isOther && $0.tokens >= floor }
            .max { lhs, rhs in
                (lhs.costPerMillionTokens ?? 0) < (rhs.costPerMillionTokens ?? 0)
            }
    }
}

public extension SpendReport {
    /// Window-wide efficiency readings derived from the same series the
    /// breakdown shows, so the two never disagree about which models exist.
    var efficiency: TokenEfficiency {
        let blended = blendedRate
        let rows = orderedSeries.map { series -> TokenEfficiency.Row in
            var row = TokenEfficiency.Row(
                id: series.id,
                label: series.label,
                detail: series.detail,
                isOther: series.isOther,
                amount: series.total,
                promptTokens: series.promptTokens,
                completionTokens: series.completionTokens,
                requests: series.requests,
                tokenShare: fraction(Double(series.totalTokens), of: Double(totalTokens)),
                spendShare: fraction(series.total.doubleValue, of: grandTotal.doubleValue),
                rateMultiple: nil
            )
            if let blended, blended > 0, let rate = row.costPerMillionTokens {
                row.rateMultiple = (rate / blended).doubleValue
            }
            return row
        }

        return TokenEfficiency(
            rows: rows,
            amount: grandTotal,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            requests: requests
        )
    }

    /// Plain-language span for the efficiency block, e.g. "last 14 days".
    /// It is a whole-window figure, so it must not be captioned like the
    /// in-progress headline.
    var windowSpanLabel: String {
        let count = buckets.count
        return switch window {
        case .hourly: "last \(count)h"
        case .daily: count == 1 ? "today" : "last \(count) days"
        case .weekly: count == 1 ? "this week" : "last \(count) weeks"
        case .monthly: count == 1 ? "this month" : "last \(count) months"
        }
    }

    /// Measures the report has data for. Spend is always offered so the picker
    /// never empties, even for a credential that reports no token counts.
    var supportedMeasures: [BreakdownMeasure] {
        BreakdownMeasure.allCases.filter { measure in
            switch measure {
            case .spend: true
            case .tokens: totalTokens > 0
            case .requests: requests > 0
            }
        }
    }

    private var blendedRate: Decimal? {
        guard totalTokens > 0 else { return nil }
        return grandTotal / Decimal(totalTokens) * 1_000_000
    }
}

extension SpendReport {
    /// Shared guard for the zero-denominator case, so shares are nil rather than
    /// NaN.
    func fraction(_ value: Double, of denominator: Double) -> Double? {
        denominator > 0 ? value / denominator : nil
    }
}
