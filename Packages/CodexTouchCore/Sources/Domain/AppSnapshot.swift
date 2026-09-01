import Foundation

public enum ConnectionState: String, Codable, Sendable {
    case connected
    case connecting
    case disconnected
}

public enum AuthenticationState: String, Codable, Sendable {
    case authenticated
    case requiresLogin
    case unknown
}

public enum StatusSeverity: String, Codable, Sendable {
    case ready
    case working
    case stale
    case attention
    case offline
}

public struct StatusSignals: Equatable, Sendable {
    public let connection: ConnectionState
    public let authentication: AuthenticationState
    public let quotaFreshness: DataFreshness
    public let usageFreshness: DataFreshness
    public let pluginTurnInProgress: Bool
    public let pendingWrite: Bool

    public init(
        connection: ConnectionState,
        authentication: AuthenticationState,
        quotaFreshness: DataFreshness,
        usageFreshness: DataFreshness,
        pluginTurnInProgress: Bool,
        pendingWrite: Bool
    ) {
        self.connection = connection
        self.authentication = authentication
        self.quotaFreshness = quotaFreshness
        self.usageFreshness = usageFreshness
        self.pluginTurnInProgress = pluginTurnInProgress
        self.pendingWrite = pendingWrite
    }
}

public enum StatusAggregator {
    public static func severity(_ signals: StatusSignals) -> StatusSeverity {
        if signals.connection == .disconnected { return .offline }
        if signals.connection == .connecting { return .working }
        if signals.authentication != .authenticated { return .attention }
        if signals.pendingWrite { return .attention }
        if signals.pluginTurnInProgress { return .working }
        if signals.quotaFreshness == .unavailable || signals.usageFreshness == .unavailable { return .stale }
        if signals.quotaFreshness == .stale || signals.usageFreshness == .stale { return .stale }
        return .ready
    }
}

public struct AppSnapshot: Codable, Equatable, Sendable {
    public let profile: AccountProfile
    public let serverCodexHome: URL?
    public let account: AccountIdentity?
    public let connection: ConnectionState
    public let authentication: AuthenticationState
    public let quota: QuotaSnapshot
    public let usage: UsageSnapshot
    public let models: [ModelOption]
    public let selection: ModelSelection?
    public let pluginTurnInProgress: Bool
    public let pendingWrite: Bool
    public let errorMessage: String?
    public let fetchedAt: Date?

    public init(
        profile: AccountProfile,
        serverCodexHome: URL? = nil,
        account: AccountIdentity? = nil,
        connection: ConnectionState = .disconnected,
        authentication: AuthenticationState = .unknown,
        quota: QuotaSnapshot = QuotaSnapshot(),
        usage: UsageSnapshot = UsageSnapshot(availability: .unavailable),
        models: [ModelOption] = [],
        selection: ModelSelection? = nil,
        pluginTurnInProgress: Bool = false,
        pendingWrite: Bool = false,
        errorMessage: String? = nil,
        fetchedAt: Date? = nil
    ) {
        self.profile = profile
        self.serverCodexHome = serverCodexHome
        self.account = account
        self.connection = connection
        self.authentication = authentication
        self.quota = quota
        self.usage = usage
        self.models = models
        self.selection = selection
        self.pluginTurnInProgress = pluginTurnInProgress
        self.pendingWrite = pendingWrite
        self.errorMessage = errorMessage
        self.fetchedAt = fetchedAt
    }

    public static func empty(profile: AccountProfile) -> AppSnapshot {
        AppSnapshot(profile: profile)
    }

    public func status(now: Date = Date()) -> StatusSeverity {
        let usageFreshness: DataFreshness
        if let fetchedAt = usage.fetchedAt {
            let age = now.timeIntervalSince(fetchedAt)
            usageFreshness = age <= 120 ? .fresh : (age <= 600 ? .stale : .unavailable)
        } else {
            // An older server that explicitly does not implement account
            // usage is a capability limitation, not stale transport data.
            usageFreshness = usage.availability == .unsupported ? .fresh : .unavailable
        }
        let severity = StatusAggregator.severity(StatusSignals(
            connection: connection,
            authentication: authentication,
            quotaFreshness: quota.freshness(now: now),
            usageFreshness: usageFreshness,
            pluginTurnInProgress: pluginTurnInProgress,
            pendingWrite: pendingWrite
        ))
        if errorMessage != nil, severity != .offline { return .attention }
        return severity
    }
}
