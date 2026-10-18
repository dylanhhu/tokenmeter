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

    /// Finds the first key matching a time-bucket column. Analytics rows name the
    /// bucket column after the data source, e.g. `date__day` or
    /// `created_at__hour`, so the prefix cannot be hard-coded.
    public static func timeBucket(in row: [String: Any]) -> (key: String, value: Any?)? {
        let candidates = ["date__", "created_at__", "timestamp__", "hour__", "day__", "week__", "month__"]
        for prefix in candidates {
            if let match = row.first(where: { $0.key.hasPrefix(prefix) }) {
                return (match.key, match.value)
            }
        }
        for key in ["date", "created_at", "timestamp", "bucket"] where row[key] != nil {
            return (key, row[key])
        }
        return nil
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
        guard let raw = FlexibleJSON.string(value) else { return nil }
        return parseISO8601(raw)
    }

    /// Accepts `yyyy-MM-dd`, `yyyy-MM-ddTHH:mm`, `yyyy-MM-ddTHH:mm:ss`, with an
    /// optional fractional part and trailing `Z`.
    public static func parseISO8601(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("Z") || text.hasSuffix("z") {
            text.removeLast()
        }
        let parts = text.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
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
