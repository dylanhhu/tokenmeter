import SwiftUI
import TokenMeterKit

/// Chart colours. Chosen to stay distinguishable in light and dark appearance at
/// the small sizes used in a popover, and to read in stacked-bar adjacency.
enum SeriesPalette {
    private static let colors: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.98),
        Color(red: 0.05, green: 0.68, blue: 0.62),
        Color(red: 0.95, green: 0.63, blue: 0.13),
        Color(red: 0.90, green: 0.36, blue: 0.55),
        Color(red: 0.62, green: 0.42, blue: 0.98),
        Color(red: 0.24, green: 0.70, blue: 0.42),
        Color(red: 0.16, green: 0.62, blue: 0.86),
        Color(red: 0.90, green: 0.45, blue: 0.27),
    ]

    static func color(at index: Int, isOther: Bool = false) -> Color {
        if isOther {
            return Color.secondary.opacity(0.45)
        }
        return colors[index % colors.count]
    }
}

struct DeltaBadge: View {
    let change: Double
    let caption: String

    var body: some View {
        let positive = change >= 0
        HStack(spacing: 3) {
            Image(systemName: positive ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 8, weight: .bold))
            Text(String(format: "%.0f%%", abs(change) * 100))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(positive ? Color.orange : Color.green)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill((positive ? Color.orange : Color.green).opacity(0.14))
        )
        .help(caption)
        .accessibilityLabel(caption)
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}

/// Shown when a provider returns a non-fatal problem (missing key, truncation,
/// degraded credential tier).
struct IssueBanner: View {
    let issue: ProviderIssue

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: issue.isCredentialProblem ? "key.slash" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(issue.isCredentialProblem ? Color.secondary : Color.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(issue.providerName)
                    .font(.system(size: 10, weight: .semibold))
                Text(issue.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// Thin proportional bar used in the breakdown rows.
struct ShareBar: View {
    let fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
    }
}

extension SpendReport {
    /// Series ordered for display: descending by total, with "Other" always last.
    var orderedSeries: [SpendReport.Series] {
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
}

extension SpendWindow {
    /// Format used for x-axis tick labels.
    var axisFormat: Date.FormatStyle {
        switch self {
        case .hourly: .dateTime.hour()
        case .daily: .dateTime.month(.defaultDigits).day()
        case .weekly: .dateTime.month(.abbreviated).day()
        case .monthly: .dateTime.month(.abbreviated)
        }
    }

    var axisTickCount: Int {
        switch self {
        case .hourly: 4
        case .daily: 5
        case .weekly: 4
        case .monthly: 6
        }
    }
}
