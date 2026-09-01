import Foundation

public enum UsageAvailability: String, Codable, Sendable {
    case available
    case unsupported
    case unavailable
}

public struct DailyUsageBucket: Codable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = max(0, tokens)
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let availability: UsageAvailability
    public let todayTokens: Int64?
    public let serviceDate: String?
    public let serviceTimeZoneIdentifier: String?
    public let dailyBuckets: [DailyUsageBucket]
    public let fetchedAt: Date?

    public init(
        availability: UsageAvailability,
        todayTokens: Int64? = nil,
        serviceDate: String? = nil,
        serviceTimeZoneIdentifier: String? = nil,
        dailyBuckets: [DailyUsageBucket] = [],
        fetchedAt: Date? = nil
    ) {
        self.availability = availability
        self.todayTokens = todayTokens
        self.serviceDate = serviceDate
        self.serviceTimeZoneIdentifier = serviceTimeZoneIdentifier
        self.dailyBuckets = dailyBuckets
        self.fetchedAt = fetchedAt
    }

    public static func fromBuckets(
        _ buckets: [DailyUsageBucket],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        serviceTimeZoneIdentifier: String? = nil,
        fetchedAt: Date = Date()
    ) -> UsageSnapshot {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        let value = buckets.first(where: { $0.startDate == date })?.tokens
        return UsageSnapshot(
            availability: .available,
            todayTokens: value,
            serviceDate: date,
            serviceTimeZoneIdentifier: serviceTimeZoneIdentifier ?? timeZone.identifier,
            dailyBuckets: buckets,
            fetchedAt: fetchedAt
        )
    }

    /// Builds a snapshot from the server's date boundary. Codex 0.147.0
    /// exposes dated buckets but no timezone metadata, so UTC is used as an
    /// explicit, visible fallback instead of silently applying the device zone.
    public static func fromServerBuckets(
        _ buckets: [DailyUsageBucket],
        serviceDate: String?,
        serviceTimeZoneIdentifier: String?,
        now: Date = Date(),
        fetchedAt: Date = Date()
    ) -> UsageSnapshot {
        if let serviceTimeZoneIdentifier,
           let timeZone = TimeZone(identifier: serviceTimeZoneIdentifier) {
            let derived = fromBuckets(
                buckets,
                now: now,
                timeZone: timeZone,
                serviceTimeZoneIdentifier: serviceTimeZoneIdentifier,
                fetchedAt: fetchedAt
            )
            return UsageSnapshot(
                availability: .available,
                todayTokens: serviceDate.flatMap { date in buckets.first(where: { $0.startDate == date })?.tokens } ?? derived.todayTokens,
                serviceDate: serviceDate ?? derived.serviceDate,
                serviceTimeZoneIdentifier: serviceTimeZoneIdentifier,
                dailyBuckets: buckets,
                fetchedAt: fetchedAt
            )
        }

        if let serviceDate {
            return UsageSnapshot(
                availability: .available,
                todayTokens: buckets.first(where: { $0.startDate == serviceDate })?.tokens,
                serviceDate: serviceDate,
                serviceTimeZoneIdentifier: serviceTimeZoneIdentifier ?? "server-defined (timezone unspecified)",
                dailyBuckets: buckets,
                fetchedAt: fetchedAt
            )
        }

        let utc = TimeZone(secondsFromGMT: 0)!
        return fromBuckets(
            buckets,
            now: now,
            timeZone: utc,
            serviceTimeZoneIdentifier: "UTC (assumed; API omits timezone)",
            fetchedAt: fetchedAt
        )
    }
}
