import Charts
import SwiftUI
import TokenMeterKit

/// Stacked bar chart of spend per bucket, one stack segment per series.
///
/// A bar is a period, so it can be inspected directly: hovering shows the
/// bucket's interval and total, and clicking selects it for the breakdown below.
struct SpendChart: View {
    let report: SpendReport
    /// Start of the selected bucket, or nil when the breakdown describes the
    /// in-progress period. Owned by the popover, which draws the breakdown.
    @Binding var selection: Date?
    @State private var hoveredIndex: Int?

    /// - Parameter initialHoverIndex: bucket the tooltip starts pinned to. Only
    ///   the snapshot renderer passes this; a live chart starts with no tooltip.
    init(report: SpendReport, selection: Binding<Date?>, initialHoverIndex: Int? = nil) {
        self.report = report
        _selection = selection
        _hoveredIndex = State(initialValue: initialHoverIndex)
    }

    /// Axis configuration comes from the report's own window, not from
    /// separately held settings state. A window switch refreshes in the
    /// background, so the previous report lingers until new data lands;
    /// pairing it with the newly selected window's scale is what made
    /// the chart jump before the update arrived.
    private var window: SpendWindow {
        report.window
    }

    private var hasValues: Bool {
        report.series.contains { series in series.perBucket.contains { $0.amount > 0 } }
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return report.bucketIndex(startingAt: selection)
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
        // A hover index belongs to the bucket layout it was measured against.
        .onChange(of: report.window) { _, _ in hoveredIndex = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Unique x-axis category for a bucket.
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
    private func key(for bucket: SpendReport.Bucket) -> String {
        "\(bucket.start.timeIntervalSinceReferenceDate)"
    }

    private func bucket(forKey key: String, in buckets: [SpendReport.Bucket]) -> SpendReport.Bucket? {
        buckets.first { self.key(for: $0) == key }
    }

    private func labelledBuckets(in buckets: [SpendReport.Bucket]) -> [SpendReport.Bucket] {
        window
            .axisLabelIndices(bucketCount: buckets.count, tickCount: window.axisTickCount)
            .map { buckets[$0] }
    }

    private var chart: some View {
        let buckets = report.buckets
        return Chart {
            ForEach(Array(report.orderedSeries.enumerated()), id: \.element.id) { index, series in
                ForEach(Array(buckets.enumerated()), id: \.element.id) { bucketIndex, bucket in
                    let amount = series.perBucket.indices.contains(bucketIndex)
                        ? series.perBucket[bucketIndex].amount
                        : 0
                    BarMark(
                        x: .value("Time", key(for: bucket)),
                        y: .value("Spend", amount.doubleValue),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(SeriesPalette.color(at: index, isOther: series.isOther))
                    .opacity(opacity(at: bucketIndex, isCurrent: bucket.isCurrent))
                    .cornerRadius(1.5)
                }
            }
        }
        // Room either side so the outermost labels are not clipped by the plot
        // edge now that they are centred on the last band rather than hanging
        // off its leading edge.
        .chartXScale(range: .plotDimension(startPadding: 12, endPadding: 12))
        .chartXAxis {
            AxisMarks(values: labelledBuckets(in: buckets).map { key(for: $0) }) { value in
                AxisValueLabel {
                    if let axisKey = value.as(String.self), let bucket = bucket(forKey: axisKey, in: buckets) {
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    pointerSurface(proxy: proxy, plot: plot, buckets: buckets)
                    if let hoveredIndex, buckets.indices.contains(hoveredIndex) {
                        let bucket = buckets[hoveredIndex]
                        hoverBand(for: bucket, proxy: proxy, plot: plot, buckets: buckets)
                        tooltip(for: bucket, proxy: proxy, plot: plot, buckets: buckets)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: report.series.map(\.id))
    }

    /// Opacity that keeps the selected bar at full strength and fades the rest,
    /// so a click reads as "this slice" without hiding the shape of the window.
    private func opacity(at index: Int, isCurrent: Bool) -> Double {
        guard let selectedIndex else { return isCurrent ? 1 : 0.88 }
        return index == selectedIndex ? 1 : 0.3
    }

    // MARK: - Pointer handling

    /// Transparent surface over the plot that turns pointer locations into
    /// buckets. Both gestures and hover go through `bucketIndex(at:)`, so a
    /// click and the tooltip always agree about which bar is under the pointer.
    private func pointerSurface(proxy: ChartProxy, plot: CGRect, buckets: [SpendReport.Bucket]) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    // Hover fires on every pointer move; only a band change is
                    // worth re-rendering the marks for.
                    let index = bucketIndex(at: location, proxy: proxy, plot: plot, buckets: buckets)
                    if index != hoveredIndex {
                        hoveredIndex = index
                    }
                case .ended:
                    hoveredIndex = nil
                }
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let index = bucketIndex(
                            at: value.location,
                            proxy: proxy,
                            plot: plot,
                            buckets: buckets
                        ) else { return }
                        toggleSelection(buckets[index].start)
                    }
            )
    }

    /// Nearest bucket to a pointer location, or nil outside the plot area.
    ///
    /// Band centres come from `ChartProxy` because it accounts for the plot's
    /// horizontal padding; deriving them from the plot width would put the
    /// first and last bars half a band off.
    private func bucketIndex(
        at location: CGPoint,
        proxy: ChartProxy,
        plot: CGRect,
        buckets: [SpendReport.Bucket]
    ) -> Int? {
        guard plot.width > 0, plot.insetBy(dx: -1, dy: -1).contains(location) else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, bucket) in buckets.enumerated() {
            guard let position = proxy.position(forX: key(for: bucket)) else { continue }
            let distance = abs(plot.minX + position - location.x)
            if distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Clicking the selected bar again returns the breakdown to the in-progress
    /// period, so the selection needs no separate dismiss control.
    private func toggleSelection(_ start: Date) {
        selection = selection == start ? nil : start
    }

    // MARK: - Tooltip

    private func hoverBand(
        for bucket: SpendReport.Bucket,
        proxy: ChartProxy,
        plot: CGRect,
        buckets: [SpendReport.Bucket]
    ) -> some View {
        let band = bandWidth(proxy: proxy, plot: plot, buckets: buckets)
        let center = plot.minX + (proxy.position(forX: key(for: bucket)) ?? plot.midX)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: band, height: plot.height)
            .offset(x: center - band / 2, y: plot.minY)
            .allowsHitTesting(false)
    }

    private func tooltip(
        for bucket: SpendReport.Bucket,
        proxy: ChartProxy,
        plot: CGRect,
        buckets: [SpendReport.Bucket]
    ) -> some View {
        let width: CGFloat = 150
        let center = plot.minX + (proxy.position(forX: key(for: bucket)) ?? plot.midX)
        let lowest = min(plot.minX + width / 2, plot.midX)
        let highest = max(plot.maxX - width / 2, plot.midX)
        // Sit above the top of the stack, but never above the plot itself.
        let stackTop = plot.minY + (proxy.position(forY: bucket.total.doubleValue) ?? plot.minY)
        let totals = report.totals(for: .bucket(bucket.start))
        return BucketTooltip(
            rangeLabel: report.label(for: bucket),
            amount: bucket.total,
            tokens: totals.tokens,
            requests: totals.requests
        )
        .frame(width: width)
        .offset(x: min(max(center, lowest), highest) - width / 2, y: max(plot.minY, stackTop - 36))
        .allowsHitTesting(false)
    }

    /// Width of one band, minus a hairline so adjacent hover highlights do not
    /// touch.
    private func bandWidth(proxy: ChartProxy, plot: CGRect, buckets: [SpendReport.Bucket]) -> CGFloat {
        guard buckets.count > 1,
              let first = proxy.position(forX: key(for: buckets[0])),
              let last = proxy.position(forX: key(for: buckets[buckets.count - 1])),
              last > first
        else {
            return plot.width / CGFloat(max(buckets.count, 1))
        }
        return (last - first) / CGFloat(buckets.count - 1) * 0.9
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
        var summary = "\(window.title) spend chart. \(parts.joined(separator: ", "))."
        if let selectedIndex, report.buckets.indices.contains(selectedIndex) {
            summary += " Showing the breakdown for \(report.label(for: report.buckets[selectedIndex]))."
        }
        return summary
    }
}

/// Floating readout for the bar under the pointer: its interval, then what the
/// interval cost. Fixed width so the caller can clamp it inside the plot without
/// measuring it first.
private struct BucketTooltip: View {
    let rangeLabel: String
    let amount: Decimal
    let tokens: Int
    let requests: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(rangeLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(Money.precise(amount))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                if tokens > 0 {
                    Text("· \(tokens.compactTokens) tok")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else if requests > 0 {
                    Text("· \(requests.compactTokens) req")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
