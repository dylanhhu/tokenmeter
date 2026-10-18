import Foundation
import os

/// Category-scoped loggers. Use `privacy: .public` only for non-sensitive values;
/// credentials, tokens, and request bodies must never be logged.
public enum Log {
    private static let subsystem = "com.dylanhu.TokenMeter"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let providers = Logger(subsystem: subsystem, category: "providers")
    public static let aggregation = Logger(subsystem: subsystem, category: "aggregation")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let credentials = Logger(subsystem: subsystem, category: "credentials")
}

/// Redacts a secret for display: keeps a short prefix so the user can tell keys
/// apart. Never renders the full value.
public enum SecretRedactor {
    public static func redact(_ secret: String, visiblePrefix: Int = 6) -> String {
        guard secret.count > visiblePrefix + 4 else { return String(repeating: "•", count: 8) }
        return secret.prefix(visiblePrefix) + String(repeating: "•", count: 8)
    }
}
