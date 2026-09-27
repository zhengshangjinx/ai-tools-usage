import AppKit
import SwiftUI

/// 窗口生命周期：关掉最后一个真窗口之后把 App 撤成纯状态栏（Dock 图标与菜单栏一起收掉），
/// 再有真窗口出现时临时变回 `.regular`。决策本身在 `ActivationPolicyController`，这里只负责**发现**。
///
/// **为什么不接管 `NSWindow.delegate`**：窗口是 SwiftUI 建的，delegate 已经被它自己占着，
/// 抢过来等于把它的窗口管理拆掉（症状是窗口尺寸记忆、状态恢复一起坏，且坏得很难查）。
/// 所以这里挂全局通知观察者，用 `object: nil` 收所有窗口的事件 —— 判据本来就是全局的
/// （「整个 App 还有没有别的窗口」），本来也不该按窗口分别记账。
///
/// **`install` 里一个 `NSApp` 都不碰**：它在 `AIUsageApp.init()` 里被调用，那一刻 App 还没起完、
/// `NSApp` 还是 nil。所有碰 `NSApp` 的动作都留在通知回调里，那些回调只可能在窗口存在之后才发。
@MainActor
enum WindowLifecycle {

    /// 主窗口的弱引用。关掉它要走「退出还是退成状态栏」那条决策，别的窗口不走。
    ///
    /// 配对用 `===`，**不看 `identifier` / `title` / `frameAutosaveName`** —— 那三样都由 SwiftUI 管着，
    /// `frameAutosaveName` 已经有过一次被 SwiftUI 抢走的实测记录（见 `WindowFrameKeeper` 开头那段账），
    /// 拿它当身份认，迟早会把「关主窗口」认成「关别的窗口」。
    private static weak var mainWindow: NSWindow?

    /// 两个设置项的引用。放静态量而不是让观察者闭包捕获，理由见 `install` 里那段。
    private static var behavior: AppBehaviorSettings?
    private static var menuBar: MenuBarSettings?

    /// 「打开主窗口」的桥。`AppDelegate` 拿不到 SwiftUI 的 `openWindow` 环境动作，
    /// 只能由视图在自己 `onAppear` 里把这个闭包交出来。
    ///
    /// 注册点挂两处（`MenuBarLabel` 与 `ContentView`）是**故意**的：一个只在菜单栏图标开着时才有，
    /// 一个只在主窗口出现过之后才有，只挂一处就会留下「点不动」的死路。重复赋值是幂等的，零成本。
    static var openMainWindow: (() -> Void)?

    static func register(_ window: NSWindow) { mainWindow = window }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let main = mainWindow else { return false }
        return main === window
    }

    static func install(behavior: AppBehaviorSettings, menuBar: MenuBarSettings) {
        self.behavior = behavior
        self.menuBar = menuBar

        // 闭包**什么都不捕获**，状态全走上面的静态量。这不是洁癖：
        // `addObserver` 收的是 `@Sendable` 闭包，直接捕获 `AppBehaviorSettings` 会得到
        // 「capturing non-Sendable … in a `@Sendable` closure」，把 `@MainActor` 的方法当函数值传进去
        // 还会多一条「loses global actor 'MainActor'（Swift 6 里是错误）」。
        // `queue: .main` 已经保证回调在主线程，`assumeIsolated` 是把这件已知的事告诉编译器，
        // 不是绕过检查 —— 回调里做的事（读设置、改激活策略）本来就只能在主线程做。
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handleWillClose(note) }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handleDidBecomeMain(note) }
        }
    }

    /// 关窗这一条**不从通知里直接读判据**，只读「关的是不是主窗口」和两个设置项，
    /// 真正的形态判定交给 `refreshAfterWindowCloses()` 延后一轮去做 ——
    /// 原因见那个方法的注释（`willClose` 发出时窗口还没撤下屏幕）。
    private static func handleWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              let behavior, let menuBar else { return }
        switch ActivationPolicyController.closeOutcome(
            isMainWindow: isMainWindow(window),
            keepRunning: behavior.keepRunningAfterMainWindowClose,
            hasMenuBarIcon: menuBar.config.showInMenuBar) {
        case .terminate:
            NSApp.terminate(nil)
        case .refresh:
            ActivationPolicyController.refreshAfterWindowCloses()
        case .stayInDock:
            break
        }
    }

    /// 兜底网：**任何**窗口成为 main 时，如果 App 现在是辅助型，说明有一条我们没接的开窗路径
    /// （从「应用程序」里再点一次、`open -a`、脚本、SwiftUI 自己的 reopen）已经把真窗口弄出来了 ——
    /// 那就把 Dock 图标还回去，否则这个窗口没有菜单栏、⌘W / ⌘Q 全是哑的。
    ///
    /// 挂在 `didBecomeMain` 而**不是** `didBecomeKey`，也**不重读 `canBecomeMain`**：
    /// 「刚刚成为 main」这件事本身就蕴含了「它有资格成为 main」，所以菜单栏面板
    /// （`MenuBarExtra(.window)` 那个窗口）永远触发不到这里。这条排除正是本功能最怕漏的 ——
    /// 一旦面板能触发，用户点一下菜单栏图标 Dock 图标就会冒出来，等于这个修复白做。
    ///
    /// 这里**不调 `NSApp.activate`**：窗口正在成为 main，激活本来就在发生，再抢一次焦点是多余的，
    /// 而且会从别的 App 手里把焦点夺过来。
    private static func handleDidBecomeMain(_ note: Notification) {
        guard NSApp.activationPolicy() == .accessory else { return }
        ActivationPolicyController.adoptExistingWindow()
    }
}

/// 0×0 的标记视图：挂上窗口那一刻把窗口登记成「主窗口」。
///
/// **为什么不并进 `WindowFrameKeeper.KeeperView`**（那里已经有一个 `viewDidMoveToWindow`）：
/// ① 那个文件整篇在论证**尺寸记忆**，往里塞「关窗该不该退 App」会让 `terminate` 出现在一个讲尺寸的文件里；
/// ② 关窗通知与视图销毁的先后顺序本身要单独论证，挂在会随窗口销毁而销毁的视图上太脆。
/// 两个 0×0 的 `NSView` 的成本可以忽略，换来的是两条线各自能读懂。
private struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = MarkerView(frame: .zero)
        view.setAccessibilityHidden(true)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 窗口销毁时会以 `nil` 再调一次，这里**不清登记** —— 弱引用自己会归零，
        // 而那次 `nil` 往往发生在真正的 `willClose` 之前，清了就会把关窗认成「关的不是主窗口」。
        guard let window else { return }
        WindowLifecycle.register(window)
    }
}

/// 交出「打开主窗口」的能力。挂在**常驻**的视图上（见 `WindowLifecycle.openMainWindow`）。
private struct OpenMainWindowBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { WindowLifecycle.openMainWindow = { openWindow(id: "main") } }
    }
}

extension View {
    /// 把窗口登记成主窗口。与 `.keepWindowFrame()` 并列挂在 `WindowGroup` 的内容上。
    func markAsMainWindow() -> some View {
        background(MainWindowMarker().frame(width: 0, height: 0))
    }

    func bridgeOpenMainWindow() -> some View {
        modifier(OpenMainWindowBridge())
    }
}
