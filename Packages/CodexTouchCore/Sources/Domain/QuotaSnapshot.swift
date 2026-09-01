import Foundation

public enum QuotaKind: String, Codable, CaseIterable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let kind: QuotaKind
    public let usedPercent: Int
    public let remainingPercent: Int
    public let resetsAt: Date?
    public let fetchedAt: Date

    public init(kind: QuotaKind, usedPercent: Int, resetsAt: Date?, fetchedAt: Date) {
        self.kind = kind
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.remainingPercent = min(max(100 - usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let windows: [QuotaKind: QuotaWindow]
    public let fetchedAt: Date?

    public init(windows: [QuotaKind: QuotaWindow] = [:], fetchedAt: Date? = nil) {
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public func lastKnown(_ kind: QuotaKind) -> QuotaWindow? { windows[kind] }

    /// The last known value is retained for diagnostics, but becomes non-current after ten minutes.
    public func current(_ kind: QuotaKind, now: Date, staleAfter: TimeInterval = 600) -> QuotaWindow? {
        guard let window = windows[kind], now.timeIntervalSince(window.fetchedAt) <= staleAfter else { return nil }
        return window
    }

    public func freshness(now: Date, staleAfter: TimeInterval = 120) -> DataFreshness {
        guard let fetchedAt else { return .unavailable }
        let age = now.timeIntervalSince(fetchedAt)
        if age <= staleAfter { return .fresh }
        if age <= 600 { return .stale }
        return .unavailable
    }
}

public enum DataFreshness: String, Codable, Sendable {
    case fresh
    case stale
    case unavailable
}

public enum QuotaParser {
    public static func parse(
        windows: [WireQuotaWindow],
        fetchedAt: Date = Date()
    ) -> QuotaSnapshot {
        var values: [QuotaKind: QuotaWindow] = [:]
        for wire in windows {
            guard let duration = wire.windowDurationMins else { continue }
            let kind: QuotaKind?
            switch duration {
            case 300: kind = .fiveHour
            case 10_080: kind = .sevenDay
            default: kind = nil
            }
            guard let kind else { continue }
            let reset = wire.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            values[kind] = QuotaWindow(kind: kind, usedPercent: wire.usedPercent, resetsAt: reset, fetchedAt: fetchedAt)
        }
        return QuotaSnapshot(windows: values, fetchedAt: values.isEmpty ? nil : fetchedAt)
    }
}

/// The exact app-server response is decoded by the stable protocol adapter.
/// Keeping this small wire model here makes quota parsing independently testable.
public struct WireQuotaWindow: Equatable, Sendable {
    public let windowDurationMins: Int64?
    public let usedPercent: Int
    public let resetsAt: Int64?

    public init(windowDurationMins: Int64?, usedPercent: Int, resetsAt: Int64?) {
        self.windowDurationMins = windowDurationMins
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}
