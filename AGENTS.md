# AGENTS.md

Operational guide for anyone — human or agent — changing this repository. Read
this before editing code. `docs/ARCHITECTURE.md` explains *why* the design looks
the way it does; this file explains *what to do*.

## What this is

A macOS menu bar app (SwiftUI, no Xcode project) that shows LLM API spend for the
current hour, day, week, or month, with a per-model and per-provider breakdown.
Providers are pluggable adapters; OpenRouter is the reference implementation.

## Commands

```bash
make build      # debug build
make test       # swift-testing suite (65 tests, no network)
make lint       # swiftformat --lint + swiftlint --strict (no writes)
make format     # apply formatting fixes
make check      # lint + test — run before every commit
make bundle     # build build/TokenMeter.app (release, ad-hoc signed)
make run        # bundle and launch
make snapshot   # render UI screenshots to docs/screenshots/
```

### Visual QA without a display

`make snapshot` renders the popover, onboarding state, and settings window to PNG
using an offscreen `NSHostingView` fed by `DemoProvider`. It never touches your
settings or Keychain, needs no screen-recording permission, and works over SSH.
Use it to check a layout change before handing work back. Flags:

```bash
./.build/debug/TokenMeter --snapshot out.png --appearance light   # or dark
./.build/debug/TokenMeter --snapshot out.png --view settings      # popover | settings | empty
```

### Toolchain gotcha (read this first)

`@State`, `@Environment`, and `#Preview` come from the **Xcode** toolchain, not
the Command Line Tools. If `xcode-select` points at `/Library/Developer/CommandLineTools`,
building the app target fails with:

```
external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

The `Makefile` detects Xcode and exports `DEVELOPER_DIR` automatically, so always
build through `make`, or export it yourself:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Do not "fix" this by deleting `@State`. Losing that macro would mean rewriting
every view's local state for no benefit.

## Layout

```
Sources/TokenMeterKit/          # pure logic, unit-tested, no AppKit UI
  Core/SpendWindow.swift        # windows, bucketing, time-zone handling
  Core/SpendSlice.swift         # the provider → aggregator contract
  Core/Aggregation.swift        # slices → SpendReport (series, totals, deltas)
  Core/Money.swift              # Decimal money formatting
  Providers/SpendProvider.swift # the protocol every adapter implements
  Providers/ProviderCatalog.swift # registry — the one place adapters are listed
  Providers/OpenRouter/         # reference adapter (client + provider)
  Providers/DemoProvider.swift  # synthetic data for UI work and tests
  Config/                       # settings file, Keychain credential store
  Support/                      # logging, lenient JSON/date parsing, HTTP
Sources/TokenMeter/             # app layer: MenuBarExtra, popover, settings UI
Tests/TokenMeterKitTests/       # swift-testing; never hits the network
docs/                           # architecture and provider-authoring guides
```

Dependency direction is strictly one-way: `TokenMeter` → `TokenMeterKit`.
Never import SwiftUI or AppKit inside `TokenMeterKit`; it must stay testable and
UI-agnostic.

## Invariants

Break one of these and you have introduced a bug, even if it compiles.

1. **Money is `Decimal`, never `Double`.** Aggregating thousands of sub-cent
   charges as `Double` drifts. Convert to `Double` only at the plotting and
   formatting boundary.
2. **Bucketing invariant.** A provider must return slices bucketed no more
   coarsely than `request.window`, and covering `request.range`. The aggregator
   assigns each slice to the bucket that contains `slice.start`; coarser slices
   therefore smear across buckets.
3. **Capabilities travel with the fetch.** They depend on the credential, not
   just the provider. `capabilities` is populated from `SpendFetchResult`, and
   the UI gates window options and the breakdown control on it.
4. **The headline figure is the in-progress period**, unless the provider reports
   an authoritative period total (`periodTotals`), which then wins. For the
   hourly window that period is the trailing 60 minutes (`headlineRange`), not
   the clock hour to date, so it can span two chart buckets.
5. **The breakdown shares the headline's denominator.** `currentBreakdown` ranks
   series by the in-progress period; `windowBreakdown` ranks by the whole window.
   Never mix the two — a "$45" row under a "$9.50 today" headline is a bug report
   waiting to happen. Colours come from `colorIndex` (window rank), not list
   position, so a series keeps its chart colour when the list is re-sorted.
6. **Period-over-period deltas compare equal elapsed durations.** Never divide a
   partial period by a whole one; that is how you publish a fake 90% saving. See
   `priorComparableTotal`.
7. **Credentials only ever live in the Keychain.** Never in `settings.json`,
   never in a log line, never in an error message. `SecretRedactor` exists for
   display; the SwiftLint custom rule `no_credentials_in_logs` enforces the log
   case.
8. **Errors degrade, they do not blank the UI.** A failing provider keeps its last
   good data and adds a `ProviderIssue` row. Refresh must never leave the menu bar
   showing a stale value with no indication.
9. **`AppModel` is `@MainActor` and owns all mutable app state.** Network work
   runs in detached tasks and returns `Sendable` values. Do not add mutable shared
   state to `TokenMeterKit` types without making it an `actor`.

## Adding a provider

Full walkthrough in `docs/ADDING_A_PROVIDER.md`. The short version:

1. Create `Sources/TokenMeterKit/Providers/<Vendor>/`.
2. Implement the `SpendProvider` protocol: `descriptor`, `probe()`,
   `fetchSpend(_:)`.
3. Map the vendor's rows into `SpendSlice` values. Bucket at or below the
   requested window; leave `model` / `upstreamProvider` nil when the vendor does
   not expose them.
4. Report honest `ProviderCapabilities` — the UI trusts them.
5. Add the descriptor and factory case to `ProviderCatalog`.
6. Add tests in `Tests/TokenMeterKitTests/` that feed recorded fixtures through
   the mapper. No network in tests.

Nothing in `Sources/TokenMeter/` needs to change. If you find yourself editing a
view to support a new vendor, the abstraction has been violated — fix that
instead.

## Testing expectations

- New aggregation or bucketing logic needs tests; these are where silent money
  bugs live.
- Parsing code gets fixture tests, including the ugly cases: numeric strings,
  nulls, missing time-bucket columns, `date__X` versus `created_at__X`.
- Tests must not touch the network, the Keychain, or `~/Library`. Use
  `SettingsStore(fileURL:)` with a temporary directory.
- Snapshot/golden tests are not used; prefer assertions on values.

## Style

- `swiftformat` + `swiftlint` are authoritative. `make format` then `make check`.
- Public API in `TokenMeterKit` gets a doc comment explaining the *why* where the
  reasoning is not obvious. Do not restate the type name.
- Prefer `switch` expressions and `if`/`switch` postfix when they shorten code.
- Views stay dumb: formatting and derivation belong in `TokenMeterKit` or
  `AppModel`, not in a `body`.
- No `print`. Use `Log.<category>`.

## Commits and PRs

- Conventional-ish subjects: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`,
  `chore:`. One logical change per commit.
- `make check` must pass before you push; CI runs the same commands.
- Never commit `.build/`, `build/`, secrets, or a `settings.json` from your own
  machine.

## Safety rules for agents

- Do not run `rm -f`. Use `swift package clean`, `make clean`, or `rm -r`.
- Do not hit real provider APIs from tests, scripts, or exploratory commands;
  they cost money and mutate rate-limit state. Use `DemoProvider` or fixtures.
- Do not read or print the contents of the user's Keychain, and do not attempt to
  extract credentials from a running app.
- Before changing anything under `Config/`, re-read invariant 6. A regression
  here leaks a customer credential to disk.

## Definition of done

- [ ] `make check` passes
- [ ] New behaviour has tests
- [ ] Doc comments on any new public API
- [ ] Capability gating considered for every new provider or window
- [ ] No new force-unwraps, `try!`, or `as!` in `Sources/`
- [ ] `AGENTS.md` / `docs/` updated if you changed a contract or invariant
