import Foundation

/// Style of the menu bar label.
public enum MenuBarStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// `$1.23`
    case amount
    /// `$1.23 1D`
    case amountAndWindow
    /// A small icon followed by the amount.
    case iconAndAmount

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .amount: "Amount"
        case .amountAndWindow: "Amount + window"
        case .iconAndAmount: "Icon + amount"
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    /// Window whose current-period total appears in the menu bar and whose
    /// buckets the chart displays.
    public var menuBarWindow: SpendWindow
    public var grouping: SpendGrouping
    /// How often to refresh from providers, in seconds.
    public var refreshInterval: TimeInterval
    public var timeZoneMode: TimeZoneMode
    /// Maximum number of series rendered before folding the remainder into
    /// "Other".
    public var seriesLimit: Int
    /// Providers to query, in display order.
    public var enabledProviders: [ProviderID]
    public var menuBarStyle: MenuBarStyle
    public var launchAtLogin: Bool

    public init(
        menuBarWindow: SpendWindow = .daily,
        grouping: SpendGrouping = .model,
        refreshInterval: TimeInterval = 300,
        timeZoneMode: TimeZoneMode = .local,
        seriesLimit: Int = 5,
        enabledProviders: [ProviderID] = [OpenRouterProvider.providerID],
        menuBarStyle: MenuBarStyle = .amount,
        launchAtLogin: Bool = false
    ) {
        self.menuBarWindow = menuBarWindow
        self.grouping = grouping
        self.refreshInterval = refreshInterval
        self.timeZoneMode = timeZoneMode
        self.seriesLimit = seriesLimit
        self.enabledProviders = enabledProviders
        self.menuBarStyle = menuBarStyle
        self.launchAtLogin = launchAtLogin
    }

    public static let `default` = AppSettings()

    // Decode defensively so that adding a field in a later version does not
    // discard a user's whole configuration file.
    public init(from decoder: any Decoder) throws {
        let fallback = AppSettings.default
        let container = try decoder.container(keyedBy: CodingKeys.self)
        menuBarWindow = try container.decodeIfPresent(SpendWindow.self, forKey: .menuBarWindow) ?? fallback.menuBarWindow
        grouping = try container.decodeIfPresent(SpendGrouping.self, forKey: .grouping) ?? fallback.grouping
        refreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? fallback.refreshInterval
        timeZoneMode = try container.decodeIfPresent(TimeZoneMode.self, forKey: .timeZoneMode) ?? fallback.timeZoneMode
        seriesLimit = try container.decodeIfPresent(Int.self, forKey: .seriesLimit) ?? fallback.seriesLimit
        enabledProviders = try container.decodeIfPresent([ProviderID].self, forKey: .enabledProviders) ?? fallback.enabledProviders
        menuBarStyle = try container.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? fallback.menuBarStyle
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin
    }

    /// True when a change requires re-fetching from providers.
    public func requiresRefetch(comparedTo other: AppSettings) -> Bool {
        menuBarWindow != other.menuBarWindow
            || timeZoneMode != other.timeZoneMode
            || enabledProviders != other.enabledProviders
    }

    /// True when the rendered report must be recomputed from cached data.
    public func requiresRebuild(comparedTo other: AppSettings) -> Bool {
        requiresRefetch(comparedTo: other)
            || grouping != other.grouping
            || seriesLimit != other.seriesLimit
    }
}

/// JSON-file settings store. Deliberately not `UserDefaults`: a visible file is
/// easier to inspect, diff, and reset, and it keeps the app's state in one place
/// next to its logs.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TokenMeter", isDirectory: true)
    }

    public static func defaultFileURL() -> URL {
        supportDirectory().appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.settings.error("Could not decode settings, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    public func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.settings.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
