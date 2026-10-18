# Architecture

TokenMeter answers one question — *what is this costing me right now* — for
providers whose APIs disagree about almost everything: granularity, attribution,
time zones, and what a credential can even read.

## Layers

```mermaid
graph TD
    A[MenuBarExtra + popover] --> B[AppModel<br/>@MainActor state]
    B --> C[ProviderCatalog]
    C --> D[OpenRouterProvider]
    C --> E[DemoProvider]
    C --> F["<future adapter>"]
    D --> G[OpenRouterClient<br/>URLSession]
    D --> H[SpendSlice values]
    E --> H
    H --> I[SpendAggregator]
    I --> J[SpendReport<br/>spend, tokens, requests]
    J --> J2[TokenEfficiency]
    J --> A
    B --> K[CredentialStore<br/>Keychain]
    B --> L[SettingsStore<br/>JSON file]
```

`TokenMeterKit` holds everything below the popover and knows nothing about
SwiftUI. It is a normal SwiftPM library and is tested directly.

## The provider seam

```swift
protocol SpendProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func probe() async throws -> ProviderCapabilities
    func fetchSpend(_ request: SpendRequest) async throws -> SpendFetchResult
}
```

A provider receives a window plus the exact time range to cover, and returns
`SpendSlice` values: one per (bucket, model, upstream provider) it can
distinguish. It never sees charts, grouping, colours, or formatting.

`SpendRequest.range` normally spans the visible buckets *and* the equivalent
prior period, so period-over-period comparison costs no extra round trip.

### Capabilities are per credential, not per vendor

OpenRouter is the motivating case. With a normal inference key, only
`GET /api/v1/key` is readable, which returns this key's own running totals for
the current UTC day, week, and month — no history and no attribution. With a
management key, the analytics API answers arbitrary metric × dimension ×
granularity queries, so hourly series with per-model breakdown become available.

Rather than branching on the vendor inside the UI, the adapter reports what the
credential unlocks:

```swift
ProviderCapabilities(windows: [.daily, .weekly, .monthly],
                     hasModelBreakdown: false, ...)
```

The window picker hides unsupported windows, the grouping control disappears when
there is nothing to group, and `AppModel.coerceWindowIfUnsupported()` moves the
selection if a credential is downgraded while hourly was selected.

### Degradation ladder

For OpenRouter, `fetchSpend` tries, in order:

1. `/analytics/query` grouped by `model` + `provider` at hour granularity
2. the same query at day granularity, if the first came back truncated
3. `/key` period totals, if the credential is an inference key

Each step is reported through `capabilities` or `warnings` so the popover can say
what it is showing rather than quietly presenting a different number.

## Time bucketing

Buckets are **client-side**. Providers are asked for data at or below the target
granularity and the app re-buckets into the user's calendar.

That is deliberate. OpenRouter's day boundaries are UTC; a user in California
means local midnight. Requesting `granularity: "day"` and relabelling those
buckets would shift every bar by seven hours and put spend in the wrong day.

So: hourly and daily windows request hour-level rows (a UTC hour boundary is a
local hour boundary in every zone, since offsets are whole minutes), and
weekly/monthly windows request day-level rows to keep row counts sane, accepting
sub-day skew at the bucket boundary.

The hourly headline is a trailing 60 minutes rather than the current clock hour,
so its boundary generally falls inside an hour bucket. Those two clock hours are
refetched at minute granularity and merged with the coarse history; the cut sits
on a clock-hour boundary so the queries cannot double-count a partial bucket.

`Bucketing` walks calendar components backwards rather than subtracting fixed
durations, so a 23-hour or 25-hour DST day and variable-length months behave
correctly. `BucketingTests.bucketPartition` asserts that every instant in the
displayed range maps to exactly one bucket.

## Aggregation

`SpendAggregator.makeReport` folds N providers into one `SpendReport`:

- **Series** are keyed by grouping mode: `model:<adapter>:<slug>` or
  `provider:<vendor>`. Missing attribution falls back to "Unattributed" and the
  adapter name respectively, so totals always reconcile with what providers
  reported.
- **Other** absorbs everything past `settings.seriesLimit`, preserving the sum.
- **Headline** is the total inside `Bucketing.headlineRange`: the in-progress
  bucket for daily/weekly/monthly, the trailing 60 minutes for hourly. It is
  accumulated separately from the chart buckets, so it may span two bars. A
  provider-reported period total (`periodTotals`) still takes precedence — an
  inference key knows today's exact spend even though it cannot show history.
- **Delta** compares against `priorHeadlineRange`, the equal-length interval
  immediately before the headline (`priorComparableTotal`). Comparing a partial
  day against a whole day would manufacture a misleading number on every refresh.
- **Counters** travel with the same folds: every series carries prompt tokens,
  completion tokens, and requests both across the window and inside the headline
  interval, so token volume is attributed exactly as finely as spend.

## Token measures and efficiency

Spend alone cannot distinguish a cheap model doing most of the work from an
expensive one doing a little. Each `SpendReport` therefore carries the same
period at three resolutions, and `BreakdownMeasure` selects which one the list
ranks and plots:

| Measure | Current-period denominator | Answers |
| --- | --- | --- |
| `spend` | `currentPeriodTotal` | what did this cost |
| `tokens` | `currentTokens` | how much of the work was this |
| `requests` | `currentRequests` | how many calls was this |

`currentBreakdown(measure:)` and `windowBreakdown(measure:)` share one
implementation. The denominator rule from invariant 5 extends to every measure:
a token row under "$9.50 today" describes today's tokens, never the window's.
Every row also carries the fixed `spendShare`, `tokenShare`, and `requestShare`
for its period, so a token-ranked row can state the share of the bill it
represents. That pair — 47% of tokens, 14% of spend — is the point of the
feature; a single percentage of either kind would hide it.

`TokenEfficiency` adds window-wide readings: blended cost per million tokens,
completion-to-prompt ratio, tokens and cost per request, and an effective rate
per series relative to the window's average.

Efficiency deliberately covers the **whole window**, not the headline period.
A partial hour rarely holds enough tokens for a blended rate or an output ratio
to mean anything, and a figure that lurches on every refresh teaches nothing. The
caption ("last 14 days") states the span so the block is never mistaken for the
headline's period.

Two guards keep the derived figures honest:

- A blended rate mixes input and output prices, so it is only comparable between
  models with similar prompt/completion splits. The output ratio is shown beside
  it for that reason; neither is presented alone.
- `priciest` ignores series holding less than 1% of the window's tokens. Forty
  tokens against a dollar of spend implies a five-figure rate, which is rounding,
  not a price anyone paid.

How to read the resulting figures, and where each one misleads, is in
[docs/READING_THE_NUMBERS.md](READING_THE_NUMBERS.md).

## State and failure handling

`AppModel` is a `@MainActor @Observable` singleton. It:

- fans out to enabled providers in a task group, with a per-provider timeout so
  one slow vendor cannot stall a refresh
- retains the last good contribution for any provider that fails, and surfaces
  the failure as a `ProviderIssue` row instead of blanking the chart
- keeps the previous report on screen while a refresh is in flight. A
  report is self-describing — its `window` travels with it — so views
  derive window-scoped configuration (axis scale, labels, the menu-bar
  window suffix) from the report rather than from settings. Pairing a
  stale report with the newly selected window's scale is what made the
  chart jump mid-refresh.
- refreshes on a timer, on wake, on wall-clock change, and when the popover opens
  (only if the data is stale)
- serves the popover and window switching from `SpendResultCache`, which keeps one
  response per (provider, window, time zone) for the refresh interval, and only
  while that response still spans the requested range. Manual refresh, a probe,
  and credential changes bypass or invalidate it
- coerces the selected window when capabilities no longer support it

## Testing

Development is test-first. The money path — bucketing, aggregation, deltas,
conversion of vendor rows into slices — is exactly the kind of code where a bug
is invisible until it has been billing for a week, so the expected number is
written down in a test before the code that produces it. Tests assert on values
(`Decimal` amounts, bucket boundaries, token counts) rather than snapshots,
because a golden image will happily approve a wrong total.

This is also why the pure logic lives in `TokenMeterKit` with no AppKit or
SwiftUI import: a behaviour that can be tested without a window is a behaviour
that can be driven red-to-green. When something seems untestable, it usually
belongs one tier lower.

## Storage

| What | Where | Why |
| --- | --- | --- |
| API keys | login Keychain, service `com.dylanhu.TokenMeter.credentials` | never on disk in plaintext |
| Preferences | `~/Library/Application Support/TokenMeter/settings.json` | inspectable, diffable, easy to reset |
| Logs | unified logging, subsystem `com.dylanhu.TokenMeter` | no credentials, category per concern |

Settings decode defensively: a missing key falls back to the default rather than
discarding the user's configuration after an upgrade.

## Non-goals

- Historical storage. The app reads provider history on demand; it keeps no local
  ledger. That keeps it stateless and avoids reconciling its own numbers against
  the provider's.
- Budget enforcement or alerting. Read-only, by design: management keys cannot
  make inference requests, and this app never needs write access.
