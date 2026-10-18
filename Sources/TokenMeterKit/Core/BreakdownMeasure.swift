import Foundation

/// The quantity a breakdown is ranked and measured by.
///
/// Spend answers "what did this cost"; tokens and requests answer "how much work
/// did that money buy", which is the only way to see that a cheap model holding
/// most of the token volume is doing more of the work than its invoice suggests.
public enum BreakdownMeasure: String, CaseIterable, Codable, Sendable, Identifiable {
    case spend
    case tokens
    case requests

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .spend: "Spend"
        case .tokens: "Tokens"
        case .requests: "Requests"
        }
    }

    /// Short noun for share captions, e.g. "18% of tokens".
    public var shareNoun: String {
        switch self {
        case .spend: "of spend"
        case .tokens: "of tokens"
        case .requests: "of requests"
        }
    }

    /// Unit abbreviation used on dense row labels.
    public var unitSuffix: String? {
        switch self {
        case .spend: nil
        case .tokens: "tok"
        case .requests: "req"
        }
    }
}
