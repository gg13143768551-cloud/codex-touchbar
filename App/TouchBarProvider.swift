import AppKit
import CodexTouchCore

@MainActor
final class TouchBarProvider: NSObject, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate {
    static let quota5 = NSTouchBarItem.Identifier("com.codex.touchbar.quota.5h")
    static let quota7 = NSTouchBarItem.Identifier("com.codex.touchbar.quota.7d")
    static let tokens = NSTouchBarItem.Identifier("com.codex.touchbar.tokens.today")
    static let model = NSTouchBarItem.Identifier("com.codex.touchbar.model")
    static let effort = NSTouchBarItem.Identifier("com.codex.touchbar.effort")
    static let status = NSTouchBarItem.Identifier("com.codex.touchbar.status")
    static let account = NSTouchBarItem.Identifier("com.codex.touchbar.account")
    private static let modelScrubber = NSTouchBarItem.Identifier("com.codex.touchbar.model.scrubber")

    private let store: DashboardStore
    private weak var activeTouchBar: NSTouchBar?
    private weak var modelScrubberView: NSScrubber?
    var onNextAccount: (() -> Void)?
    var onSelectModel: ((String, String?) -> Void)?
    var isAccountSwitchEnabled: (() -> Bool)?

    init(store: DashboardStore) {
        self.store = store
        super.init()
        store.addObserver { [weak self] _ in self?.reload() }
    }

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.quota5, Self.quota7, Self.tokens, Self.model, Self.effort, Self.status, Self.account]
        activeTouchBar = touchBar
        return touchBar
    }

    func reload() {
        guard let bar = activeTouchBar else { return }
        let snapshot = store.snapshot
        modelScrubberView?.reloadData()
        (bar.item(forIdentifier: Self.quota5) as? NSCustomTouchBarItem)?.view = label("5h \(snapshot.quota.current(.fiveHour, now: Date()).map { "\($0.remainingPercent)%" } ?? "--")", tooltip: quotaTooltip(.fiveHour, snapshot: snapshot))
        (bar.item(forIdentifier: Self.quota7) as? NSCustomTouchBarItem)?.view = label("7d \(snapshot.quota.current(.sevenDay, now: Date()).map { "\($0.remainingPercent)%" } ?? "--")", tooltip: quotaTooltip(.sevenDay, snapshot: snapshot))
        (bar.item(forIdentifier: Self.tokens) as? NSCustomTouchBarItem)?.view = label("Today \(todayText(snapshot.usage))", tooltip: usageTooltip(snapshot.usage))
        (bar.item(forIdentifier: Self.model) as? NSPopoverTouchBarItem)?.collapsedRepresentationLabel = snapshot.selection?.model ?? "Model"
        let effortLabel = snapshot.selection.map { $0.confirmed ? $0.effort : "\($0.effort)?" } ?? "Effort"
        (bar.item(forIdentifier: Self.effort) as? NSCustomTouchBarItem)?.view = effortButton(title: effortLabel)
        (bar.item(forIdentifier: Self.status) as? NSCustomTouchBarItem)?.view = statusField(snapshot)
        (bar.item(forIdentifier: Self.account) as? NSCustomTouchBarItem)?.view = accountButton(snapshot)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.quota5: return textItem(identifier, text: "5h --")
        case Self.quota7: return textItem(identifier, text: "7d --")
        case Self.tokens: return textItem(identifier, text: "Today --")
        case Self.effort:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = effortButton(title: "Effort")
            return item
        case Self.status: return textItem(identifier, text: "Offline")
        case Self.account:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = accountButton(store.snapshot)
            return item
        case Self.model:
            let item = NSPopoverTouchBarItem(identifier: identifier)
            item.collapsedRepresentationLabel = store.snapshot.selection?.model ?? "Model"
            item.popoverTouchBar = modelPopover()
            return item
        case Self.modelScrubber:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber()
            scrubber.dataSource = self
            scrubber.delegate = self
            scrubber.mode = .fixed
            scrubber.backgroundColor = .clear
            scrubber.translatesAutoresizingMaskIntoConstraints = false
            scrubber.widthAnchor.constraint(equalToConstant: 320).isActive = true
            modelScrubberView = scrubber
            item.view = scrubber
            return item
        default: return nil
        }
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int { store.snapshot.models.filter { !$0.hidden }.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = LabelScrubberItem(frame: .zero)
        let models = store.snapshot.models.filter { !$0.hidden }
        if models.indices.contains(index) { view.title = models[index].displayName }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        let models = store.snapshot.models.filter { !$0.hidden }
        guard models.indices.contains(index) else { return }
        onSelectModel?(models[index].model, store.snapshot.selection?.effort)
    }

    @objc private func nextEffort() {
        let snapshot = store.snapshot
        guard !store.configurationWriteBlocked,
              !snapshot.pendingWrite,
              let selection = snapshot.selection,
              let model = snapshot.models.first(where: { $0.model == selection.model }),
              !model.supportedReasoningEfforts.isEmpty else { return }
        let efforts = model.supportedReasoningEfforts.map(\.value)
        let currentIndex = efforts.firstIndex(of: selection.effort) ?? -1
        let nextIndex = (currentIndex + 1) % efforts.count
        onSelectModel?(model.model, efforts[nextIndex])
    }

    @objc private func nextAccount() { onNextAccount?() }

    private func modelPopover() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.modelScrubber]
        return bar
    }

    private func textItem(_ identifier: NSTouchBarItem.Identifier, text: String) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = label(text)
        return item
    }

    private func label(_ text: String, tooltip: String? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .center
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = tooltip
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return field
    }

    private func effortButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(nextEffort))
        button.toolTip = "Switch reasoning effort for future Codex sessions"
        button.isEnabled = !store.configurationWriteBlocked && !store.snapshot.pendingWrite && store.snapshot.selection != nil
        return button
    }

    private func statusField(_ snapshot: AppSnapshot) -> NSTextField {
        let state = snapshot.status()
        let presentation: (title: String, color: NSColor)
        switch state {
        case .ready: presentation = ("Ready", .systemGreen)
        case .working: presentation = ("Working", .systemBlue)
        case .stale: presentation = ("Stale", .systemYellow)
        case .attention:
            presentation = (snapshot.authentication == .requiresLogin ? "Login" : "Attention", .systemRed)
        case .offline: presentation = ("Offline", .systemRed)
        }
        let field = label(presentation.title, tooltip: snapshot.errorMessage ?? "Codex connection and data status")
        field.textColor = presentation.color
        return field
    }

    private func accountButton(_ snapshot: AppSnapshot) -> NSButton {
        let alias = String(snapshot.profile.alias.prefix(8))
        let button = NSButton(title: "↻ \(alias)", target: self, action: #selector(nextAccount))
        button.toolTip = "Switch the monitored account for future sessions"
        button.isEnabled = isAccountSwitchEnabled?() ?? false
        return button
    }

    private func todayText(_ usage: UsageSnapshot) -> String {
        guard usage.availability == .available else { return usage.availability == .unsupported ? "unsupported" : "--" }
        return usage.todayTokens.map { $0 >= 1_000 ? String(format: "%.1fk", Double($0) / 1_000) : "\($0)" } ?? "--"
    }

    private func quotaTooltip(_ kind: QuotaKind, snapshot: AppSnapshot) -> String {
        guard let window = snapshot.quota.lastKnown(kind) else { return "No server quota data" }
        let reset = window.resetsAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "unknown"
        return "Used \(window.usedPercent)% / resets \(reset) / fetched \(DateFormatter.localizedString(from: window.fetchedAt, dateStyle: .short, timeStyle: .short))"
    }

    private func usageTooltip(_ usage: UsageSnapshot) -> String {
        guard let date = usage.serviceDate else { return "Today's usage is unavailable" }
        let zone = usage.serviceTimeZoneIdentifier ?? "service date boundary unavailable"
        return "Server daily bucket \(date) / \(zone)"
    }
}

private final class LabelScrubberItem: NSScrubberItemView {
    private let field = NSTextField(labelWithString: "")
    var title: String = "" { didSet { field.stringValue = title } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.alignment = .center
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { return nil }
}
