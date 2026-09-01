import Foundation

public enum AccountSwitchState: Equatable, Sendable {
    case idle
    case opening(UUID)
    case validating(UUID)
    case committing(UUID)
    case completed(UUID)
    case failed(String)
}

@MainActor
public final class AccountSwitchCoordinator {
    public private(set) var state: AccountSwitchState = .idle
    public var onStateChange: ((AccountSwitchState) -> Void)?
    public var activeGateway: (any CodexGateway)? { currentGateway }

    private let registry: ProfileRegistry
    private let preferences: AtomicPreferences
    private var factory: any CodexSessionFactory
    private let store: DashboardStore
    private var currentGateway: (any CodexGateway)?
    private var switchInProgress = false

    public init(
        registry: ProfileRegistry,
        preferences: AtomicPreferences,
        factory: any CodexSessionFactory,
        store: DashboardStore,
        currentGateway: (any CodexGateway)? = nil
    ) {
        self.registry = registry
        self.preferences = preferences
        self.factory = factory
        self.store = store
        self.currentGateway = currentGateway
    }

    public func switchTo(profileID: UUID) async {
        guard !switchInProgress else { return }
        guard profileID != store.snapshot.profile.id else { return }
        guard !store.snapshot.pendingWrite else {
            setState(.failed("Wait for the configuration write to finish"))
            return
        }
        guard !store.snapshot.pluginTurnInProgress else {
            setState(.failed("Account switching is unavailable while a managed turn is running"))
            return
        }
        guard let target = try? registry.profile(id: profileID) else {
            setState(.failed("Profile is not registered"))
            return
        }

        switchInProgress = true
        store.beginAccountSwitch()
        defer { switchInProgress = false }
        setState(.opening(profileID))
        var newGateway: (any CodexGateway)?
        do {
            let opened = try await factory.open(profile: target)
            newGateway = opened
            setState(.validating(profileID))
            let nextSnapshot = try await opened.readSnapshot()
            guard nextSnapshot.connection == .connected,
                  nextSnapshot.authentication == .authenticated,
                  nextSnapshot.profile.id == target.id,
                  nextSnapshot.usage.availability != .unavailable,
                  let serverHome = nextSnapshot.serverCodexHome,
                  serverHome.standardizedFileURL.path == target.codexHome.standardizedFileURL.path else {
                throw GatewayError.profileMismatch
            }

            setState(.committing(profileID))
            // This is the only durable mutation that selects the active profile, and it occurs last.
            _ = try preferences.setSelectedProfileID(profileID)
            let oldGateway = currentGateway
            currentGateway = opened
            await oldGateway?.stop()
            store.resetConfigurationState()
            store.replace(nextSnapshot)
            setState(.completed(profileID))
        } catch let error as LocalizedError {
            await newGateway?.stop()
            let message = error.errorDescription ?? "Profile switch failed"
            store.endAccountSwitch(errorMessage: message)
            setState(.failed(message))
        } catch {
            await newGateway?.stop()
            let message = "Profile switch failed"
            store.endAccountSwitch(errorMessage: message)
            setState(.failed(message))
        }
    }

    public func switchToNext() async {
        guard (try? preferences.read().oneTouchEnabled) == true else {
            setState(.failed("One-touch switching is disabled"))
            return
        }
        guard let profiles = try? registry.allProfiles(), !profiles.isEmpty else {
            setState(.failed("No profiles are registered"))
            return
        }
        let preferencesValue = try? preferences.read()
        let ordered = preferencesValue?.orderedProfileIDs ?? []
        let orderedProfiles = ordered.compactMap { id in profiles.first(where: { $0.id == id }) }
        let remaining = profiles.filter { !ordered.contains($0.id) }
        let list = orderedProfiles + remaining
        guard let currentIndex = list.firstIndex(where: { $0.id == store.snapshot.profile.id }) else {
            await switchTo(profileID: list[0].id)
            return
        }
        await switchTo(profileID: list[(currentIndex + 1) % list.count].id)
    }

    public func stop() async { await currentGateway?.stop() }

    public func adoptCurrentGateway(_ gateway: any CodexGateway) {
        currentGateway = gateway
    }

    public func updateFactory(_ factory: any CodexSessionFactory) {
        self.factory = factory
    }

    private func setState(_ value: AccountSwitchState) {
        state = value
        onStateChange?(value)
    }
}
