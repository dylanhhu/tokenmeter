import Foundation

/// Lenient coercion for provider payloads. Aggregation endpoints are loosely
/// typed in practice: numeric metrics come back as either JSON numbers or
/// numeric strings, unused fields are `null`, and timestamps appear in a few
/// shapes depending on which granularity and data source answered.
public enum FlexibleJSON {
    public static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let number as NSNumber:
            Decimal(string: number.stringValue)
        case let string as String:
            Decimal(string: string.trimmingCharacters(in: .whitespaces))
        case let decimal as Decimal:
            decimal
        case let double as Double:
            isPlausible(double) ? Decimal(string: String(double)) : nil
        default:
            nil
        }
    }

    public static func int(_ value: Any?) -> Int? {
        guard let decimal = decimal(value) else { return nil }
        return NSDecimalNumber(decimal: decimal).intValue
    }

    public static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            bool
        case let number as NSNumber:
            number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "true", "1", "yes": true
            case "false", "0", "no": false
            default: nil
            }
        default:
            nil
        }
    }

    private static let timeColumnPrefixes = [
        "date__", "created_at__", "timestamp__", "hour__", "day__", "week__", "month__", "minute__",
    ]
    private static let timeColumnTokens = ["date", "time", "bucket", "start", "minute", "hour", "day", "week", "month"]

    /// Finds the key holding the time bucket. Analytics rows name that column
    /// after whichever rollup answered the query — `date__hour` from the hourly
    /// view, `date__minute` from the minute view, `created_at__day` from the
    /// daily one — and the set of rollups changes without notice. Matching a
    /// fixed list of names is therefore not enough on its own, so the scan falls
    /// back to any column that holds a timestamp.
    public static func timeBucket(in row: [String: Any]) -> (key: String, value: Any?)? {
        for prefix in timeColumnPrefixes {
            if let match = row.first(where: { $0.key.hasPrefix(prefix) }) {
                return (match.key, match.value)
            }
        }
        for key in ["date", "created_at", "timestamp", "bucket"] where row[key] != nil {
            return (key, row[key])
        }
        let ordered = row.sorted { $0.key < $1.key }
        if let named = ordered.first(where: { entry in
            timeColumnTokens.contains { entry.key.lowercased().contains($0) } && isTimestamp(entry.value)
        }) {
            return (named.key, named.value)
        }
        if let date = ordered.first(where: { isTimestamp($0.value) }) {
            return (date.key, date.value)
        }
        return nil
    }

    /// Whether a column value could plausibly be a bucket boundary.
    ///
    /// Metric columns are numbers too, so an unqualified "does this parse" test
    /// would happily read `total_usage: 0.5` as 1970-01-01T00:00:00.5Z. Epoch
    /// magnitudes below 1e9 seconds predate 2001 and are never bucket boundaries.
    public static func isTimestamp(_ value: Any?) -> Bool {
        switch value {
        case let text as String:
            return FlexibleDate.parseISO8601(text) != nil
        case let number as NSNumber where !(value is Bool):
            return abs(number.doubleValue) >= 1_000_000_000
        case let fields as [Any]:
            guard let date = FlexibleDate.parse(fields) else { return false }
            return date.timeIntervalSince1970 >= 1_000_000_000
        default:
            return false
        }
    }

    private static func isPlausible(_ value: Double) -> Bool {
        value.isFinite
    }
}

/// Parses the timestamp shapes OpenRouter emits for bucket boundaries.
///
/// `DateFormatter` and `ISO8601DateFormatter` are not `Sendable`, so this works
/// on components directly instead of hoisting shared formatter instances.
public enum FlexibleDate {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    public static func parse(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        // Bucket columns come back as epoch numbers as often as ISO strings, so a
        // numeric value is not evidence that the row has no timestamp.
        if let number = value as? NSNumber, !(value is Bool) {
            return Date(timeIntervalSince1970: epochSeconds(number.doubleValue))
        }
        if let fields = value as? [Any], let components = dateComponents(from: fields) {
            return utc.date(from: components)
        }
        guard let raw = FlexibleJSON.string(value) else { return nil }
        if let parsed = parseISO8601(raw) {
            return parsed
        }
        return Double(raw.trimmingCharacters(in: .whitespaces)).map { Date(timeIntervalSince1970: epochSeconds($0)) }
    }

    /// Reads `[year, month, day, hour, minute, second]` arrays, which some rollups
    /// return in place of a formatted timestamp.
    private static func dateComponents(from values: [Any]) -> DateComponents? {
        guard values.count >= 3,
              let year = FlexibleJSON.int(values[0]),
              let month = FlexibleJSON.int(values[1]),
              let day = FlexibleJSON.int(values[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = values.count > 3 ? FlexibleJSON.int(values[3]) ?? 0 : 0
        components.minute = values.count > 4 ? FlexibleJSON.int(values[4]) ?? 0 : 0
        components.second = values.count > 5 ? FlexibleJSON.int(values[5]) ?? 0 : 0
        return components
    }

    /// Normalises an epoch to seconds, accepting the second, millisecond,
    /// microsecond, and nanosecond resolutions that database columns emit.
    private static func epochSeconds(_ value: Double) -> Double {
        switch abs(value) {
        case 100_000_000_000_000_000...: value / 1_000_000_000
        case 100_000_000_000_000...: value / 1_000_000
        case 100_000_000_000...: value / 1_000
        default: value
        }
    }

    /// Accepts `yyyy-MM-dd`, `yyyy-MM-ddTHH:mm`, `yyyy-MM-ddTHH:mm:ss`, with an
    /// optional fractional part and trailing `Z`. A space between the date and
    /// time is legal too: that is how ClickHouse renders `DateTime`.
    public static func parseISO8601(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") || text.hasSuffix("z") {
            text.removeLast()
        }
        let normalized = text.replacingOccurrences(of: "T", with: " ")
        let parts = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let datePart = parts.first else { return nil }

        let dateNumbers = datePart.split(separator: "-").map { Int($0) }
        guard dateNumbers.count == 3,
              let year = dateNumbers[0], let month = dateNumbers[1], let day = dateNumbers[2]
        else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0

        if parts.count == 2 {
            // Drop any explicit offset; OpenRouter reports UTC.
            let timePart = parts[1].split { $0 == "+" || $0 == "-" }.first ?? Substring("")
            components.hour = intComponent(timePart, at: 0) ?? 0
            components.minute = intComponent(timePart, at: 1) ?? 0
            components.second = intComponent(timePart, at: 2) ?? 0
        }

        return utc.date(from: components)
    }

    /// Reads one `:`-separated field, tolerating a fractional seconds suffix.
    private static func intComponent(_ text: Substring, at index: Int) -> Int? {
        let fields = text.split(separator: ":")
        guard fields.indices.contains(index) else { return nil }
        let whole = fields[index].split(separator: ".").first.map(String.init) ?? ""
        return Int(whole)
    }

    /// Canonical form the analytics API expects: seconds precision, UTC.
    public static func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}

public enum HTTPStatusError: Error, Sendable {
    case transport(String)
}

/// Minimal JSON-over-HTTPS helper shared by adapters.
public struct JSONHTTPClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    public func get(_ path: String, query: [URLQueryItem] = [], bearer: String?) async throws -> Data {
        var request = try makeRequest(path: path, method: "GET", query: query, bearer: bearer)
        request.setValue("TokenMeter/1.0", forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }

    public func post(_ path: String, body: Data, bearer: String?) async throws -> Data {
        var request = try makeRequest(path: path, method: "POST", query: [], bearer: bearer)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TokenMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return try await send(request)
    }

    private func makeRequest(path: String, method: String, query: [URLQueryItem], bearer: String?) throws -> URLRequest {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL.appendingPathComponent(trimmed), resolvingAgainstBaseURL: false) else {
            throw SpendProviderError.requestRejected("Invalid path \(path)")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw SpendProviderError.requestRejected("Could not build URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SpendProviderError.network("No HTTP response")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw Self.mapError(status: http.statusCode, data: data, headers: http)
            }
            return data
        } catch let error as SpendProviderError {
            throw error
        } catch let error as URLError {
            throw SpendProviderError.network(error.localizedDescription)
        } catch {
            throw SpendProviderError.network(error.localizedDescription)
        }
    }

    private static func mapError(status: Int, data: Data, headers: HTTPURLResponse) -> SpendProviderError {
        let message = extractMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401:
            return .invalidCredential(message)
        case 403:
            return .insufficientPermissions(message)
        case 400, 422:
            return .requestRejected(message)
        case 429:
            let retry = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .rateLimited(retryAfter: retry)
        default:
            return .server(status: status, message: message)
        }
    }

    private static func extractMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data.prefix(300), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
        if let error = object["error"] as? [String: Any] {
            return FlexibleJSON.string(error["message"]) ?? FlexibleJSON.string(error["code"].map { String(describing: $0) })
        }
        if let error = object["error"] as? String {
            return error
        }
        return FlexibleJSON.string(object["message"])
    }
}
