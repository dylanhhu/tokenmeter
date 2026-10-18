import SwiftUI
import TokenMeterKit

/// Window-wide token economics: what a million tokens costs, how much of each
/// request is prompt versus answer, and which model charges the most for the
/// tokens it delivers.
///
/// Everything here covers the whole displayed window, so the caption says so;
/// these figures deliberately do not track the in-progress headline.
struct TokenEfficiencyView: View {
    let efficiency: TokenEfficiency
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Efficiency")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .fixedSize()
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }

            VStack(spacing: 3) {
                HStack(spacing: 10) {
                    stat(efficiency.costPerMillionTokensLabel, "blended")
                    stat(efficiency.outputRatioValueLabel, "out : in")
                }
                HStack(spacing: 10) {
                    stat(efficiency.tokensPerRequestLabel, "tokens / req")
                    stat(efficiency.costPerRequestLabel, "per req")
                }
            }

            if let priciest = efficiency.priciest, let rate = priciest.costPerMillionTokensLabel {
                priciestNote(priciest, rate: rate)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value ?? "—")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func priciestNote(_ row: TokenEfficiency.Row, rate: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
                .padding(.top, 1)
            Text(noteText(row, rate: rate))
                .font(.system(size: 9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
    }

    private func noteText(_ row: TokenEfficiency.Row, rate: String) -> String {
        guard let multiple = row.rateMultiple else {
            return "\(row.label) costs the most per token, \(rate)"
        }
        return "\(row.label) costs the most per token: \(rate), \(String(format: "%.1f", multiple))x blended"
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let rate = efficiency.costPerMillionTokensLabel {
            parts.append("Blended rate \(rate)")
        }
        if let ratio = efficiency.outputRatioLabel {
            parts.append(ratio)
        }
        if let tokens = efficiency.tokensPerRequestLabel {
            parts.append("\(tokens) tokens per request")
        }
        if let cost = efficiency.costPerRequestLabel {
            parts.append("\(cost) per request")
        }
        return "Token efficiency, \(caption). \(parts.joined(separator: ", "))."
    }
}
