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
make test       # swift-testing suite (no network; count on last line)
swift test --filter BucketingTests.bucketPartition   # one test, for the red/green loop
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
./.build/debug/TokenMeter --snapshot out.png --measure tokens     # spend | tokens | requests
./.build/debug/TokenMeter --snapshot out.png --selected 9         # bucket index, oldest first
./.build/debug/TokenMeter --snapshot out.png --hover 9            # pin the chart tooltip
./.build/debug/TokenMeter --snapshot out.png --scope trailing     # calendar | trailing
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
  Core/SpendWindow.swift        # windows, scopes, bucketing, time-zone handling
  Core/SpendSlice.swift         # the provider → aggregator contract
  Core/Aggregation.swift        # slices → SpendReport (series, totals, deltas)
  Core/SpendReport+Captions.swift # the wording of a period, shared by every figure
  Core/BreakdownRows.swift      # rows ranked by spend, tokens, or requests
  Core/BreakdownMeasure.swift   # which quantity the breakdown is measured by
  Core/TokenEfficiency.swift    # blended rates, output ratio, per-request costs
  Core/Money.swift              # Decimal money formatting
  Providers/SpendProvider.swift # the protocol every adapter implements
  Providers/ProviderCatalog.swift # registry — the one place adapters are listed
  Providers/OpenRouter/         # reference adapter (client + provider)
  Providers/DemoProvider.swift  # synthetic data for UI work and tests
  Config/                       # settings file, Keychain credential store
  Support/                      # logging, lenient JSON/date parsing, HTTP
Sources/TokenMeter/             # app layer: MenuBarExtra, popover, settings UI
Tests/TokenMeterKitTests/       # swift-testing; never hits the network
docs/                           # architecture, metrics, and provider-authoring guides
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
   the UI gates window options and the breakdown control on it. Rolling support
   is tracked separately (`rollingWindows`): a credential can fill a window from
   coarse rows and still be unable to resolve a rolling boundary, in which case
   the UI must not offer that reading.
4. **The headline figure is the period the user chose**, unless the provider
   reports an authoritative period total (`periodTotals`) and the scope is
   calendar — a period total describes a calendar period and can never stand in
   for a rolling one. `WindowScope` selects the period: the calendar period in
   progress (today, this week) or one bucket's length ending now
   (`last 24 hours`). A rolling headline starts
   mid-bucket, so it can span two chart buckets, and providers must return rows
   finer than the bucket around its two boundaries.
5. **The breakdown shares the headline's denominator.** `currentBreakdown` ranks
   series by the in-progress period; `windowBreakdown` ranks by the whole window;
   `breakdown(for: .bucket(start))` ranks by one clicked bar. Never mix them — a
   "$45" row under a "$9.50 today" headline is a bug report waiting to happen,
   and a selected bar must be captioned with its own interval and total. Colours
   come from `colorIndex` (window rank), not list position, so a series keeps its
   chart colour when the list is re-sorted.
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
10. **Every measure shares the headline's denominator.** Switching the breakdown
    to tokens or requests re-ranks the same rows against that period's tokens or
    requests, never the window's. `BreakdownRow` carries all three shares for the
    same period so the divergence stays visible, and `Series.perBucket` carries
    per-bar counters so a selected bar can be re-measured the same way. Efficiency
    figures are the one exception: they cover the whole window and say so in their
    caption.
11. **Provider results are cached; navigation is free.** `SpendResultCache` holds
    one result per (provider, window, scope, time zone) for the refresh interval,
    and serves it only while it still spans the requested range. Scope is part of
    the key because a calendar result lacks the fine rows a rolling headline
    needs. Opening the popover
    or switching windows must not query a vendor. Manual refresh and credential
    changes force a fetch; credential changes also invalidate the entry.

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

## Test-driven development

This repository is developed test-first. Write the failing test before the
implementation, watch it fail for the reason you expect, then write the minimum
code that makes it pass and refactor. A pull request whose tests were written
after the implementation is not ready, even when the tests pass: tests written
against finished code encode what the code does rather than what it must do.

The loop, concretely:

1. Write one test expressing the next piece of behaviour. Put it next to the
   tests for that tier — aggregation, bucketing, parsing, caching — not in a
   catch-all file.
2. Run `swift test --filter <Suite>.<test>` and confirm it fails on the
   assertion, not on a compile error or a missing fixture. A test that cannot
   compile has not failed yet.
3. Implement the smallest change that makes it pass. No speculative generality,
   no unrelated API surface added along the way.
4. Run `make check` after the green step. Refactor only while green, then rerun.
5. Repeat for the next behaviour. Do not batch several behaviours behind one
   test; a failing assertion should name one expectation.

Where test-first does not apply: view layout, copy, docs, and other
non-observable presentation changes. Those are verified with `make snapshot` or
by inspection. Logic that a view calls belongs in `TokenMeterKit` precisely so it
can be driven test-first. If you cannot write a test for a behaviour, that is
often a sign the logic sits in the wrong tier — move it down.

Regression fixes start with a test that reproduces the bug and fails on the
current code. State the failure in the commit message body; the test that
previously would have caught it is part of the fix.

### Testing expectations

- New aggregation or bucketing logic needs tests; these are where silent money
  bugs live.
- Parsing code gets fixture tests, including the ugly cases: numeric strings,
  nulls, missing time-bucket columns, `date__X` versus `created_at__X`.
- Tests must not touch the network, the Keychain, or `~/Library`. Use
  `SettingsStore(fileURL:)` with a temporary directory.
- Snapshot/golden tests are not used; prefer assertions on values.
- Prefer boundary cases over story-shaped tests: equal elapsed durations across
  DST, an empty provider set, a slice landing exactly on a bucket edge.

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
- "Merge" means squash. Use `gh pr merge --squash`, or `git merge --squash`
  followed by one commit. Do not create merge commits or fast-forward a branch's
  intermediate commits onto `main`.
- `make check` must pass before you push; CI runs the same commands.
- A commit that adds behaviour includes the failing test written first in the
  same commit (or an earlier one), not a follow-up `test:` commit.
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
- [ ] New behaviour was written test-first: the test failed before the
      implementation existed
- [ ] Bug fixes include a test that reproduced the bug
- [ ] Doc comments on any new public API
- [ ] Capability gating considered for every new provider or window
- [ ] No new force-unwraps, `try!`, or `as!` in `Sources/`
- [ ] `AGENTS.md` / `docs/` updated if you changed a contract or invariant
