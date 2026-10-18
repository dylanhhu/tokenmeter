import AppKit
import SwiftUI
import TokenMeterKit

/// The menu bar drop-down: a window selector, the headline figure, the stacked
/// chart, and the ranking that explains it.
struct SpendPopoverView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    private let width: CGFloat = 372

    private enum Layout {
        /// Height used for the first layout pass, before the content has been
        /// measured. An explicit non-zero value matters: a `MenuBarExtra` window
        /// asks the content for a size under a proposal that leaves a bare
        /// `ScrollView` at zero height, which collapses the drop-down to its
        /// header and footer.
        static let initialContentHeight: CGFloat = 430

        /// Ceiling on the measured height, so a long breakdown scrolls instead of
        /// growing the popover into the menu bar and the Dock.
        static let maxContentHeight: CGFloat = 620
    }

    /// Height of the scrollable column, measured from its content.
    ///
    /// `MenuBarExtra` sizes its window from the view tree's ideal size, and a
    /// `ScrollView` has none along its scroll axis. Without this the dropped-down
    /// window is only as tall as the fixed header and footer, so the chart and
    /// breakdown never appear regardless of how much data the provider returned.
    @State private var contentHeight: CGFloat = Layout.initialContentHeight

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
                        SpendChart(report: report, bucketing: model.currentBucketing)
                        Divider().opacity(0.4)
                        breakdown(report)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                        }
                    )
                }
                .frame(height: contentHeight)
                .onPreferenceChange(ContentHeightKey.self) { measured in
                    contentHeight = min(max(measured, 200), Layout.maxContentHeight)
                }
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
                Button("Refresh Now") { model.refresh(reason: "manual") }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var windowBinding: Binding<SpendWindow> {
        Binding(
            get: { model.settings.menuBarWindow },
            set: { model.setWindow($0) }
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
                    DeltaBadge(
                        change: change,
                        caption: "Versus the same elapsed time in the previous period"
                    )
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
        let efficiency = report.efficiency
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

            if report.series.isEmpty {
                Text("No attributable spend yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                BreakdownList(rows: report.currentBreakdown(measure: measure))
            }

            if efficiency.hasData {
                Divider().opacity(0.35).padding(.vertical, 1)
                TokenEfficiencyView(efficiency: efficiency, caption: report.windowSpanLabel)
            }
        }
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
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.settings)
    }
}

/// Carries the scrollable column's natural height back up to the frame that
/// constrains it.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
