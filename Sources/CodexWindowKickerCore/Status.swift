import Foundation

/// The status file contract shared by the launchd worker and the menu-bar app.
/// Unknown keys are deliberately ignored so later worker versions remain readable.
public struct KickerStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let enabled: Bool
    public let lastPollAt: Date?
    public let usagePercent: Double?
    public let resetAt: Date?
    public let lastKickoffAt: Date?
    public let lastError: String?

    public init(
        schemaVersion: Int = 1,
        enabled: Bool,
        lastPollAt: Date? = nil,
        usagePercent: Double? = nil,
        resetAt: Date? = nil,
        lastKickoffAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.lastPollAt = lastPollAt
        self.usagePercent = usagePercent
        self.resetAt = resetAt
        self.lastKickoffAt = lastKickoffAt
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, lastPollAt, usagePercent, resetAt, lastKickoffAt, lastError
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try values.decode(Bool.self, forKey: .enabled)
        lastPollAt = try values.decodeISO8601DateIfPresent(forKey: .lastPollAt)
        usagePercent = try values.decodeIfPresent(Double.self, forKey: .usagePercent)
        resetAt = try values.decodeISO8601DateIfPresent(forKey: .resetAt)
        lastKickoffAt = try values.decodeISO8601DateIfPresent(forKey: .lastKickoffAt)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(enabled, forKey: .enabled)
        try values.encodeISO8601Date(lastPollAt, forKey: .lastPollAt)
        try values.encodeIfPresent(usagePercent, forKey: .usagePercent)
        try values.encodeISO8601Date(resetAt, forKey: .resetAt)
        try values.encodeISO8601Date(lastKickoffAt, forKey: .lastKickoffAt)
        try values.encodeIfPresent(lastError, forKey: .lastError)
    }
}

private extension KeyedDecodingContainer {
    func decodeISO8601DateIfPresent(forKey key: Key) throws -> Date? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value.hasSuffix("Z"), let date = StatusDateCodec.date(from: value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected an ISO-8601 UTC timestamp ending in Z")
        }
        return date
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeISO8601Date(_ date: Date?, forKey key: Key) throws {
        if let date {
            try encode(StatusDateCodec.string(from: date), forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

public enum StatusDateCodec {
    public static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        if let date = fractional.date(from: string) { return date }

        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        basic.timeZone = TimeZone(secondsFromGMT: 0)
        return basic.date(from: string)
    }

    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

public enum MenuBarState: Equatable, Sendable {
    case enabled
    case paused
    case warning

    public static func derive(status: KickerStatus?, now: Date, staleAfter: TimeInterval = 900) -> MenuBarState {
        guard let status else { return .warning }
        guard status.enabled else { return .paused }
        guard status.schemaVersion == 1,
              status.lastError?.isEmpty != false,
              let lastPollAt = status.lastPollAt,
              now.timeIntervalSince(lastPollAt) <= staleAfter else {
            return .warning
        }
        return .enabled
    }
}

public enum StatusPresentation {
    public static func timestamp(_ date: Date?, relativeTo now: Date = .now) -> String {
        guard let date else { return "Unavailable" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    public static func usage(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    public static func reset(_ date: Date?) -> String {
        guard let date else { return "Unavailable" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
