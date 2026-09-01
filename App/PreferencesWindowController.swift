import AppKit
import CodexTouchCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let registry: ProfileRegistry
    private let preferences: AtomicPreferences
    private let store: DashboardStore
    private let touchBarController: TouchBarController
    private let profiles = NSPopUpButton()
    private let oneTouch = NSButton(checkboxWithTitle: "Enable one-touch account switching (A)", target: nil, action: nil)
    private let onSelectProfile: (UUID) -> Void
    private let onLogin: (UUID) -> Void
    private let onChooseCodex: () -> Void

    init(
        registry: ProfileRegistry,
        preferences: AtomicPreferences,
        store: DashboardStore,
        touchBarController: TouchBarController,
        onSelectProfile: @escaping (UUID) -> Void,
        onLogin: @escaping (UUID) -> Void,
        onChooseCodex: @escaping () -> Void
    ) {
        self.registry = registry
        self.preferences = preferences
        self.store = store
        self.touchBarController = touchBarController
        self.onSelectProfile = onSelectProfile
        self.onLogin = onLogin
        self.onChooseCodex = onChooseCodex
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Touch Bar Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        refresh()
        touchBarController.attach(to: window)
    }

    required init?(coder: NSCoder) { return nil }

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Accounts use isolated CODEX_HOME directories. Credentials are managed by Codex.")
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2

        profiles.target = self
        profiles.action = #selector(profileChanged(_:))
        oneTouch.target = self
        oneTouch.action = #selector(oneTouchChanged(_:))
        let add = NSButton(title: "Add account profile...", target: self, action: #selector(addProfile))
        let login = NSButton(title: "Start official Codex login...", target: self, action: #selector(startLogin))
        let chooseCodex = NSButton(title: "Choose Codex executable...", target: self, action: #selector(chooseCodex))
        let reveal = NSTextField(labelWithString: "No credential file is read, copied, or displayed by this app.")
        reveal.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, profiles, oneTouch, add, login, chooseCodex, reveal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])
    }

    func refresh() {
        profiles.removeAllItems()
        guard let values = try? registry.allProfiles() else { return }
        for profile in values {
            profiles.addItem(withTitle: profile.alias)
            profiles.lastItem?.representedObject = profile.id
            if profile.id == store.snapshot.profile.id { profiles.select(profiles.lastItem) }
        }
        oneTouch.state = (try? preferences.read().oneTouchEnabled) == true ? .on : .off
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? UUID else { return }
        onSelectProfile(id)
    }

    @objc private func oneTouchChanged(_ sender: NSButton) {
        guard var value = try? preferences.read() else { return }
        value.oneTouchEnabled = sender.state == .on
        guard (try? preferences.write(value)) != nil else {
            sender.state = value.oneTouchEnabled ? .off : .on
            return
        }
        touchBarController.reload()
    }

    @objc private func startLogin() {
        guard let id = profiles.selectedItem?.representedObject as? UUID else { return }
        onLogin(id)
    }
    @objc private func chooseCodex() { onChooseCodex() }

    @objc private func addProfile() {
        let alert = NSAlert()
        alert.messageText = "Add account profile"
        alert.informativeText = "Choose a local nickname. Codex will own authentication inside the new isolated home."
        let field = NSTextField(string: "")
        field.placeholderString = "Work"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let profile = try? registry.register(alias: field.stringValue), !profile.alias.isEmpty else { return }
        guard var value = try? preferences.read() else { return }
        value.orderedProfileIDs.append(profile.id)
        _ = try? preferences.write(value)
        refresh()
    }
}
