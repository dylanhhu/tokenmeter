import Charts
import SwiftUI
import TokenMeterKit

/// Stacked bar chart of spend per bucket, one stack segment per series.
struct SpendChart: View {
    let report: SpendReport
    let bucketing: Bucketing

    private var hasValues: Bool {
        report.series.contains { series in series.amounts.contains { $0 > 0 } }
    }

    var body: some View {
        Group {
            if hasValues {
                chart
            } else {
                placeholder
            }
        }
        // Flexible above the floor: when the breakdown is short, the popover's
        // leftover height goes here instead of into empty space below the list.
        .frame(minHeight: 156)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(report.orderedSeries.enumerated()), id: \.element.id) { index, series in
                ForEach(Array(report.buckets.enumerated()), id: \.element.id) { bucketIndex, bucket in
                    let amount = series.amounts.indices.contains(bucketIndex) ? series.amounts[bucketIndex] : 0
                    BarMark(
                        x: .value("Time", bucket.start, unit: bucketing.window.bucketComponent),
                        y: .value("Spend", amount.doubleValue),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(SeriesPalette.color(at: index, isOther: series.isOther))
                    .opacity(bucket.isCurrent ? 1 : 0.88)
                    .cornerRadius(1.5)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: bucketing.window.axisTickCount)) { _ in
                AxisValueLabel(format: bucketing.window.axisFormat)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Money.compact(Decimal(amount)))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.top, 4)
        }
        .animation(.easeOut(duration: 0.2), value: report.series.map(\.id))
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 16, weight: .light))
            Text("No spend in this range")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilitySummary: String {
        let parts = report.orderedSeries.prefix(4).map { "\($0.label) \(Money.compact($0.total))" }
        return "\(bucketing.window.title) spend chart. \(parts.joined(separator: ", "))."
    }
}
