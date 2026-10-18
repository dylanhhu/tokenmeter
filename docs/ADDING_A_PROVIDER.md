# Adding a provider

A provider is one directory in `Sources/TokenMeterKit/Providers/` plus two lines
in the registry. Nothing in the UI changes.

## What you need to know about the vendor's API

Answer these before writing code:

1. **Auth** — one secret? Bearer token? Provisioning/admin key required?
2. **Endpoint** — can it return cost *and* attribution (model, upstream provider)
   in one call, or only totals?
3. **Granularity** — finest bucket available (`hour`, `day`), and the maximum
   lookback window.
4. **Time zone** — are buckets UTC? Is there an explicit offset parameter?
5. **Limits** — page size, row caps, rate limits.

Record the answers in the adapter's doc comment. Future readers will need them and
the vendor's docs will move.

## Skeleton

```swift
import Foundation

public struct AcmeProvider: SpendProvider {
    public static let providerID: ProviderID = "acme"

    public static let descriptor = ProviderDescriptor(
        id: AcmeProvider.providerID,
        displayName: "Acme",
        summary: "Usage-cost reporting via the Acme admin API.",
        credentialLabel: "Admin key",
        credentialPlaceholder: "acme-sk-…",
        credentialURL: URL(string: "https://acme.example/settings/keys"),
        documentationURL: URL(string: "https://acme.example/docs/costs")
    )

    private let apiKey: String
    private let client: AcmeClient

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.client = AcmeClient(apiKey: apiKey)
    }

    public var descriptor: ProviderDescriptor { Self.descriptor }

    public func probe() async throws -> ProviderCapabilities {
        let account = try await client.account()
        return ProviderCapabilities(
            windows: account.supportsHourly ? Set(SpendWindow.allCases) : [.daily, .weekly, .monthly],
            hasModelBreakdown: account.supportsModels,
            hasProviderBreakdown: false,
            nativeGranularity: account.supportsHourly ? .hourly : .daily,
            notes: []
        )
    }

    public func fetchSpend(_ request: SpendRequest) async throws -> SpendFetchResult {
        // Ask for data at or below request.window resolution, covering
        // request.range (which includes the prior comparison period).
        let granularity = request.window.rank <= SpendWindow.daily.rank ? "hour" : "day"
        let rows = try await client.costs(
            from: request.range.start,
            to: request.range.end,
            granularity: granularity
        )

        let slices = rows.compactMap { row -> SpendSlice? in
            guard let start = FlexibleDate.parse(row.bucket) else { return nil }
            return SpendSlice(
                start: start,
                end: start.addingTimeInterval(granularity == "hour" ? 3600 : 86_400),
                providerID: Self.providerID,
                providerName: Self.descriptor.displayName,
                model: row.model,
                upstreamProvider: nil,
                amount: row.costUSD,
                promptTokens: row.inputTokens,
                completionTokens: row.outputTokens,
                requests: row.requests
            )
        }

        return SpendFetchResult(
            slices: slices,
            capabilities: try await probe()
        )
    }
}
```

Then register it:

```swift
// Sources/TokenMeterKit/Providers/ProviderCatalog.swift
public static let descriptors: [ProviderDescriptor] = [
    OpenRouterProvider.descriptor,
    AcmeProvider.descriptor,          // <- add
    DemoProvider.descriptor,
]

public static func makeProvider(id: ProviderID, credential: String?) -> (any SpendProvider)? {
    switch id {
    case AcmeProvider.providerID:
        guard let credential, !credential.isEmpty else { return nil }
        return AcmeProvider(apiKey: credential)
    // ...
    }
}
```

## Rules the aggregator depends on

- **Bucket no coarser than `request.window`.** A day total placed in an hour
  bucket misrepresents it. If the vendor cannot go finer, remove that window from
  `capabilities` and return nothing for it.
- **Cover `request.range`.** It extends one full period before the visible range
  so the delta badge has a baseline.
- **Leave attribution nil when unknown.** `model: "unknown"` becomes a real series
  named "unknown" and pollutes the legend; `nil` becomes "Unattributed".
- **Prefer slices over `periodTotals`.** Only use `periodTotals` when the vendor
  reports an authoritative current-period figure that cannot be reconstructed
  (as with OpenRouter inference keys).
- **Amounts are `Decimal` USD.** Convert elsewhere, not here.

## Handle these API shapes defensively

Real cost APIs are loosely typed. `FlexibleJSON` and `FlexibleDate` already cover
the common cases:

```swift
FlexibleJSON.decimal(row["cost"])            // number or numeric string
FlexibleJSON.int(row["requests"])            // number or numeric string
FlexibleJSON.timeBucket(in: row)             // date__hour / created_at__day / ...
FlexibleDate.parse(value)                    // ISO with/without fractions, date-only
```

Also check for truncation flags on paginated responses and surface them via
`SpendFetchResult.warnings` rather than silently under-reporting.

## Tests

Add fixture-driven tests next to the existing ones:

```swift
@Test("Acme rows map to slices")
func rowMapping() {
    let rows = [/* recorded JSON, reduced to the fields you read */]
    let slices = AcmeProvider.slices(from: rows)   // expose a pure static mapper
    #expect(slices.first?.model == "acme-large")
    #expect(slices.first?.amount == Decimal(string: "0.0123"))
}
```

Expose the row → slice mapping as a `static` function that takes decoded rows, so
it is testable without a network client. That is how `OpenRouterProvider.slices`
is written, and how its tests avoid mocking `URLSession`.

Include at least one test for the coarsest data the vendor can return, and one for
empty results.

## Checklist

- [ ] Descriptor fields filled in, including `credentialURL`
- [ ] `probe()` returns honest capabilities for the credential in use
- [ ] Adapter issues no requests when `fetchSpend` is called without a credential
- [ ] Errors map onto `SpendProviderError` so the UI can phrase them
- [ ] No credentials in logs
- [ ] Registered in `ProviderCatalog` with a `makeProvider` case
- [ ] Fixture tests for the row mapper
- [ ] `make check` passes
