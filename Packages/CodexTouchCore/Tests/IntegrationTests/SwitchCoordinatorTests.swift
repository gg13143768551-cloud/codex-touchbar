import XCTest
import CodexTouchCore

final class SwitchCoordinatorTests: XCTestCase {
    func testSwitchDoesNotCommitWhenTargetValidationFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = try ProfileRegistry(rootDirectory: root.appendingPathComponent("Profiles"))
        let old = try registry.register(alias: "Old")
        let target = try registry.register(alias: "Target")
        let prefs = try AtomicPreferences(fileURL: root.appendingPathComponent("preferences.json"))
        _ = try prefs.write(Preferences(selectedProfileID: old.id))
        let store = await MainActor.run { DashboardStore(profile: old) }
        let factory = MockFactory(gateway: MockGateway(snapshot: AppSnapshot(profile: target, serverCodexHome: URL(fileURLWithPath: "/wrong"), account: AccountIdentity(kind: .chatGPT), connection: .connected, authentication: .authenticated)))
        let coordinator = await MainActor.run { AccountSwitchCoordinator(registry: registry, preferences: prefs, factory: factory, store: store) }
        await coordinator.switchTo(profileID: target.id)
        XCTAssertEqual(try prefs.read().selectedProfileID, old.id)
        let state = await MainActor.run { coordinator.state }
        if case .failed = state {} else { XCTFail("expected failed state") }
    }

    func testSwitchDoesNotStartDuringConfigurationWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = try ProfileRegistry(rootDirectory: root.appendingPathComponent("Profiles"))
        let old = try registry.register(alias: "Old")
        let target = try registry.register(alias: "Target")
        let prefs = try AtomicPreferences(fileURL: root.appendingPathComponent("preferences.json"))
        _ = try prefs.write(Preferences(selectedProfileID: old.id))
        let store = await MainActor.run { DashboardStore(profile: old) }
        await MainActor.run { store.beginConfigurationWrite() }
        let validSnapshot = AppSnapshot(
            profile: target,
            serverCodexHome: target.codexHome,
            account: AccountIdentity(kind: .chatGPT),
            connection: .connected,
            authentication: .authenticated
        )
        let factory = MockFactory(gateway: MockGateway(snapshot: validSnapshot))
        let coordinator = await MainActor.run {
            AccountSwitchCoordinator(registry: registry, preferences: prefs, factory: factory, store: store)
        }

        await coordinator.switchTo(profileID: target.id)

        XCTAssertEqual(try prefs.read().selectedProfileID, old.id)
        let state = await MainActor.run { coordinator.state }
        if case .failed = state {} else { XCTFail("expected failed state") }
    }

    func testSwitchCommitsCompleteAuthenticatedTargetSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = try ProfileRegistry(rootDirectory: root.appendingPathComponent("Profiles"))
        let old = try registry.register(alias: "Old")
        let target = try registry.register(alias: "Target")
        let prefs = try AtomicPreferences(fileURL: root.appendingPathComponent("preferences.json"))
        _ = try prefs.write(Preferences(selectedProfileID: old.id))
        let store = await MainActor.run { DashboardStore(profile: old) }
        let now = Date()
        let quota = QuotaParser.parse(
            windows: [WireQuotaWindow(windowDurationMins: 300, usedPercent: 10, resetsAt: nil)],
            fetchedAt: now
        )
        let usage = UsageSnapshot(availability: .available, todayTokens: 100, serviceDate: "2026-09-01", fetchedAt: now)
        let validSnapshot = AppSnapshot(
            profile: target,
            serverCodexHome: target.codexHome,
            account: AccountIdentity(kind: .chatGPT),
            connection: .connected,
            authentication: .authenticated,
            quota: quota,
            usage: usage
        )
        let coordinator = await MainActor.run {
            AccountSwitchCoordinator(
                registry: registry,
                preferences: prefs,
                factory: MockFactory(gateway: MockGateway(snapshot: validSnapshot)),
                store: store
            )
        }

        await coordinator.switchTo(profileID: target.id)

        XCTAssertEqual(try prefs.read().selectedProfileID, target.id)
        let activeProfileID = await MainActor.run { store.snapshot.profile.id }
        XCTAssertEqual(activeProfileID, target.id)
    }
}

struct MockFactory: CodexSessionFactory {
    let gateway: any CodexGateway
    func open(profile: AccountProfile) async throws -> any CodexGateway { gateway }
}

actor MockGateway: CodexGateway {
    let snapshot: AppSnapshot
    init(snapshot: AppSnapshot) { self.snapshot = snapshot }
    func readSnapshot() async throws -> AppSnapshot { snapshot }
    func writeSelection(model: String, effort: String) async throws -> ConfigWriteResult { ConfigWriteResult(selection: ModelSelection(model: model, effort: effort, confirmed: true), readbackMatched: true) }
    func startTurn(threadID: String, input: String, selection: ModelSelection) async throws {}
    func stop() async {}
}
