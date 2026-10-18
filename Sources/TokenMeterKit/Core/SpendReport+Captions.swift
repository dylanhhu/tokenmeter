import Foundation

/// Captions for the figures in a `SpendReport`. They live apart from the
/// aggregation so the wording of a period is stated once, next to the scope it
/// depends on.
public extension SpendReport {
    /// Caption for the denominator behind `currentBreakdown`.
    var currentBreakdownLabel: String {
        headlineCaption
    }

    /// Caption for the denominator behind `windowBreakdown`.
    var windowBreakdownLabel: String {
        "\(buckets.count) \(window.title.lowercased()) buckets"
    }

    var priorPeriodCaption: String? {
        guard let priorPeriodTotal, priorPeriodTotal > 0 else { return nil }
        let noun = switch scope {
        case .calendar: "Previous \(window.title.lowercased()) period"
        case .trailing: "Previous \(periodSpan)"
        }
        return "\(noun): \(Money.precise(priorPeriodTotal))"
    }

    /// Caption for the delta badge, which must not promise a comparison the
    /// scope does not make: a rolling period is compared against a whole prior
    /// interval, a calendar period against the same elapsed slice of one.
    var priorComparisonCaption: String {
        switch scope {
        case .calendar: "Versus the same elapsed time in the previous period"
        case .trailing: "Versus the previous \(periodSpan)"
        }
    }

    /// Label describing the headline figure, e.g. "this week" or "last 7 days".
    var headlineCaption: String {
        window.headlineLabel(scope: scope, duration: headlineRange.duration)
    }

    /// Length of the headline period as a noun, e.g. "7 days".
    private var periodSpan: String {
        let label = window.headlineLabel(scope: .trailing, duration: headlineRange.duration)
        return label.hasPrefix("last ") ? String(label.dropFirst("last ".count)) : label
    }
}
