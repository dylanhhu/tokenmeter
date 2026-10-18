import Foundation

/// Registry of known adapters.
///
/// Adding a provider is a two-step change: implement `SpendProvider` in
/// `Sources/TokenMeterKit/Providers/<Name>/`, then append its descriptor and
/// factory here. Nothing in the app layer needs to change — the settings list,
/// capability gating, chart, and menu bar are all driven by the protocol.
public enum ProviderCatalog {
    /// Descriptors for every adapter the build knows about, in display order.
    public static let descriptors: [ProviderDescriptor] = [
        OpenRouterProvider.descriptor,
        DemoProvider.descriptor,
    ]

    public static func descriptor(for id: ProviderID) -> ProviderDescriptor? {
        descriptors.first { $0.id == id }
    }

    /// Instantiates an adapter. Returns nil when the descriptor is unknown or a
    /// required credential is absent.
    public static func makeProvider(id: ProviderID, credential: String?) -> (any SpendProvider)? {
        switch id {
        case OpenRouterProvider.descriptor.id:
            guard let credential, !credential.isEmpty else { return nil }
            return OpenRouterProvider(apiKey: credential)
        case DemoProvider.descriptor.id:
            return DemoProvider()
        default:
            return nil
        }
    }

    /// Providers that need no credential (used for the synthetic demo adapter).
    public static func requiresCredential(id: ProviderID) -> Bool {
        descriptor(for: id)?.isSynthetic == false
    }

    public static var realProviderIDs: [ProviderID] {
        descriptors.filter { !$0.isSynthetic }.map(\.id)
    }
}
