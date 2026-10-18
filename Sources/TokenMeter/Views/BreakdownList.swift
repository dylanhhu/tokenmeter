import SwiftUI
import TokenMeterKit

/// Legend and ranking for the chart: one row per series, with amount and share.
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
                Text(Money.precise(row.amount))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Text(row.share.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .help(series.detail ?? series.label)
        .accessibilityElement(children: .combine)
    }
}
