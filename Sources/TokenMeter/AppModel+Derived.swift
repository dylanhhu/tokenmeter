import Foundation
import TokenMeterKit

/// Read-only views of the state `AppModel` owns: which windows the configured
/// credentials can fill, and what the menu bar renders.
extension AppModel {
    // MARK: - Derived state

    /// Windows that at least one configured provider can fill under `scope`.
    ///
    /// Rolling headlines need rows finer than the display bucket, so a credential
    /// can fill a window without being able to resolve its rolling reading.
    func availableWindows(for scope: WindowScope) -> [SpendWindow] {
        guard !settings.enabledProviders.isEmpty else { return SpendWindow.allCases }
        var supported: Set<SpendWindow> = []
        for id in settings.enabledProviders {
            if let capability = capabilities[id] {
                supported.formUnion(capability.supportedWindows(for: scope))
            } else {
                // Unknown capabilities (first launch, failed probe): do not hide
                // options the user may legitimately want.
                supported.formUnion(SpendWindow.allCases)
            }
        }
        return SpendWindow.allCases.filter { supported.contains($0) }
    }

    var availableWindows: [SpendWindow] {
        availableWindows(for: settings.windowScope)
    }

    /// Whether any enabled provider can resolve a rolling headline at all. When
    /// none can, the popover hides the choice instead of offering a figure that
    /// would silently mean the calendar period.
    var supportsRollingScope: Bool {
        !settings.enabledProviders.isEmpty && !availableWindows(for: .trailing).isEmpty
    }

    /// Whether per-model attribution is available from any provider.
    var hasBreakdown: Bool {
        report?.hasBreakdown ?? capabilities.values.contains(where: \.hasBreakdown)
    }

    var menuBarText: String {
        guard let report else { return "—" }
        let amount = Money.menuBar(report.headlineTotal)
        switch settings.menuBarStyle {
        case .amount, .iconAndAmount: return amount
        case .amountAndWindow:
            return "\(amount) \(report.window.shortTitle(scope: report.scope, duration: report.headlineRange.duration))"
        }
    }

    var menuBarTooltip: String {
        guard let report else { return "TokenMeter — no data yet" }
        return "\(Money.precise(report.headlineTotal)) \(report.headlineCaption)"
    }

    var descriptors: [ProviderDescriptor] {
        ProviderCatalog.descriptors
    }

    var enabledDescriptors: [ProviderDescriptor] {
        settings.enabledProviders.compactMap { ProviderCatalog.descriptor(for: $0) }
    }

    func capability(for id: ProviderID) -> ProviderCapabilities? {
        capabilities[id]
    }

    func hasCredential(_ id: ProviderID) -> Bool {
        connectedProviders.contains(id)
    }
}
