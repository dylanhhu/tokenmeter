import AppKit
import SwiftUI
import TokenMeterKit

/// The menu bar drop-down: a window selector, the headline figure, the stacked
/// chart, and the ranking that explains it.
struct SpendPopoverView: View {
    let model: AppModel
    /// Bar the tooltip starts pinned to; see `init`.
    private let initialHoverIndex: Int?
    /// How the drop-down asks for the settings window. Injected rather than read
    /// from the scene environment: the panel is hosted by `StatusItemController`
    /// in an `NSWindow`, not by a SwiftUI scene.
    private let openSettingsAction: @MainActor () -> Void

    private let width: CGFloat = 372

    private enum Layout {
        /// Height of the scrollable column.
        ///
        /// A `ScrollView` has no ideal height along its scroll axis, so the
        /// column needs an explicit one or the drop-down collapses to its header
        /// and footer. It is a constant rather than a measurement because the
        /// panel anchors its top edge to the menu bar item: measuring made the
        /// window lurch as data arrived, a provider issue appeared, or a selected
        /// slice added its banner. With a fixed height the chart absorbs the
        /// slack when the breakdown is short, and the list scrolls when it is
        /// long.
        static let contentHeight: CGFloat = 620

        /// Padding around the scrolling column. The column's minimum height is
        /// the viewport minus this, so the padding does not push it into a
        /// permanent scroll.
        static let verticalPadding: CGFloat = 12
    }

    /// Start of the bar the user clicked, or nil while the breakdown describes
    /// the in-progress period. Transient by design: reopening the popover is a
    /// request for the headline reading, not for the slice inspected last time.
    @State private var selection: Date?

    /// - Parameters:
    ///   - initialSelection: bucket to start with selected, and `initialHoverIndex`:
    ///     bar to start with the tooltip pinned to. Both exist for the snapshot
    ///     renderer; a live popover starts on the headline period.
    ///   - openSettings: invoked from the popover's menus and empty state. The
    ///     snapshot renderer passes a no-op.
    init(
        model: AppModel,
        initialSelection: Date? = nil,
        initialHoverIndex: Int? = nil,
        openSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.initialHoverIndex = initialHoverIndex
        openSettingsAction = openSettings
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)

            if let report = model.report, !model.enabledDescriptors.isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        headline(report)
                        if !model.issues.isEmpty {
                            issueList
                        }
                        SpendChart(report: report, selection: $selection, initialHoverIndex: initialHoverIndex)
                        Divider().opacity(0.4)
                        breakdown(report)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, Layout.verticalPadding)
                    // Fill the viewport so the flexible chart takes the slack
                    // instead of leaving a gap above the footer.
                    .frame(
                        minHeight: Layout.contentHeight - Layout.verticalPadding * 2,
                        alignment: .top
                    )
                }
                .frame(height: Layout.contentHeight)
            } else {
                emptyState
            }

            Divider().opacity(0.6)
            footer
        }
        .frame(width: width)
        .onAppear { model.refreshIfStale() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Window", selection: windowBinding) {
                    ForEach(model.availableWindows) { window in
                        Text(window.title).tag(window)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                Menu {
                    Button("Refresh Now") { model.refresh(reason: "manual", force: true) }
                        .keyboardShortcut("r")
                    Button("Settings…") { openSettings() }
                        .keyboardShortcut(",")
                    Divider()
                    Button("Quit TokenMeter") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }

            // The window picker says how wide the period is; this one says where
            // it sits. Labels spell out both readings rather than "calendar" and
            // "rolling", so the figure below is never ambiguous.
            if model.supportsRollingScope {
                Picker("Period", selection: scopeBinding) {
                    ForEach([WindowScope.calendar, .trailing], id: \.self) { scope in
                        Text(model.periodLabel(for: scope)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .help("Switch between the period in progress and the same length of time ending now")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var windowBinding: Binding<SpendWindow> {
        Binding(
            get: { model.settings.menuBarWindow },
            set: { window in
                // The selected bar belongs to the old window's buckets.
                selection = nil
                model.setWindow(window)
            }
        )
    }

    private var scopeBinding: Binding<WindowScope> {
        Binding(
            get: { model.settings.windowScope },
            set: { model.setScope($0) }
        )
    }

    // MARK: - Headline

    private func headline(_ report: SpendReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.precise(report.headlineTotal))
                    .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(report.headlineCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let change = report.priorPeriodChange {
                    DeltaBadge(change: change, caption: report.priorComparisonCaption)
                }
            }

            HStack(spacing: 10) {
                if report.currentTokens > 0 {
                    metric("tokens", report.currentTokens.compactTokens)
                }
                if report.currentRequests > 0 {
                    metric("requests", report.currentRequests.compactTokens)
                }
                if !report.hasBreakdown, report.headlineTotal > 0 {
                    metric("breakdown", "unavailable")
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(value).foregroundStyle(.primary.opacity(0.8))
            Text(label)
        }
    }

    // MARK: - Breakdown

    private func breakdown(_ report: SpendReport) -> some View {
        let measure = effectiveMeasure(report)
        let period = selectedPeriod(in: report)
        let efficiency = report.efficiency
        let rows = report.breakdown(for: period, measure: measure)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Breakdown")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .fixedSize()
                Spacer(minLength: 4)
                if model.hasBreakdown {
                    Picker("Grouping", selection: groupingBinding) {
                        ForEach(SpendGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 140)
                }
                measurePicker(report, selected: measure)
            }

            if period != .current {
                selectionBanner(report, period: period)
            }

            if report.series.isEmpty {
                Text("No attributable spend yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if rows.isEmpty {
                Text("No spend in this slice.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                BreakdownList(rows: rows)
            }

            // Efficiency covers the whole window, so it would contradict a
            // single-slice reading. Show it only when the rows do too.
            if period == .current, efficiency.hasData {
                Divider().opacity(0.35).padding(.vertical, 1)
                TokenEfficiencyView(efficiency: efficiency, caption: report.windowSpanLabel)
            }
        }
    }

    /// The interval the breakdown describes.
    ///
    /// A selection that no longer maps to a bucket — the window changed, or the
    /// hourly window rolled past it — falls back to the headline period instead
    /// of rendering an empty list.
    private func selectedPeriod(in report: SpendReport) -> SpendReport.BreakdownPeriod {
        guard let selection, report.bucketIndex(startingAt: selection) != nil else { return .current }
        return .bucket(selection)
    }

    /// States which bar the rows below describe, and the denominator they share,
    /// so a slice is never mistaken for the headline period.
    private func selectionBanner(_ report: SpendReport, period: SpendReport.BreakdownPeriod) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(report.caption(for: period))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Text(Money.precise(report.totals(for: period).spend))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Show the whole \(report.currentBreakdownLabel) again")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// Falls back to spend when the active measure has no data — a credential
    /// that reports no token counts, or a window with no requests.
    private func effectiveMeasure(_ report: SpendReport) -> BreakdownMeasure {
        let requested = model.settings.breakdownMeasure
        return report.supportedMeasures.contains(requested) ? requested : .spend
    }

    /// Only offered when there is something behind it, so the menu never
    /// advertises a lens that would render an empty list.
    private func measurePicker(_ report: SpendReport, selected: BreakdownMeasure) -> some View {
        Picker("Measure", selection: measureBinding(selected)) {
            ForEach(report.supportedMeasures) { measure in
                Text(measure.title).tag(measure)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.mini)
        .frame(width: 82)
        .help("Rank the breakdown by spend, tokens, or requests")
    }

    private func measureBinding(_ selected: BreakdownMeasure) -> Binding<BreakdownMeasure> {
        Binding(
            get: { selected },
            set: { newValue in model.updateSettings { $0.breakdownMeasure = newValue } }
        )
    }

    private var groupingBinding: Binding<SpendGrouping> {
        Binding(
            get: { model.settings.grouping },
            set: { newValue in model.updateSettings { $0.grouping = newValue } }
        )
    }

    // MARK: - Issues

    private var issueList: some View {
        VStack(spacing: 5) {
            ForEach(model.issues) { issue in
                IssueBanner(issue: issue)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyHeadline)
                .font(.system(size: 12, weight: .semibold))
            Text(emptyBody)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Connect a provider…") { openSettings() }
                    .controlSize(.small)
                Button("Preview with sample data") { model.enableDemoProvider() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
            } else {
                StatusDot(color: statusColor)
            }

            Text(updatedText)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            if let credit = model.accountInfo.values.compactMap(\.remainingCredit).min() {
                Text("·")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("\(Money.currency(credit)) credit left")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var statusColor: Color {
        if !model.issues.isEmpty {
            return .orange
        }
        if model.report == nil {
            return .secondary.opacity(0.5)
        }
        return .green.opacity(0.7)
    }

    private var emptyHeadline: String {
        if model.settings.enabledProviders.isEmpty {
            return "No providers enabled"
        }
        if model.issues.contains(where: \.isCredentialProblem) {
            return "Waiting on a credential"
        }
        return "No spend data yet"
    }

    private var emptyBody: String {
        if model.settings.enabledProviders.isEmpty {
            return "Enable a provider to start tracking what your API usage costs."
        }
        if let issue = model.issues.first {
            return "\(issue.providerName): \(issue.message)"
        }
        return "Nothing has been reported for this range yet."
    }

    private var updatedText: String {
        guard let last = model.lastRefresh else { return "Not refreshed yet" }
        let elapsed = Date.now.timeIntervalSince(last)
        guard elapsed >= 10 else { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: last, relativeTo: .now))"
    }

    private func openSettings() {
        openSettingsAction()
    }
}
