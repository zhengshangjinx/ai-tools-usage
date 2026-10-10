import AppKit

/// 「关掉主窗口之后，App 该以什么形态继续活着」的唯一决策点。
///
/// 对标日历那个项目（`calendar-plus/Sources/App/Windows/ActivationPolicyController.swift`）：
/// 平时是纯状态栏程序、没有 Dock 图标；打开主窗口时 Dock 图标与菜单栏临时出现，关掉之后再收回去。
///
/// **为什么不加 `LSUIElement`**（这条要一直留着，别再「顺手补上」）：
/// 本 App 启动就开主窗口（出生即 `.regular`），「纯状态栏」这个状态**只有一个来源** ——
/// 关掉最后一个真窗口。加静态声明唯一能多买到的是「启动瞬间也是 `.accessory`」，那正是不要的状态；
/// 反而要在 `applicationDidFinishLaunching` 里补一次 `setActivationPolicy(.regular)` 把启动掰回来，
/// 还额外吃两个已知坑：`WindowGroup` 与菜单栏 App 的生命周期打架（社区报告集中在 `LSUIElement` 场景），
/// 以及 Apple 论坛 650270 / FB7743313 —— `setActivationPolicy(.regular)` 返回 true 但菜单栏仍显示
/// 上一个 App 的菜单，要 ⌘-Tab 走开再回来才亮。
///
/// **`setActivationPolicy` 绝不能写在 `App.init()` 里**：那一刻 `NSApp` 还是 nil，直接崩。
/// 本文件里所有碰 `NSApp` 的方法都只在运行期（窗口通知回调）被调用，`install` 阶段只注册观察者。
@MainActor
enum ActivationPolicyController {

    // MARK: - 判据（纯函数，为了能离屏自测）

    /// 判据的输入。抽成结构体是因为活的路径读的是 `NSApp.windows` ——
    /// 那是窗口服务器状态，离屏自测里造不出来。
    struct WindowSnapshot: Equatable {
        var isVisible = false
        var isMiniaturized = false
        var canBecomeMain = false
    }

    static func snapshot(of window: NSWindow) -> WindowSnapshot {
        WindowSnapshot(isVisible: window.isVisible,
                       isMiniaturized: window.isMiniaturized,
                       canBecomeMain: window.canBecomeMain)
    }

    static func snapshots(of windows: [NSWindow]) -> [WindowSnapshot] {
        windows.map(snapshot(of:))
    }

    /// 屏幕上还有没有「真窗口」。
    ///
    /// `canBecomeMain` 这个过滤条件是关键，不能省：`NSApp.windows` 里躺着菜单栏面板的窗口
    /// （`MenuBarExtra(.window)` 那个）、`_NSPopoverWindow`、`NSStatusBarWindow`、tooltip，
    /// 它们**全都** `isVisible == true`，但一个都不该让 App 变回 `.regular` ——
    /// 否则点一下菜单栏图标就把 Dock 图标招回来了。
    ///
    /// `isMiniaturized` 是本项目比日历多算的一条：主窗口缩到 Dock 之后 `isVisible` 会变成 false，
    /// 只判 `isVisible` 的话，这时再关掉设置窗口就会判成「没有真窗口」→ 退成纯状态栏 →
    /// **Dock 图标消失，而主窗口还挂在 Dock 里点不开**。
    static func hasRealWindow(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
    }

    /// 关掉一个窗口之后的处置。
    enum CloseOutcome: Equatable {
        /// 退出 App
        case terminate
        /// 按「还剩几个真窗口」重新判（关掉的不是主窗口时走这条）
        case refresh
        /// 留在 Dock 里不动
        case stayInDock
    }

    /// 关窗决策。抽成纯函数同样是为了自测 —— 活的路径读 `NSApp.windows`，离屏测不了。
    ///
    /// `keepRunning == false` 只在**主窗口**关闭时才等于退出：关个设置窗口把整个 App 带走，
    /// 是这类实现最容易出的事故，所以 `isMainWindow == false` 直接短路成 `refresh`。
    ///
    /// `hasMenuBarIcon == false && keepRunning == true` 这一格是**死路兜底**：菜单栏图标关掉了，
    /// 再退成纯状态栏，App 就变成「没有 Dock 图标、没有菜单栏、没有窗口」—— 三个入口全没了，
    /// 只能去活动监视器杀。用户的两个设置在这里冲突，取「别让 App 变成点不到的状态」这一侧。
    /// 界面上要如实说出来（设置里那行橙色提示），不能默默替他决定。
    static func closeOutcome(isMainWindow: Bool, keepRunning: Bool, hasMenuBarIcon: Bool) -> CloseOutcome {
        guard isMainWindow else { return .refresh }
        guard keepRunning else { return .terminate }
        return hasMenuBarIcon ? .refresh : .stayInDock
    }

    /// ⌘Q 的落点判据：这个窗口该不该被 ⌘Q 关掉。
    ///
    /// 判据就是「它是不是一个真窗口」，与 `hasRealWindow` 共用同一条定义（`canBecomeMain` 那一条）——
    /// 菜单栏面板、弹出层、tooltip 都不是，⌘Q 落在它们上面什么都不做。
    ///
    /// **返回值里刻意没有「退出 App」这一档**：⌘Q 把状态栏一起收掉，正是用户报上来的毛病。
    /// 关掉主窗口之后走哪条路（留在菜单栏还是退出）由 `closeOutcome` 说了算，
    /// 这里只负责选出「关哪个窗口」。退出整个 App 只剩两个入口：
    /// 菜单栏面板页脚那枚电源按钮、App 菜单里的「退出」（见 `QuitShortcut`）。
    static func closesOnQuitKey(_ window: WindowSnapshot) -> Bool {
        hasRealWindow([window])
    }

    // MARK: - 运行期

    /// 唯一的 `setActivationPolicy` 调用点。策略没变就不重复设 ——
    /// 反复设同一个值会白白惊动窗口服务器，也会让「谁改的」这件事查不清。
    private static func apply(_ policy: NSApplication.ActivationPolicy, reason: String) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// 按「屏幕上还有没有真窗口」重新决定形态。
    static func refresh() {
        let has = hasRealWindow(snapshots(of: NSApp.windows))
        apply(has ? .regular : .accessory, reason: "refresh")
    }

    /// **关窗路径一律走这个，不要直接调 `refresh()`。**
    ///
    /// 时序坑（日历文档 33 那条，别再踩第二次）：`windowWillClose` 是在窗口**撤下屏幕之前**发的，
    /// 实测那一刻 `isVisible` 仍然是 `true`。同步 `refresh()` 会判成「还有真窗口」，
    /// 把 App 永远留在 `.regular` —— Dock 图标赖着不走，「仅状态栏运行」随之失效。
    /// 而窗口关闭不会发第二次通知，所以这个错误状态没有任何机会被纠正。
    /// 一句话：判据型代码挂在这个通知上，读到的一定是过期状态。等一轮 runloop 再判。
    static func refreshAfterWindowCloses() {
        Task { @MainActor in refresh() }
    }

    /// **打开窗口之前**调。
    ///
    /// 不能走 `refresh()`：调用方是在窗口显示**之前**调过来的，那一刻还没有窗口，
    /// `refresh()` 会把 App 判成辅助型，等于白调。
    /// 顺序也不能换：`.accessory` 状态下 `makeKeyAndOrderFront` 拿不到键盘焦点，
    /// 必须先把策略掰成 `.regular` 再开窗，否则窗口开出来是死的 —— ⌘W / ⌘Q 全哑。
    static func activateForWindow() {
        apply(.regular, reason: "activateForWindow")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 兜底网用：真窗口已经自己冒出来了（成为 main），只把形态补回 `.regular`，**不抢焦点**。
    /// 与 `activateForWindow()` 的差别只在要不要 `NSApp.activate` —— 那种情况下激活本来就在发生。
    static func adoptExistingWindow() {
        apply(.regular, reason: "didBecomeMain")
    }
}
