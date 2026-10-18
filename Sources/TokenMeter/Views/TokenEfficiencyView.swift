import SwiftUI
import TokenMeterKit

/// Window-wide token economics: what a million tokens costs, how much of each
/// request is prompt versus answer, and which model carries the highest
/// effective rate against the window average.
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
                    stat(efficiency.costPerMillionTokensLabel, "blended in + out")
                    stat(efficiency.outputRatioValueLabel, "out : in")
                }
                HStack(spacing: 10) {
                    stat(efficiency.tokensPerRequestLabel, "tokens / req")
                    stat(efficiency.costPerRequestLabel, "per req")
                }
            }
            .help(TokenEfficiency.blendedRateDefinition)

            if let note = efficiency.priciestNote {
                priciestNote(note)
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

    private func priciestNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .help(TokenEfficiency.priciestRule)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let rate = efficiency.costPerMillionTokensSpoken {
            parts.append("Blended rate \(rate) across prompt and completion tokens")
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
        var summary = "Token efficiency, \(caption). \(parts.joined(separator: ", "))."
        if let note = efficiency.priciestNoteSpoken {
            summary += " \(note)."
        }
        return summary
    }
}
