import AppKit
import CodexTouchCore

@MainActor
final class TouchBarController {
    private let provider: TouchBarProvider

    init(store: DashboardStore) { provider = TouchBarProvider(store: store) }

    var onNextAccount: (() -> Void)? {
        get { provider.onNextAccount }
        set { provider.onNextAccount = newValue }
    }

    var onSelectModel: ((String, String?) -> Void)? {
        get { provider.onSelectModel }
        set { provider.onSelectModel = newValue }
    }

    var isAccountSwitchEnabled: (() -> Bool)? {
        get { provider.isAccountSwitchEnabled }
        set { provider.isAccountSwitchEnabled = newValue }
    }

    func attach(to window: NSWindow) { window.touchBar = provider.makeTouchBar() }
    func reload() { provider.reload() }
}
