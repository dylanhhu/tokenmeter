import Charts
import SwiftUI
import TokenMeterKit

/// Stacked bar chart of spend per bucket, one stack segment per series.
struct SpendChart: View {
    let report: SpendReport

    /// Axis configuration comes from the report's own window, not from
    /// separately held settings state. A window switch refreshes in the
    /// background, so the previous report lingers until new data lands;
    /// pairing it with the newly selected window's scale is what made
    /// the chart jump before the update arrived.
    private var window: SpendWindow {
        report.window
    }

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

    /// One x-axis category per bucket.
    ///
    /// Buckets are plotted as categorical bands rather than as date bins: a
    /// date-bin mark is anchored to the leading edge of its bin, so an axis
    /// label sitting on the bucket start hangs off the left side of the bar. A
    /// band centres both the bar and its label.
    ///
    /// The category is a key derived from the start rather than the start
    /// itself, because `Date` is a continuous value to Charts and continuous
    /// axes neither stack marks nor honour a relative bar width. The key is also
    /// unique even when two buckets format to the same label, as an hourly
    /// window spanning midnight does.
    private struct AxisBucket: Hashable {
        let start: Date
        let isCurrent: Bool

        var key: String {
            "\(start.timeIntervalSinceReferenceDate)"
        }
    }

    private var axisBuckets: [AxisBucket] {
        report.buckets.map { AxisBucket(start: $0.start, isCurrent: $0.isCurrent) }
    }

    private func labelledBuckets(in buckets: [AxisBucket]) -> [AxisBucket] {
        window
            .axisLabelIndices(bucketCount: buckets.count, tickCount: window.axisTickCount)
            .map { buckets[$0] }
    }

    private var chart: some View {
        let buckets = axisBuckets
        return Chart {
            ForEach(Array(report.orderedSeries.enumerated()), id: \.element.id) { index, series in
                ForEach(Array(buckets.enumerated()), id: \.element) { bucketIndex, bucket in
                    let amount = series.amounts.indices.contains(bucketIndex) ? series.amounts[bucketIndex] : 0
                    BarMark(
                        x: .value("Time", bucket.key),
                        y: .value("Spend", amount.doubleValue),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(SeriesPalette.color(at: index, isOther: series.isOther))
                    .opacity(bucket.isCurrent ? 1 : 0.88)
                    .cornerRadius(1.5)
                }
            }
        }
        // Room either side so the outermost labels are not clipped by the plot
        // edge now that they are centred on the last band rather than hanging
        // off its leading edge.
        .chartXScale(range: .plotDimension(startPadding: 12, endPadding: 12))
        .chartXAxis {
            AxisMarks(values: labelledBuckets(in: buckets).map(\.key)) { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let bucket = buckets.first(where: { $0.key == key }) {
                        Text(bucket.start.formatted(window.axisFormat))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
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
        return "\(window.title) spend chart. \(parts.joined(separator: ", "))."
    }
}
