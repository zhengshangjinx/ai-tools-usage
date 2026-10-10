import AppKit

/// ⌘Q 从「退出 App」改成「关掉当前窗口」。
///
/// 改之前用的是系统默认：不管当时开着什么，一下 ⌘Q 连菜单栏图标一起收掉。对常驻状态栏的工具
/// 来说这是最难受的一种误触 —— 用户只是想把窗口收起来，结果提醒也一起没了。现在的规矩
/// （与 calendar-plus 一致）：
///
/// - **⌘Q = 关掉当前窗口。** 关的是主窗口时，接下来走哪条路由 `AppBehaviorSettings` 说了算：
///   默认「关闭主窗口后保留在菜单栏」→ App 退成纯状态栏，图标还在；关掉那个开关 → 才真的退出
///   （那是用户自己明说过的期望，不在这里替他改）。
/// - **退出整个 App 只剩两个入口**：菜单栏面板页脚那枚电源按钮，和 App 菜单里的「退出」。
///
/// **为什么除了换菜单项，还要在按键这一层再拦一道**：菜单是 SwiftUI 按 scene 生成的，里面那一项
/// 由不得我们。换掉它只保证**当前这一版**生成的菜单里 ⌘Q 挂在「关闭窗口」上 —— 这一点用临时探针
/// 在「主窗口为 key / 只剩设置窗口 / 已退成纯状态栏」三种窗口状态下都核过，三项一致；
/// 但哪天系统升级把默认的「退出 ⌘Q」加回来，菜单就又开始撒谎了。监视器在**按键分发之前**拦下 ⌘Q，
/// 与当时有没有菜单、菜单里写了什么无关。两道一起上：菜单负责把话说清楚，监视器负责保证落点。
@MainActor
enum QuitShortcut {

    /// 留着引用只为 `install` 幂等：重复调用时先把旧的那个拆掉。
    private static var monitor: Any?

    /// 装上拦截。重复调用是安全的（先拆旧的再装）。
    ///
    /// 从 `AppDelegate.applicationDidFinishLaunching` 调，而不是跟 `WindowLifecycle.install` 一样
    /// 放在 `App.init()`：这一条不碰 `NSApp`（那边的时间约束在这儿不成立），
    /// 但事件监视器是要跟着事件循环走的，等 App 起完再装最稳。
    static func install() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isQuitKey(event) else { return event }
            // 监视器的回调在主线程；`assumeIsolated` 是把这件已知的事告诉编译器，
            // 不是绕过检查（同 `WindowLifecycle.install` 里那两处）。
            MainActor.assumeIsolated { closeFrontWindow() }
            // 返回 nil = 这次按键到此为止，不再往菜单/响应链上传。**必须吞掉**：
            // 只要有一个带 ⌘Q 的菜单项漏在菜单里（比如只剩设置窗口那一档），
            // 放行就等于绕过这里直接退出 App —— 那正是这次要修掉的毛病。
            return nil
        }
    }

    /// ⌘Q 的按键形状：**只认「⌘ + Q」本身**。
    ///
    /// 修饰键与 `quitModifiers` **精确比较**：所以 ⌘⇧Q、⌘⌥Q 一律放行，
    /// 它们不是「退出」的写法，不该被吞掉。
    /// 认 `charactersIgnoringModifiers` 而不是 `keyCode`：后者绑在物理键位上，
    /// 换个键盘布局（Dvorak 之类）就会认错键。
    ///
    /// internal 而不是 private：`--selftest` 第 8 组用真 `NSEvent` 钉这个形状
    /// （只动可见性，没动逻辑，同两个 provider 的 `scanFile`）。
    nonisolated static func isQuitKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(quitModifiers)
        return flags == .command && event.charactersIgnoringModifiers?.lowercased() == quitKey
    }

    /// 判定时要看的修饰键。
    ///
    /// **刻意不是 `deviceIndependentFlagsMask`**：那里面还含着 caps lock / 数字键盘 / fn，
    /// 而那几个键亮着并不代表用户按的是别的组合 —— 一起比的话，大写锁定开着时 ⌘Q 就漏过去了，
    /// 那一按会绕过这里直接落到菜单上（菜单里那一项恰好也是关窗口，所以症状只是「时灵时不灵」，
    /// 最难查的那一类）。
    nonisolated private static let quitModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// ⌘Q 的字符
    nonisolated private static let quitKey = "q"

    /// 关掉最前面那个真窗口。
    ///
    /// 判据交给 `ActivationPolicyController.closesOnQuitKey`：「真窗口」在这个 App 里只有一个定义，
    /// 菜单栏面板与弹出层都不算，⌘Q 落在它们上面时什么都不做。
    /// 没有 key 窗口时（窗口都关了、App 还在状态栏活着）同样什么都不做 ——
    /// **这里绝不补 `NSApp.terminate`**，那正是这次要改掉的毛病。
    static func closeFrontWindow() {
        guard let window = NSApp.keyWindow,
              ActivationPolicyController.closesOnQuitKey(ActivationPolicyController.snapshot(of: window))
        else { return }
        // 用 `performClose` 而不是 `close()`：前者会发 `windowWillClose`，
        // 而「关掉主窗口后留在菜单栏还是退出」整条决策链就挂在那个通知上（见 `WindowLifecycle`）。
        // `close()` 会静默跳过它，症状是关掉主窗口后 Dock 图标赖着不走。
        window.performClose(nil)
    }
}
