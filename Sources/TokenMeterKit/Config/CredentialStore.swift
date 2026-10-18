import Foundation
import Security

public enum CredentialStoreError: Error, LocalizedError, Sendable {
    case keychain(status: OSStatus, operation: String)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case let .keychain(status, operation):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(detail)"
        case .unexpectedData:
            return "Keychain returned an unreadable credential."
        }
    }
}

/// Credentials live in the login keychain, never in the settings file and never
/// in logs.
///
/// Ad-hoc signed development builds get a new code signature on every rebuild,
/// which macOS treats as a different app for keychain ACL purposes. The first
/// read after a rebuild may therefore prompt; choosing "Always Allow" settles it
/// until the next rebuild.
public struct CredentialStore: Sendable {
    public static let defaultService = "com.dylanhu.TokenMeter.credentials"

    private let service: String

    public init(service: String = CredentialStore.defaultService) {
        self.service = service
    }

    public func load(for provider: ProviderID) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.unexpectedData
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status: status, operation: "read")
        }
    }

    public func save(_ secret: String, for provider: ProviderID) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete(for: provider)
            return
        }
        let data = Data(trimmed.utf8)
        let query = baseQuery(for: provider)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            attributes[kSecAttrLabel as String] = "TokenMeter — \(provider.rawValue)"
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(status: addStatus, operation: "write")
            }
        default:
            throw CredentialStoreError.keychain(status: updateStatus, operation: "update")
        }
    }

    public func delete(for provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status, operation: "delete")
        }
    }

    public func contains(_ provider: ProviderID) -> Bool {
        (try? load(for: provider))?.isEmpty == false
    }

    private func baseQuery(for provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
