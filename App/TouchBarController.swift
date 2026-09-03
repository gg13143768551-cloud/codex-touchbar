import AppKit
import CodexTouchCore
import ObjectiveC

@MainActor
final class TouchBarController {
    private let provider: TouchBarProvider
    private var globalTouchBar: NSTouchBar?

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

    /// Presents the bar through AppKit's private system-modal Touch Bar SPI.
    /// This is what allows a menu-bar agent to keep a bar visible while another
    /// application, such as Codex, is frontmost.
    @discardableResult
    func presentGlobally() -> Bool {
        let bar = globalTouchBar ?? provider.makeTouchBar()
        globalTouchBar = bar
        let selector = Selector("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else {
            return false
        }

        typealias Present = @convention(c) (AnyObject, Selector, AnyObject, Int64, AnyObject?) -> Void
        let implementation = method_getImplementation(method)
        let present = unsafeBitCast(implementation, to: Present.self)
        present(NSTouchBar.self as AnyObject, selector, bar, 0, nil)
        return true
    }

    func dismissGlobally() {
        guard let bar = globalTouchBar else { return }
        let selector = Selector("dismissSystemModalTouchBar:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else { return }
        typealias Dismiss = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let implementation = method_getImplementation(method)
        let dismiss = unsafeBitCast(implementation, to: Dismiss.self)
        dismiss(NSTouchBar.self as AnyObject, selector, bar)
        globalTouchBar = nil
    }
}
