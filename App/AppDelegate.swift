import AppKit
import CodexTouchCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var registry: ProfileRegistry!
    private var preferences: AtomicPreferences!
    private var store: DashboardStore!
    private var factory: (any CodexSessionFactory)!
    private var gateway: (any CodexGateway)?
    private var refreshCoordinator: RefreshCoordinator?
    private var selectionCoordinator: SelectionCoordinator?
    private var switchCoordinator: AccountSwitchCoordinator!
    private var menuBarController: MenuBarController!
    private var touchBarController: TouchBarController!
    private var preferencesWindow: PreferencesWindowController?
    private var capability: CodexCapability?
    private var loginProcess: Process?
    private var snapshotCache: SnapshotCache!
    private let logger = RedactingLogger()
    private var systemObserverTokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
        do {
            try bootstrap()
        } catch {
            showFatalSetupError(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemObserverTokens.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        if loginProcess?.isRunning == true { loginProcess?.terminate() }
        Task { await switchCoordinator?.stop() }
    }

    private func bootstrap() throws {
        registry = try ProfileRegistry()
        let preferencesURL = registry.rootDirectory.deletingLastPathComponent().appendingPathComponent("preferences.json")
        preferences = try AtomicPreferences(fileURL: preferencesURL)

        var profiles = try registry.allProfiles()
        if profiles.isEmpty { profiles = [try registry.register(alias: "Default")] }
        var saved = try preferences.read()
        if saved.selectedProfileID == nil || !profiles.contains(where: { $0.id == saved.selectedProfileID }) {
            saved.selectedProfileID = profiles[0].id
        }
        saved.orderedProfileIDs = (saved.orderedProfileIDs + profiles.map(\.id)).reduce(into: []) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        _ = try preferences.write(saved)
        guard let selectedID = saved.selectedProfileID, let profile = profiles.first(where: { $0.id == selectedID }) else {
            throw ProfileRegistryError.missingProfile
        }

        store = DashboardStore(profile: profile)
        let cacheDirectory = registry.rootDirectory.deletingLastPathComponent().appendingPathComponent("Cache", isDirectory: true)
        snapshotCache = try SnapshotCache(directory: cacheDirectory)
        do {
            if let cached = try snapshotCache.read(profileID: profile.id) {
                let cachedSnapshot = AppSnapshot(
                    profile: profile,
                    connection: .disconnected,
                    authentication: .unknown,
                    quota: cached.quota,
                    usage: cached.usage,
                    fetchedAt: cached.savedAt
                )
                store.replace(cachedSnapshot)
            }
        } catch {
            logger.error(code: "cache_read_failed", method: "snapshot-cache", version: nil, elapsedMilliseconds: 0)
        }
        store.addObserver { [weak self] snapshot in
            do {
                try self?.snapshotCache.write(profileID: snapshot.profile.id, quota: snapshot.quota, usage: snapshot.usage)
            } catch {
                self?.logger.error(code: "cache_write_failed", method: "snapshot-cache", version: self?.capability?.version, elapsedMilliseconds: 0)
            }
        }
        touchBarController = TouchBarController(store: store)
        touchBarController.isAccountSwitchEnabled = { [weak self] in
            guard let self else { return false }
            return (try? self.preferences.read().oneTouchEnabled) == true
        }
        menuBarController = MenuBarController(store: store, registry: registry, preferences: preferences)
        menuBarController.onRefresh = { [weak self] in Task { await self?.refreshCoordinator?.refresh() } }
        menuBarController.onNextAccount = { [weak self] in Task { await self?.switchCoordinator?.switchToNext() } }
        menuBarController.onSelectProfile = { [weak self] id in Task { await self?.switchCoordinator?.switchTo(profileID: id) } }
        menuBarController.onSelectModel = { [weak self] model, effort in Task { await self?.selectionCoordinator?.choose(model: model, preferredEffort: effort) } }
        menuBarController.onOpenPreferences = { [weak self] in self?.openPreferences() }
        menuBarController.onChooseCodex = { [weak self] in self?.chooseCodexExecutable() }
        touchBarController.onNextAccount = { [weak self] in Task { await self?.switchCoordinator?.switchToNext() } }
        touchBarController.onSelectModel = { [weak self] model, effort in Task { await self?.selectionCoordinator?.choose(model: model, preferredEffort: effort) } }

        do {
            capability = try CapabilityResolver().resolve(explicitURL: saved.codexExecutablePath)
            factory = LiveCodexSessionFactory(capability: capability!)
        } catch {
            factory = UnsupportedSessionFactory(reason: "Codex executable not found; choose a valid Codex installation")
        }

        let initialGateway: any CodexGateway = UnsupportedAdapter(reason: "Connecting to Codex")
        gateway = initialGateway
        switchCoordinator = AccountSwitchCoordinator(
            registry: registry,
            preferences: preferences,
            factory: factory,
            store: store,
            currentGateway: initialGateway
        )
        switchCoordinator.onStateChange = { [weak self] state in self?.handleSwitchState(state) }
        selectionCoordinator = SelectionCoordinator(gateway: initialGateway, store: store)
        installSystemObservers()
        connect(to: profile)
    }

    private func installSystemObservers() {
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshCoordinator?.refresh() }
        }
        let timeZone = NotificationCenter.default.addObserver(
            forName: NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
                Task { @MainActor in await self?.refreshCoordinator?.refresh() }
        }
        systemObserverTokens = [wake, timeZone]
    }

    private func connect(to profile: AccountProfile) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await self.factory.open(profile: profile)
                self.gateway = opened
                self.switchCoordinator.adoptCurrentGateway(opened)
                self.selectionCoordinator = SelectionCoordinator(gateway: opened, store: self.store)
                self.refreshCoordinator?.stop()
                self.refreshCoordinator = RefreshCoordinator(gateway: opened, store: self.store)
                await self.refreshCoordinator?.refresh()
                self.refreshCoordinator?.start()
            } catch let error as LocalizedError {
                self.store.recordRefreshFailure(error.errorDescription ?? "Codex connection failed")
            } catch {
                self.store.recordRefreshFailure("Codex connection failed")
            }
        }
    }

    private func handleSwitchState(_ state: AccountSwitchState) {
        guard case .completed = state, let newGateway = switchCoordinator.activeGateway else { return }
        gateway = newGateway
        selectionCoordinator = SelectionCoordinator(gateway: newGateway, store: store)
        refreshCoordinator?.stop()
        refreshCoordinator = RefreshCoordinator(gateway: newGateway, store: store)
        refreshCoordinator?.start()
        menuBarController.reload()
        preferencesWindow?.refresh()
    }

    private func openPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(
                registry: registry,
                preferences: preferences,
                store: store,
                touchBarController: touchBarController,
                onSelectProfile: { [weak self] id in Task { await self?.switchCoordinator?.switchTo(profileID: id) } },
                onLogin: { [weak self] id in self?.startOfficialLogin(profileID: id) },
                onChooseCodex: { [weak self] in self?.chooseCodexExecutable() }
            )
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startOfficialLogin(profileID: UUID) {
        guard loginProcess == nil,
              !store.snapshot.pendingWrite,
              !store.snapshot.pluginTurnInProgress,
              let capability,
              let profile = try? registry.profile(id: profileID) else { return }
        let process = Process()
        process.executableURL = capability.executableURL
        process.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_ACCESS_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = profile.codexHome.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                self?.loginProcess = nil
                if finishedProcess.terminationStatus == 0 {
                    if self?.store.snapshot.profile.id == profileID {
                        await self?.refreshCoordinator?.refresh()
                    } else {
                        await self?.switchCoordinator?.switchTo(profileID: profileID)
                    }
                } else {
                    await self?.refreshCoordinator?.refresh()
                }
            }
        }
        do {
            loginProcess = process
            try process.run()
        } catch {
            loginProcess = nil
            store.recordRefreshFailure("Unable to start official Codex login")
        }
    }

    private func chooseCodexExecutable() {
        guard !store.snapshot.pendingWrite,
              !store.snapshot.pluginTurnInProgress else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Choose the Codex CLI executable"
        panel.prompt = "Use Codex"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let selectedCapability = try CapabilityResolver().resolve(explicitURL: url)
            let selectedFactory = LiveCodexSessionFactory(capability: selectedCapability)
            var value = try preferences.read()
            value.codexExecutablePath = selectedCapability.executableURL
            _ = try preferences.write(value)
            capability = selectedCapability
            factory = selectedFactory
            switchCoordinator.updateFactory(selectedFactory)
            reconnectCurrentProfile()
        } catch let error as LocalizedError {
            store.recordRefreshFailure(error.errorDescription ?? "Codex executable is not compatible")
        } catch {
            store.recordRefreshFailure("Codex executable is not compatible")
        }
    }

    private func reconnectCurrentProfile() {
        let profile = store.snapshot.profile
        let oldGateway = gateway
        Task { [weak self] in
            guard let self else { return }
            var opened: (any CodexGateway)?
            do {
                let candidate = try await self.factory.open(profile: profile)
                opened = candidate
                let nextSnapshot = try await candidate.readSnapshot()
                guard nextSnapshot.connection == .connected, nextSnapshot.authentication == .authenticated else {
                    throw GatewayError.notAuthenticated
                }
                self.gateway = candidate
                self.switchCoordinator.adoptCurrentGateway(candidate)
                self.selectionCoordinator = SelectionCoordinator(gateway: candidate, store: self.store)
                self.store.resetConfigurationState()
                self.store.replace(nextSnapshot)
                await oldGateway?.stop()
                self.refreshCoordinator?.stop()
                self.refreshCoordinator = RefreshCoordinator(gateway: candidate, store: self.store)
                self.refreshCoordinator?.start()
            } catch let error as LocalizedError {
                await opened?.stop()
                self.store.recordRefreshFailure(error.errorDescription ?? "Codex reconnect failed")
            } catch {
                await opened?.stop()
                self.store.recordRefreshFailure("Codex reconnect failed")
            }
        }
    }

    private func showFatalSetupError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Codex Touch Bar could not start"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
        NSApp.terminate(nil)
    }
}
