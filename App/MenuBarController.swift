import AppKit
import CodexTouchCore

@MainActor
final class MenuBarController: NSObject {
    var onRefresh: (() -> Void)?
    var onNextAccount: (() -> Void)?
    var onSelectProfile: ((UUID) -> Void)?
    var onSelectModel: ((String, String?) -> Void)?
    var onOpenPreferences: (() -> Void)?
    var onChooseCodex: (() -> Void)?

    private let store: DashboardStore
    private let registry: ProfileRegistry
    private let preferences: AtomicPreferences
    private let statusItem: NSStatusItem

    init(store: DashboardStore, registry: ProfileRegistry, preferences: AtomicPreferences) {
        self.store = store
        self.registry = registry
        self.preferences = preferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Codex Touch Bar")
        statusItem.button?.imagePosition = .imageOnly
        store.addObserver { [weak self] _ in self?.reload() }
        reload()
    }

    func reload() {
        let menu = NSMenu()
        let snapshot = store.snapshot
        switch snapshot.status() {
        case .ready: statusItem.button?.contentTintColor = .systemGreen
        case .working: statusItem.button?.contentTintColor = .systemBlue
        case .stale: statusItem.button?.contentTintColor = .systemYellow
        case .attention, .offline: statusItem.button?.contentTintColor = .systemRed
        }
        let status = NSMenuItem(title: statusTitle(snapshot), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let quotas = NSMenuItem(title: "Quota  \(quotaText(.fiveHour, snapshot: snapshot))  \(quotaText(.sevenDay, snapshot: snapshot))", action: nil, keyEquivalent: "")
        quotas.isEnabled = false
        menu.addItem(quotas)
        let usage = NSMenuItem(title: "Today  \(usageText(snapshot.usage))", action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)

        let modelTitle = snapshot.selection?.confirmed == false ? "Model (unconfirmed)" : "Model"
        let modelItem = NSMenuItem(title: modelTitle, action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for model in snapshot.models where !model.hidden {
            let item = NSMenuItem(title: model.displayName, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.model
            item.state = snapshot.selection?.model == model.model ? .on : .off
            modelMenu.addItem(item)
        }
        modelItem.submenu = modelMenu
        modelItem.isEnabled = !store.configurationWriteBlocked && !snapshot.pendingWrite
        menu.addItem(modelItem)

        let effortItem = NSMenuItem(title: "Reasoning effort", action: nil, keyEquivalent: "")
        let effortMenu = NSMenu()
        if let selectedModel = snapshot.models.first(where: { $0.model == snapshot.selection?.model }) {
            for effort in selectedModel.supportedReasoningEfforts {
                let item = NSMenuItem(title: effort.value, action: #selector(selectEffort(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = effort.value
                item.state = snapshot.selection?.effort == effort.value ? .on : .off
                effortMenu.addItem(item)
            }
        }
        effortItem.submenu = effortMenu
        effortItem.isEnabled = !store.configurationWriteBlocked && !snapshot.pendingWrite
        menu.addItem(effortItem)

        menu.addItem(.separator())
        let accounts = NSMenuItem(title: "Account  \(snapshot.profile.alias)", action: nil, keyEquivalent: "")
        let accountMenu = NSMenu()
        if let profiles = try? registry.allProfiles() {
            for profile in profiles {
                let item = NSMenuItem(title: profile.alias, action: #selector(selectProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
                item.state = profile.id == snapshot.profile.id ? .on : .off
                accountMenu.addItem(item)
            }
        }
        accounts.submenu = accountMenu
        menu.addItem(accounts)
        let oneTouch = NSMenuItem(title: "One-touch: \((try? preferences.read().oneTouchEnabled) == true ? "On" : "Off")", action: nil, keyEquivalent: "")
        oneTouch.isEnabled = false
        menu.addItem(oneTouch)
        let next = NSMenuItem(title: "Next account (A)", action: #selector(nextAccount), keyEquivalent: "")
        next.target = self
        next.isEnabled = (try? preferences.read().oneTouchEnabled) == true
        menu.addItem(next)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open Settings to authenticate...", action: #selector(openPreferences), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        let chooseCodex = NSMenuItem(title: "Choose Codex executable...", action: #selector(chooseCodex), keyEquivalent: "")
        chooseCodex.target = self
        menu.addItem(chooseCodex)
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings...", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Codex Touch Bar", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        onSelectModel?(model, store.snapshot.selection?.effort)
    }

    @objc private func selectEffort(_ sender: NSMenuItem) {
        guard let effort = sender.representedObject as? String, let model = store.snapshot.selection?.model else { return }
        onSelectModel?(model, effort)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onSelectProfile?(id)
    }

    @objc private func nextAccount() { onNextAccount?() }
    @objc private func refresh() { onRefresh?() }
    @objc private func openPreferences() { onOpenPreferences?() }
    @objc private func chooseCodex() { onChooseCodex?() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func statusTitle(_ snapshot: AppSnapshot) -> String {
        switch snapshot.status() {
        case .ready: return "Ready / \(snapshot.profile.alias)"
        case .working: return "Working / \(snapshot.profile.alias)"
        case .stale: return "Stale data / \(snapshot.profile.alias)"
        case .attention: return snapshot.authentication == .requiresLogin ? "Needs login / \(snapshot.profile.alias)" : "Attention / \(snapshot.profile.alias)"
        case .offline: return "Offline / \(snapshot.profile.alias)"
        }
    }

    private func quotaText(_ kind: QuotaKind, snapshot: AppSnapshot) -> String {
        guard let window = snapshot.quota.current(kind, now: Date()) else { return "\(kind.rawValue) --" }
        let reset = window.resetsAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "reset unknown"
        return "\(kind.rawValue) \(window.remainingPercent)% (\(reset))"
    }

    private func usageText(_ usage: UsageSnapshot) -> String {
        switch usage.availability {
        case .available: return usage.todayTokens.map(formatTokens) ?? "-- (service date unavailable)"
        case .unsupported: return "unsupported"
        case .unavailable: return "--"
        }
    }

    private func formatTokens(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}
