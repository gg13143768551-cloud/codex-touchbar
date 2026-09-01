import Foundation

@MainActor
public final class RefreshCoordinator {
    private let gateway: any CodexGateway
    private let store: DashboardStore
    private var task: Task<Void, Never>?
    private let interval: TimeInterval
    private let expectedProfileID: UUID
    private var consecutiveFailures = 0

    public init(gateway: any CodexGateway, store: DashboardStore, interval: TimeInterval = 60) {
        self.gateway = gateway
        self.store = store
        self.interval = interval
        self.expectedProfileID = store.snapshot.profile.id
    }

    public func start() {
        stop()
        consecutiveFailures = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds: TimeInterval
                if let self, self.store.snapshot.connection == .disconnected {
                    self.consecutiveFailures = min(self.consecutiveFailures + 1, 6)
                    seconds = min(60, max(1, pow(2, Double(self.consecutiveFailures))))
                } else {
                    self?.consecutiveFailures = 0
                    seconds = max(1, (self?.interval ?? 60) + Double.random(in: 0...5))
                }
                let nanos = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func refresh() async {
        guard store.snapshot.profile.id == expectedProfileID else { return }
        store.markConnecting(expectedProfileID: expectedProfileID)
        do {
            let refreshed = try await gateway.readSnapshot()
            store.applyRefresh(refreshed, expectedProfileID: expectedProfileID)
        } catch let error as LocalizedError {
            store.recordRefreshFailure(error.errorDescription ?? "Refresh failed", expectedProfileID: expectedProfileID)
        } catch {
            store.recordRefreshFailure("Refresh failed", expectedProfileID: expectedProfileID)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
