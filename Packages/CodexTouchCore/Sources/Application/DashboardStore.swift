import Foundation

@MainActor
public final class DashboardStore {
    public private(set) var snapshot: AppSnapshot
    public private(set) var configurationWriteBlocked = false
    public var onChange: ((AppSnapshot) -> Void)?
    private var observers: [UUID: (AppSnapshot) -> Void] = [:]

    public init(profile: AccountProfile) {
        self.snapshot = .empty(profile: profile)
    }

    public func replace(_ snapshot: AppSnapshot) {
        self.snapshot = snapshot
        notify()
    }

    /// Applies a polling result only while the coordinator still owns the
    /// profile it was created for. A refresh must not overwrite a newly
    /// committed account switch or clear an in-flight configuration lock.
    public func applyRefresh(_ refreshed: AppSnapshot, expectedProfileID: UUID) {
        guard snapshot.profile.id == expectedProfileID,
              refreshed.profile.id == expectedProfileID else { return }
        if snapshot.pendingWrite {
            self.snapshot = AppSnapshot(
                profile: refreshed.profile,
                serverCodexHome: refreshed.serverCodexHome,
                account: refreshed.account,
                connection: refreshed.connection,
                authentication: refreshed.authentication,
                quota: refreshed.quota,
                usage: refreshed.usage,
                models: refreshed.models,
                selection: snapshot.selection,
                pluginTurnInProgress: refreshed.pluginTurnInProgress,
                pendingWrite: true,
                errorMessage: snapshot.errorMessage,
                fetchedAt: refreshed.fetchedAt
            )
        } else {
            self.snapshot = refreshed
        }
        notify()
    }

    @discardableResult
    public func addObserver(_ observer: @escaping (AppSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func resetConfigurationState() {
        configurationWriteBlocked = false
    }

    public func markConnecting(expectedProfileID: UUID? = nil) {
        if let expectedProfileID, snapshot.profile.id != expectedProfileID { return }
        snapshot = AppSnapshot(
            profile: snapshot.profile,
            serverCodexHome: snapshot.serverCodexHome,
            account: snapshot.account,
            connection: .connecting,
            authentication: snapshot.authentication,
            quota: snapshot.quota,
            usage: snapshot.usage,
            models: snapshot.models,
            selection: snapshot.selection,
            pluginTurnInProgress: snapshot.pluginTurnInProgress,
            pendingWrite: snapshot.pendingWrite,
            errorMessage: snapshot.errorMessage,
            fetchedAt: snapshot.fetchedAt
        )
        notify()
    }

    public func recordRefreshFailure(_ message: String, expectedProfileID: UUID? = nil) {
        if let expectedProfileID, snapshot.profile.id != expectedProfileID { return }
        snapshot = AppSnapshot(
            profile: snapshot.profile,
            serverCodexHome: snapshot.serverCodexHome,
            account: snapshot.account,
            connection: .disconnected,
            authentication: snapshot.authentication,
            quota: snapshot.quota,
            usage: snapshot.usage,
            models: snapshot.models,
            selection: snapshot.selection,
            pluginTurnInProgress: snapshot.pluginTurnInProgress,
            pendingWrite: snapshot.pendingWrite,
            errorMessage: message,
            fetchedAt: snapshot.fetchedAt
        )
        notify()
    }

    public func beginConfigurationWrite() {
        configurationWriteBlocked = false
        snapshot = withPendingWrite(true)
        notify()
    }

    public func beginAccountSwitch() {
        snapshot = withPendingWrite(true)
        notify()
    }

    public func endAccountSwitch(errorMessage: String) {
        snapshot = withPendingWrite(false, errorMessage: errorMessage)
        notify()
    }

    public func confirmConfiguration(_ selection: ModelSelection) {
        configurationWriteBlocked = false
        snapshot = withSelection(selection, pendingWrite: false, errorMessage: nil)
        notify()
    }

    public func failConfigurationWrite(_ message: String) {
        configurationWriteBlocked = true
        let unconfirmedSelection = snapshot.selection.map {
            ModelSelection(model: $0.model, effort: $0.effort, confirmed: false)
        }
        snapshot = withSelection(unconfirmedSelection, pendingWrite: false, errorMessage: message)
        notify()
    }

    public func setPluginTurnInProgress(_ value: Bool) {
        snapshot = AppSnapshot(
            profile: snapshot.profile,
            serverCodexHome: snapshot.serverCodexHome,
            account: snapshot.account,
            connection: snapshot.connection,
            authentication: snapshot.authentication,
            quota: snapshot.quota,
            usage: snapshot.usage,
            models: snapshot.models,
            selection: snapshot.selection,
            pluginTurnInProgress: value,
            pendingWrite: snapshot.pendingWrite,
            errorMessage: snapshot.errorMessage,
            fetchedAt: snapshot.fetchedAt
        )
        notify()
    }

    private func withPendingWrite(_ pendingWrite: Bool, errorMessage: String? = nil) -> AppSnapshot {
        AppSnapshot(
            profile: snapshot.profile,
            serverCodexHome: snapshot.serverCodexHome,
            account: snapshot.account,
            connection: snapshot.connection,
            authentication: snapshot.authentication,
            quota: snapshot.quota,
            usage: snapshot.usage,
            models: snapshot.models,
            selection: snapshot.selection,
            pluginTurnInProgress: snapshot.pluginTurnInProgress,
            pendingWrite: pendingWrite,
            errorMessage: errorMessage ?? snapshot.errorMessage,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func withSelection(_ selection: ModelSelection, pendingWrite: Bool, errorMessage: String?) -> AppSnapshot {
        AppSnapshot(
            profile: snapshot.profile,
            serverCodexHome: snapshot.serverCodexHome,
            account: snapshot.account,
            connection: snapshot.connection,
            authentication: snapshot.authentication,
            quota: snapshot.quota,
            usage: snapshot.usage,
            models: snapshot.models,
            selection: selection,
            pluginTurnInProgress: snapshot.pluginTurnInProgress,
            pendingWrite: pendingWrite,
            errorMessage: errorMessage,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private func notify() {
        onChange?(snapshot)
        observers.values.forEach { $0(snapshot) }
    }
}
