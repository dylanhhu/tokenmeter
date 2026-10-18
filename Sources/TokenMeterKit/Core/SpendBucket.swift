import Foundation

/// The bucket types a report is made of: one bar on the chart, and one series'
/// share of that bar.
///
/// Split out of `Aggregation.swift` because a bar carries spend and volume at
/// once, which is what makes clicking one useful.
public extension SpendReport {
    /// One chart bucket: a calendar interval and the spend inside it.
    struct Bucket: Sendable, Identifiable, Hashable {
        public var start: Date
        public var end: Date
        public var total: Decimal

        public var id: Date {
            start
        }

        public var isCurrent = false
    }

    /// One series' contribution to one bucket. Spend and volume are folded
    /// together so a bar can be read at every measure, not only as a height.
    struct BucketValues: Sendable, Hashable {
        public var amount: Decimal
        public var promptTokens: Int
        public var completionTokens: Int
        public var requests: Int

        public init(amount: Decimal = 0, promptTokens: Int = 0, completionTokens: Int = 0, requests: Int = 0) {
            self.amount = amount
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.requests = requests
        }

        public var tokens: Int {
            promptTokens + completionTokens
        }
    }
}
