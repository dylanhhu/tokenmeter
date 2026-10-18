import Foundation

/// Formatting helpers for USD amounts. The whole app tracks spend as `Decimal`
/// so that summing many small per-generation charges does not accumulate
/// binary-float error.
public enum Money {
    public static let zero = Decimal.zero

    private static let halfCent = Decimal(string: "0.005")!
    private static let oneCent = Decimal(string: "0.01")!
    private static let thousand = Decimal(1_000)
    private static let million = Decimal(1_000_000)

    /// Locale-aware currency rendering, e.g. `$1.23`.
    public static func currency(_ amount: Decimal, fractionDigits: Int = 2) -> String {
        amount.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(fractionDigits))
        )
    }

    /// Adaptive precision for detail views: tiny amounts get four decimals so
    /// they do not all render as `$0.00`.
    public static func precise(_ amount: Decimal) -> String {
        let magnitude = amount.magnitude
        if magnitude > 0, magnitude < halfCent {
            return currency(amount, fractionDigits: 4)
        }
        return currency(amount, fractionDigits: 2)
    }

    /// Compact form for axis labels and dense rows: `$0.01`, `$12.40`, `$1.2k`.
    public static func compact(_ amount: Decimal) -> String {
        let magnitude = amount.magnitude
        if magnitude >= million {
            return scaled(amount, by: million, suffix: "M")
        }
        if magnitude >= thousand {
            return scaled(amount, by: thousand, suffix: "k")
        }
        return currency(amount, fractionDigits: 2)
    }

    /// Tightest useful representation for the menu bar, where horizontal space
    /// is scarce and a fixed width avoids the label jittering on every refresh.
    public static func menuBar(_ amount: Decimal) -> String {
        let magnitude = amount.magnitude
        if magnitude >= thousand {
            return compact(amount)
        }
        if magnitude > 0, magnitude < oneCent {
            return currency(amount, fractionDigits: 4)
        }
        return currency(amount, fractionDigits: 2)
    }

    /// Percentage of a total, e.g. `12.4%`.
    public static func share(_ part: Decimal, of total: Decimal) -> String {
        guard total > 0 else { return "—" }
        let fraction = (part / total)
        let percent = NSDecimalNumber(decimal: fraction * 100).doubleValue
        if percent > 0, percent < 0.1 {
            return "<0.1%"
        }
        return String(format: "%.1f%%", percent)
    }

    private static func scaled(_ amount: Decimal, by divisor: Decimal, suffix: String) -> String {
        let value = NSDecimalNumber(decimal: amount / divisor).doubleValue
        let digits = abs(value) >= 100 ? 0 : 1
        return String(format: "$%.\(digits)f%@", value, suffix)
    }
}

public extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }

    /// Rounds to `places` decimal digits using banker's rounding, matching what
    /// ledgers and invoices typically do.
    func rounded(places: Int) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, places, .bankers)
        return result
    }
}

public extension Int {
    /// `12,345` for tables, `12.3k` when space matters.
    var groupedString: String {
        formatted(.number)
    }

    var compactTokens: String {
        formatted(.number.notation(.compactName))
    }
}
