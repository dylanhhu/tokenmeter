# Architecture

TokenMeter answers one question — *what is this costing me right now* — for
providers whose APIs disagree about almost everything: granularity, attribution,
time zones, and what a credential can even read.

## Layers

```mermaid
graph TD
    A[NSStatusItem + drop-down panel] --> B[AppModel<br/>@MainActor state]
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

## The menu bar item and its drop-down

The app is an AppKit application with SwiftUI views: `StatusItemController` owns
an `NSStatusItem` and `PopoverPanel` hosts `SpendPopoverView`. `MenuBarExtra` is
deliberately not used. On macOS 27 the menu bar is composed by `MenuBarAgent` as
a single window, and a bar reader — Bartender among them — finds an item by the
accessibility identifier on its button. `MenuBarExtra` never sets one: reading
`AXIdentifier` returns `kAXErrorFailure` (-25200), which Bartender reports as
"could not read the item's accessibility identity", and the item cannot be
tracked. `MenuBarExtra` also cannot take part in expanded interface sessions, the
macOS 27 mechanism that keeps a custom drop-down in step with menu bar tracking.
Both need the item to be ours.

`MenuBarLabel` separates the two things the item carries: a constant
accessibility identity and name, and the live reading in the title and tooltip.
An identity derived from the figure would be useless to anything that stores it.
Bartender derives identity keys from the accessibility title as well as the
identifier, so the reading goes in the accessibility value instead. The item has
no explicit autosave name: AppKit's default, `Item-0`, is the slot key macOS and
Bartender have recorded (`status:com.dylanhu.TokenMeter::Item-0`), and renaming
it presents a new item that a manager may file under Hidden.

### Menu bar managers on macOS 27

Bartender 7 hides items by holding a `MenuBarAgent` visibility restriction, an
allow-list of bundle identifiers
(`acquireAssertionWithID:origin:allowedSystemItems:allowedBundleIdentifiers:`).
Items whose app is not on the list are withdrawn from the bar; the manager's
reveal control, or quitting the manager, drops the restriction.

`MenuBarAgent` only honours that list for apps installed in `/Applications`. A
copy run from `build/`, a worktree, `~/Applications`, or anywhere else in the
home folder is withdrawn for as long as the manager hides anything, even though
the manager lists its bundle identifier, and returns when the restriction drops.
This was established with otherwise identical probe apps in each location. The
likely mechanism is that `MenuBarAgent` is sandboxed and asks LaunchServices for
application information restricted to what it may read, which excludes the home
folder. To see the real item under a manager, install with `make install` and run
`/Applications/TokenMeter.app`.

The symptom is visible in `MenuBarAgent`'s log: the item's
`com.apple.appkit.status-items` scenes are unregistered at the moment of
`didActivateVisibilityRestriction`, alongside the items the manager hides on
purpose.

On macOS 27 the system starts an expanded interface session when the item is
clicked and ends it when the interaction does; the controller shows the panel in
`statusItem(_:didBegin:)` and hides it in
`statusItemDidEndExpandedInterfaceSession(_:animated:)`. Closing the panel from
inside the app cancels `expandedInterfaceSession` so the session unwinds. Before
27 there are no sessions, so a button target/action toggles the panel and event
monitors supply Escape and click-outside dismissal.

Position is the other half of what the old shell handled. The panel is placed
once, when it is shown, and `PopoverPlacement` holds its top edge while the
content changes height, so data arriving mid-read grows it downward instead of
under the menu bar. The horizontal pin the previous `MenuBarExtra` shell needed
is gone: a panel placed under the item does not follow the item when a refresh
widens the label.

macOS 27 leaves `NSStatusItem.button.window` as a stub at the origin, so an item
frame is only used when it intersects a menu bar band. `PopoverPlacement.anchor`
otherwise falls back to the pointer, which is on the item when a session was
started by clicking it; Bartender reveals the item and replays that click, so a
drop-down opened from the Bartender bar is covered by the same rule.

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

The headline is not always bucket-aligned. `WindowScope.trailing` reports one
bucket's length ending now — the last 60 minutes, 24 hours, 7 days, or as many
days as the current month has — so its start and end generally fall inside a
bucket. The aggregator only counts slices that *start* inside the headline, so a
provider that can go finer refetches the coarse bucket each boundary falls in:
a minute for hourly and daily windows, an hour for weekly and monthly ones.
Segments are contiguous and half-open, so no bucket is dropped or counted twice,
and the residual error is bounded by one fine bucket rather than one chart bar.
A provider that cannot refine a window reports it in `rollingWindows` instead of
`windows`, and the UI withholds that reading.

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
- **Headline** is the total inside `Bucketing.headlineRange`: under
  `.calendar` the in-progress bucket, under `.trailing` the equal-length interval
  ending now. It is accumulated separately from the chart buckets, so it may span
  two bars. A provider-reported period total (`periodTotals`) still takes
  precedence under `.calendar` — an inference key knows today's exact spend even
  though it cannot show history — but never under `.trailing`, where a calendar
  total would be a different quantity wearing the same caption.
- **Delta** compares against `priorHeadlineRange`, the equal-length interval
  immediately before the headline (`priorComparableTotal`). Comparing a partial
  day against a whole day would manufacture a misleading number on every refresh.
  A rolling headline is compared against a whole prior interval, which the badge
  caption states.
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

`currentBreakdown(measure:)` and `windowBreakdown(measure:)` are two cases of
`breakdown(for:measure:)`, which takes a `BreakdownPeriod`: the headline
interval, the whole window, or one clicked bucket. The denominator rule from
invariant 5 extends to every measure: a token row under "$9.50 today" describes
today's tokens, never the window's. Every row also carries the fixed
`spendShare`, `tokenShare`, and `requestShare` for its period, so a token-ranked
row can state the share of the bill it represents. That pair — 47% of tokens,
14% of spend — is the point of the feature; a single percentage of either kind
would hide it.

A single bucket is the third period, and it is deliberately not a special case
of "current": clicking the Oct 4 bar must describe Oct 4, not today. Its
denominator is the bar itself (`Bucket.total` plus the summed per-bucket
counters), rows with nothing in that slice are dropped, and colours still come
from the window ranking so a series keeps its hue. Because `Series` carries
`perBucket` values rather than just amounts, switching the measure on a selected
bar re-ranks that bar's tokens and requests without re-fetching anything.

`TokenEfficiency` adds window-wide readings: blended cost per million tokens,
completion-to-prompt ratio, tokens and cost per request, and an effective rate
per series relative to the window's average.

Efficiency deliberately covers the **whole window**, not the headline period.
A partial hour rarely holds enough tokens for a blended rate or an output ratio
to mean anything, and a figure that lurches on every refresh teaches nothing. The
caption ("last 14 days") states the span so the block is never mistaken for the
headline's period. It is hidden while a bar is selected, since window-wide
efficiency would contradict a single-slice reading.

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
- fixes the popover's content height rather than measuring it, so a refresh
  cannot resize the panel around the reader. The panel holds its top edge while
  the content changes height; the chart absorbs the slack when the breakdown is
  short, and a long list scrolls instead of growing the window.
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
