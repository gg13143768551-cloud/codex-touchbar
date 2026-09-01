import Foundation

@MainActor
public final class SelectionCoordinator {
    private let gateway: any CodexGateway
    private let store: DashboardStore

    public init(gateway: any CodexGateway, store: DashboardStore) {
        self.gateway = gateway
        self.store = store
    }

    public func choose(model modelName: String, preferredEffort: String?) async {
        guard !store.configurationWriteBlocked,
              !store.snapshot.pendingWrite,
              let option = store.snapshot.models.first(where: { $0.model == modelName }) else { return }
        let effort = option.compatibleEffort(preferred: preferredEffort ?? store.snapshot.selection?.effort)
        store.beginConfigurationWrite()
        do {
            let result = try await gateway.writeSelection(model: modelName, effort: effort)
            guard result.readbackMatched else {
                store.failConfigurationWrite("Configuration readback did not match")
                return
            }
            store.confirmConfiguration(result.selection)
        } catch let error as LocalizedError {
            store.failConfigurationWrite(error.errorDescription ?? "Configuration write failed")
        } catch {
            store.failConfigurationWrite("Configuration write failed")
        }
    }
}
