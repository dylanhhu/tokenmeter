import Foundation
import Testing
@testable import TokenMeterKit

@Suite("Formatting and parsing")
struct SupportTests {
    @Test("Menu bar amounts stay short and do not round to zero")
    func menuBarFormatting() throws {
        #expect(Money.menuBar(0) == "$0.00")
        #expect(try Money.menuBar(#require(Decimal(string: "1.234"))) == "$1.23")
        #expect(try Money.menuBar(#require(Decimal(string: "0.0042"))).hasSuffix("42"))
        #expect(try Money.compact(#require(Decimal(string: "1234.5"))) == "$1.2k")
        #expect(try Money.compact(#require(Decimal(string: "2500000"))) == "$2.5M")
        #expect(try Money.compact(#require(Decimal(string: "45.6"))) == "$45.60")
    }

    @Test("Tiny amounts keep four decimals in detail views")
    func preciseFormatting() throws {
        #expect(try Money.precise(#require(Decimal(string: "0.00042"))).contains("0004"))
        #expect(try Money.precise(#require(Decimal(string: "1.5"))) == "$1.50")
    }

    @Test("Shares are percentages of the denominator")
    func shareFormatting() throws {
        #expect(Money.share(1, of: 4) == "25.0%")
        #expect(Money.share(0, of: 0) == "—")
        #expect(try Money.share(#require(Decimal(string: "0.0001")), of: 10) == "<0.1%")
    }

    @Test("Decimal rounding is banker's rounding")
    func decimalRounding() {
        #expect(Decimal(string: "1.005")?.rounded(places: 2) == Decimal(string: "1.00"))
        #expect(Decimal(string: "1.015")?.rounded(places: 2) == Decimal(string: "1.02"))
    }

    @Test("ISO-8601 variants all parse to UTC instants")
    func dateParsing() {
        let expected = Date(timeIntervalSince1970: 1_770_768_000) // 2026-02-11T00:00:00Z
        #expect(FlexibleDate.parse("2026-02-11T00:00:00.000Z") == expected)
        #expect(FlexibleDate.parse("2026-02-11T00:00:00Z") == expected)
        #expect(FlexibleDate.parse("2026-02-11") == expected)
        #expect(FlexibleDate.parse("2026-02-11T00:00") == expected)
        #expect(FlexibleDate.parse("nonsense") == nil)
        #expect(FlexibleDate.parse(nil) == nil)
    }

    @Test("Outgoing timestamps include seconds, as the API requires")
    func dateFormatting() {
        let date = Date(timeIntervalSince1970: 1_770_768_000)
        let text = FlexibleDate.iso8601(date)
        #expect(text == "2026-02-11T00:00:00Z")
        #expect(FlexibleDate.parse(text) == date)
    }

    @Test("Numeric coercion accepts numbers, strings, and nulls")
    func numericCoercion() {
        #expect(FlexibleJSON.decimal(12) == 12)
        #expect(FlexibleJSON.decimal("12.34") == Decimal(string: "12.34"))
        #expect(FlexibleJSON.decimal(NSNull()) == nil)
        #expect(FlexibleJSON.int("7") == 7)
        #expect(FlexibleJSON.int(nil) == nil)
        #expect(FlexibleJSON.string("  ") == nil)
        #expect(FlexibleJSON.bool("true") == true)
    }

    @Test("Settings round-trip and tolerate missing keys")
    func settingsCoding() throws {
        let settings = AppSettings(
            menuBarWindow: .monthly,
            grouping: .provider,
            refreshInterval: 900,
            timeZoneMode: .utc,
            seriesLimit: 8,
            enabledProviders: ["openrouter", "demo"],
            menuBarStyle: .iconAndAmount,
            launchAtLogin: true
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == settings)

        // Provider ids encode as bare strings for a readable settings file.
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"openrouter\""))

        let partial = Data(#"{"menuBarWindow":"weekly"}"#.utf8)
        let partialDecoded = try JSONDecoder().decode(AppSettings.self, from: partial)
        #expect(partialDecoded.menuBarWindow == .weekly)
        #expect(partialDecoded.refreshInterval == AppSettings.default.refreshInterval)
    }

    @Test("Refetch and rebuild decisions are distinct")
    func settingsDiffing() {
        let base = AppSettings.default
        var groupingOnly = base
        groupingOnly.grouping = .provider
        #expect(groupingOnly.requiresRefetch(comparedTo: base) == false)
        #expect(groupingOnly.requiresRebuild(comparedTo: base))

        var window = base
        window.menuBarWindow = .monthly
        #expect(window.requiresRefetch(comparedTo: base))
    }

    @Test("Secrets are redacted, never echoed")
    func redaction() {
        let redacted = SecretRedactor.redact("sk-or-v1-abcdef123456")
        #expect(redacted.hasPrefix("sk-or-"))
        #expect(!redacted.contains("abcdef123456"))
        #expect(SecretRedactor.redact("short") == "••••••••")
    }

    @Test("Settings files are written atomically and read back")
    func settingsStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.default
        settings.seriesLimit = 10
        store.save(settings)
        #expect(store.load().seriesLimit == 10)

        try FileManager.default.removeItem(at: directory)
    }
}
