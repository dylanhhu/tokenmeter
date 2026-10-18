import SwiftUI
import TokenMeterKit

/// Legend and ranking for the chart: one row per series, measured by whichever
/// quantity the user selected.
struct BreakdownList: View {
    let rows: [SpendReport.BreakdownRow]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                self.row(index: index, row: row)
            }
        }
    }

    private func row(index: Int, row: SpendReport.BreakdownRow) -> some View {
        let series = row.series
        let color = SeriesPalette.color(at: row.colorIndex, isOther: series.isOther)
        return HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(series.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if series.isOther, series.foldedCount > 0 {
                        Text("+\(series.foldedCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                ShareBar(
                    fraction: row.share ?? 0,
                    color: color
                )
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(row.valueLabel)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                HStack(spacing: 4) {
                    Text(row.shareLabel)
                    if let cross = row.crossShareLabel {
                        Text("·").foregroundStyle(.quaternary)
                        Text(cross)
                    }
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .help(helpText(for: row))
        .accessibilityElement(children: .combine)
    }

    /// The tooltip has room for the readings the row itself cannot fit: spend,
    /// tokens, and requests for the same period, regardless of the active
    /// measure.
    private func helpText(for row: SpendReport.BreakdownRow) -> String {
        var parts = ["\(row.series.label): \(Money.precise(row.amount))"]
        if row.tokens > 0 {
            parts.append("\(row.tokens.groupedString) tokens")
        }
        if row.requests > 0 {
            parts.append("\(row.requests.groupedString) requests")
        }
        if let rate = row.costPerMillionTokens {
            parts.append("\(Money.perMillion(rate)) blended")
        }
        if let detail = row.series.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }
}
