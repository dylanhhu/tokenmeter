import Foundation
import TokenMeterKit

/// Credential loading and provider fan-out for `AppModel`.
///
/// None of this touches app state, and all of it must run off the main actor:
/// Keychain reads block until answered and can raise a system prompt, and a
/// provider fetch can take seconds. Doing either on the main actor is how the
/// menu bar item fails to appear.
enum ProviderFetch {
    /// The outcome of one provider's fetch, kept separate from the report so a
    /// failure can be reported alongside the data other providers returned.
    struct Outcome: Sendable {
        var providerID: ProviderID
        var providerName: String
        var result: Result<SpendFetchResult, SpendProviderError>
    }

    static func syntheticProviders(in ids: [ProviderID]) -> Set<ProviderID> {
        Set(ids.filter { ProviderCatalog.descriptor(for: $0)?.isSynthetic == true })
    }

    /// Reads the stored credential for `id`, distinguishing "not cached" from
    /// "cached and absent" so a removed key is not re-read on every refresh.
    static func credential(_ id: ProviderID, in values: [ProviderID: String?]) -> String? {
        guard let entry = values.first(where: { $0.key == id }) else { return nil }
        return entry.value
    }

    /// Loads credentials, reusing anything already cached. Ordering follows `ids`
    /// so the resulting dictionary is deterministic.
    static func loadCredentials(
        for ids: [ProviderID],
        store: CredentialStore,
        cached: [ProviderID: String?]
    ) async -> [ProviderID: String?] {
        var values: [ProviderID: String?] = [:]
        for id in ids where ProviderCatalog.requiresCredential(id: id) {
            if let entry = cached.first(where: { $0.key == id }) {
                values.updateValue(entry.value, forKey: id)
            } else {
                values[id] = try? store.load(for: id)
            }
        }
        return values
    }

    static func makeProviders(
        for ids: [ProviderID],
        credentials: [ProviderID: String?]
    ) -> [(ProviderID, any SpendProvider)] {
        ids.compactMap { id in
            let credential = credential(id, in: credentials)
            guard let provider = ProviderCatalog.makeProvider(id: id, credential: credential) else { return nil }
            return (id, provider)
        }
    }

    /// Fetches every provider concurrently. A provider that throws becomes a
    /// failure outcome rather than failing the whole refresh.
    static func fetchAll(
        providers: [(ProviderID, any SpendProvider)],
        request: SpendRequest
    ) async -> [Outcome] {
        await withTaskGroup(of: Outcome.self) { group in
            for (id, provider) in providers {
                let name = provider.descriptor.displayName
                group.addTask {
                    do {
                        let result = try await withTimeout(seconds: 30) {
                            try await provider.fetchSpend(request)
                        }
                        return Outcome(providerID: id, providerName: name, result: .success(result))
                    } catch let error as SpendProviderError {
                        return Outcome(providerID: id, providerName: name, result: .failure(error))
                    } catch {
                        return Outcome(
                            providerID: id,
                            providerName: name,
                            result: .failure(.network(error.localizedDescription))
                        )
                    }
                }
            }
            var outcomes: [Outcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }
    }

    /// Races an operation against a timeout so one slow provider cannot stall a
    /// refresh indefinitely.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SpendProviderError.network("Timed out after \(Int(seconds))s")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw SpendProviderError.network("No result")
            }
            return value
        }
    }
}
