import SwiftUI
import AppKit

/// 主窗口尺寸的**显式**记忆。
///
/// SwiftUI 自带的窗口尺寸记忆在这个 app 上不工作。实测（装好的 Release 版，拖到 1484×913 后退出）：
/// `NSWindow Frame SwiftUI.ModifiedContent<…>-1-AppWindow-1` 这条记录**确实写了**，值是 `1485 914`；
/// 重新打开却是 1000×668，并且那条记录当场被改写成 1000×668 —— 尺寸不但没恢复，还被就地覆盖。
/// 只有完全没有历史记录时才轮得到 `.defaultSize` 生效。
/// 所以「恢复」这一步必须自己做：AppKit 读得比 SwiftUI 定尺寸早，读完就被盖掉了。
///
/// 那个自存名本身也是隐患：键里嵌着整条视图类型链（357 个字符），
/// `ContentView` 上挂的修饰符一变键就换，用户调好的尺寸随之丢失 —— 而这个 app 每次迭代都在动那层。
/// 证据就在本次改动里：光是加挂这个 `WindowFrameKeeper`，键里就多出了一段
/// `_BackgroundModifier<…WindowFrameKeeper…>`，旧键直接作废。
/// 这里换成固定名，并顺手把旧键下的尺寸过继过来。
///
/// 「读」和「写」都由这里自己来：
/// - 读不能靠 `NSWindow` 自己恢复 —— 它读得比 SwiftUI 定尺寸早，读完就被盖掉；
/// - 写不能靠 `setFrameAutosaveName` —— SwiftUI 稍后会把自存名换回它自己那个，见 `KeeperView.observe`。
struct WindowFrameKeeper: NSViewRepresentable {
    /// **改这个键名等于清空所有用户的尺寸记忆。**
    static let autosaveName = "AIUsage.MainWindow"
    /// AppKit 自存窗口尺寸用的就是这个名字的键，格式 `x y w h 屏幕x 屏幕y 屏幕宽 屏幕高`
    static var defaultsKey: String { "NSWindow Frame \(autosaveName)" }
    private static let legacyPrefix = "NSWindow Frame SwiftUI."
    /// 但 Settings 窗口那条要放过：名字也落在上面这个前缀里（形如
    /// `NSWindow Frame com_apple_SwiftUI_Settings_window…`），清掉它只会让设置窗口下次开在别处，
    /// 跟我们这个窗口的尺寸记忆毫无关系。
    private static let legacySkip = "Settings"

    /// 首次启动的窗口尺寸（屏幕可见区 1920×1055，四周留有余量）。定这一档的依据：
    /// 四张 KPI 卡在这个宽度下副标题不截断 —— 最长的一档是「未计价 100.0% · 175.4B tokens」；
    /// 环境那行七枚 chips 排得下不折行；高度够完整露出「每日趋势 / 环境分布」两张图。
    ///
    /// 档位沿革：1240×840 → 1400×900 → **1520×950**。前两档都能看全，问题是明细表只露出三四行，
    /// 得往下滚才看得出「哪些行在头部」—— 而这张表按费用降序排，「谁最贵」正是它要回答的。
    /// 1520×950 下表格能多露两行，两张图也不再有压扁感；再大就要在 1920 宽的屏上顶到边了。
    static let designSize = CGSize(width: 1520, height: 950)
    /// 最小宽度的第一条线是筛选区第一行。实测那一行：日期胶囊 304 + 档位条 565
    /// + 三个 34pt 图标按钮 102（刷新 / 导出 / 设置），再加两段 10pt 间距与至少 16pt 的空档 = 1017，
    /// 最后加上 `DashboardBody` 左右各 24pt 的留白，共 1065。
    /// （这一行原先还有个 132pt 的指标切换，搬到两张图里之后就不再算它了；
    /// 后来加了导出按钮，从 1021 涨到 1065，仍远在 1180 之下，所以下限没动。）
    ///
    /// **第二条线（现在卡住下限的是它）是明细表第一列的模型名。** 从窗口宽度倒着扣，
    /// 留给名字的宽度是 `W - 976`：
    /// 定宽列 784（环境 300 + Tokens 92 + 请求数 68 + 费用 110 + 占比 158 + 详情 56）
    /// + 六段 8pt 间距 48 + 表头/行的左右内边距 16
    /// + 卡片内边距 40 + `DashboardBody` 48 + 序号码左边那截 40（12 内缩 + 20 徽标 + 8 间距）。
    ///
    /// 名字宽度是**量出来的**，不是估的（12.5pt 等宽体，AppKit `size(withAttributes:)`）：
    /// `claude-opus-4-6-thinking` 185.45、`claude-sonnet-5（日常使用）` 180.75
    /// （两个全角括号按双倍宽算，所以 21 个字符占得比 23 个还多），
    /// `claude-fable-5-1-medium` 177.72。要连 Anthropic 那种带日期后缀的 id
    /// （`claude-sonnet-4-5-20250929`，实测 200.90）一起容下，`W - 976 ≥ 201` → W ≥ 1177，取 1180。
    ///
    /// 这条线也是量出来的：1130 那一版只留 154pt，`claude-fable-5-1-medium` 被截成
    /// `claude-fa…1-medium`，跟 `claude-5-…le-medium` 几乎分不出来 —— 等宽体做标识符比对，
    /// 中间省略号正好吃掉最能区分的型号中段。1180 留 204pt，上面几个名字全部完整。
    /// **再往表里加定宽列、或者加宽环境/占比这两列，都得把这段账重算一遍。**
    ///
    /// 注意这个值同时是**窗口尺寸记忆的准入门槛**（`storedFrame()` 里低于它就当没有记录）：
    /// 调高之后，之前把窗口拖得比它窄的人下次启动会回到默认尺寸。
    static let minSize = CGSize(width: 1180, height: 640)

    func makeNSView(context: Context) -> NSView {
        let view = KeeperView(frame: .zero)
        view.setAccessibilityHidden(true)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension WindowFrameKeeper {
    /// 一个窗口只做一次：挂上窗口时把尺寸摆到位，之后自己订阅通知写盘
    final class KeeperView: NSView {
        private var applied = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !applied else { return }
            applied = true

            // **「再次打开主窗口时宽度闪跳」就是在这里治的。**
            // 窗口是 SwiftUI 建的：它先按自己的尺寸（`.defaultSize`，或者它那条自存记录）把窗口
            // 摆出来、推上屏幕，我们才有机会在 `viewDidMoveToWindow` 里改成用户的尺寸 ——
            // 于是用户看到「先一个宽度、再跳成另一个」。快的时候几毫秒内就落定、察觉不到，
            // 主线程忙的时候（比如重开时刚好在扫日志）能拖出好几帧，所以它时有时无 ——
            // 这正是「闪跳」的脾气，也是它不好复现的原因。
            //
            // 对策：**在尺寸核稳之前不让这个窗口出现在屏幕上**。用 `alphaValue` 而不是 `orderOut`：
            // 前者不影响铺排、不会让窗口从屏幕上撤下来再上去，恢复时也没有重新上屏那一下。
            // 只在窗口还没上屏时这么做 —— 已经上屏的再藏一下，那就是真的闪了。
            //
            // 什么时候才需要藏，两条例外都要放行，否则会为了治闪跳造出一个更明显的闪：
            // ① 窗口**已经上屏、而且尺寸本来就对**（SwiftUI 自己恢复对了的那种）——
            //    没有任何要改的东西，藏一下纯属白闪；
            // ② 只差位置（换屏之后被 `clampToScreen` 挪一下）不藏：那是「挪」不是「跳」。
            let before = window.frame
            let wasVisible = window.isVisible
            let desired = WindowFrameKeeper.apply(to: window)
            let hidden = !wasVisible || WindowFrameKeeper.differs(before, desired)
            let originalAlpha = window.alphaValue
            if hidden { window.alphaValue = 0 }
            settle(window, desired: desired, turnsLeft: 8) { [weak self, weak window] in
                guard let window else { return }
                if hidden { window.alphaValue = originalAlpha }
                WindowFrameKeeper.clampToScreen(window)
                // 存盘挂在这之后 —— 否则启动/重开时这一来一回会被当成用户的拖动记下来，
                // 等于把错误的尺寸写进记忆（这条是原来就有的账，别挪到前面去）。
                WindowFrameKeeper.store(window)
                self?.observe(window)
            }
            // 兜底：`settle` 万一没跑到 `done`（窗口在中途被拆掉之类），
            // 窗口不能永远停在全透明上 —— 那比闪一下严重得多，用户会以为「打开主窗口没反应」。
            if hidden {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak window] in
                    guard let window, window.alphaValue == 0 else { return }
                    window.alphaValue = originalAlpha
                }
            }
        }

        /// 反复核对尺寸，直到**连续两轮**都对得上为止（最多 `turnsLeft` 轮）。
        ///
        /// 为什么不是「核一轮、对上就走」：SwiftUI 那次回改跟在我们 `setFrame` 的**后面**，
        /// 只核一轮正好卡在它前面，等于没核 —— 原注释里「刚设成 1240×840，紧接着被改回去」
        /// 记的就是这个。连续两轮对上，才说明它这一轮没再动手。
        private func settle(_ window: NSWindow, desired: NSRect, turnsLeft: Int,
                            matched: Int = 0, done: @escaping () -> Void) {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let window else { return }
                let ok = !WindowFrameKeeper.differs(window.frame, desired)
                if !ok { window.setFrame(desired, display: true) }
                let streak = ok ? matched + 1 : 0
                guard streak < 2, turnsLeft > 1 else { done(); return }
                self?.settle(window, desired: desired, turnsLeft: turnsLeft - 1,
                             matched: streak, done: done)
            }
        }

        /// 拖动结束后写盘。三个通知各管一段：
        /// `didEndLiveResize` 是用户拖完那一下（`inLiveResize` 已经落回 false），
        /// `didMove` / `didResize` 管程序改尺寸和移动窗口这两种不经过拖动会话的情况 ——
        /// 拖动中的那些帧由 `inLiveResize` 挡掉，没必要每帧写一次盘。
        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            func save(_ notification: Notification) {
                guard !window.inLiveResize else { return }
                WindowFrameKeeper.store(window)
            }
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main, using: save))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension WindowFrameKeeper {
    /// 把窗口摆到该在的位置，返回它应该停在哪（调用方还要在下一轮拿这个值核对一次）
    @discardableResult
    private static func apply(to window: NSWindow) -> NSRect {
        if let saved = storedFrame() {
            window.setFrame(saved, display: true)
        } else {
            // 先定尺寸，再居中。这两步不能省掉后一步：`setContentSize` **只改尺寸，原点原地不动**，
            // 于是窗口从系统给的初始位置往右上长出去，再被 `clampToScreen` 一夹，就贴死在屏幕角上
            // （实测 1520×950 会停在可见区右上角 400,105）。
            window.setContentSize(designSize)
            centerOnScreen(window)
        }
        clampToScreen(window)
        return window.frame
    }

    /// 首次启动时居中。按**可见区**算，不是整块屏幕 ——
    /// 用整块屏幕的话窗口顶部会顶到菜单栏底下，垂直方向看着偏下。
    private static func centerOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.minX + (visible.width - size.width) / 2,
                                      y: visible.minY + (visible.height - size.height) / 2))
    }

    /// 两个窗口框算不算「不一样」。留 0.5pt 的余量：尺寸是从存盘字符串解析出来的整数，
    /// 而 AppKit 回读时可能带上半点几的小数，拿 `==` 比会把这种无关紧要的差当成要改的差。
    fileprivate static func differs(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
            || abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
    }

    private static func storedFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let rect = frame(fromStored: raw),
              rect.width >= minSize.width, rect.height >= minSize.height else { return nil }
        return rect
    }

    /// 启动时调用（在窗口建出来之前）。SwiftUI 会在创建窗口时抢先按它自己那个键恢复尺寸 ——
    /// 那个值要么是过期的，要么因为键名跟着视图类型链变了而根本不是用户调的那个；
    /// 实测它恢复完之后还会在本该由我们定尺寸的时刻再动一次窗口。所以启动第一步就把它清掉，
    /// 让窗口尺寸只有 `KeeperView` 一个来源。
    static func prepareAtLaunch() {
        migrateLegacyFrame()
    }

    /// 旧键下的尺寸搬一次到新键上，用户之前调好的尺寸不至于因为这次改名丢掉。
    /// 只搬站得住的（历史上真出现过 `1000 470` 这种低于最小高度的记录，继承它等于把毛病留着），
    /// 搬完旧键一律清掉 —— 它已经没有任何用途了。
    private static func migrateLegacyFrame() {
        let defaults = UserDefaults.standard
        let legacy = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(legacyPrefix) && !$0.contains(legacySkip) }
        for key in legacy {
            if defaults.string(forKey: defaultsKey) == nil,
               let raw = defaults.string(forKey: key),
               let rect = frame(fromStored: raw),
               rect.width >= minSize.width, rect.height >= minSize.height {
                // 两边都是 AppKit 自存的格式，原样搬过去即可
                defaults.set(raw, forKey: defaultsKey)
            }
            defaults.removeObject(forKey: key)
        }
    }

    private static func frame(fromStored raw: String) -> NSRect? {
        let parts = raw.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// 存盘时那块屏幕可能已经不在了（拔了外接屏、改了分辨率）——
    /// 至少保证整个窗口落在可见区里，否则用户拖不回来。
    /// 自己写盘，不用 `saveFrame(usingName:)` —— 实测它在没有 `setFrameAutosaveName` 的时候
    /// 一声不响地什么都不写（键根本不出现在 defaults 里），而 `setFrameAutosaveName` 又会被 SwiftUI 抢走。
    /// 只存前四个数（原点 + 尺寸）；屏幕那部分不存，落到别的显示器上由 `clampToScreen` 兜。
    private static func store(_ window: NSWindow) {
        let f = window.frame
        UserDefaults.standard.set(String(format: "%.0f %.0f %.0f %.0f", f.origin.x, f.origin.y, f.width, f.height),
                                  forKey: defaultsKey)
    }

    fileprivate static func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
}

extension View {
    /// 让这个窗口记住用户拖出来的尺寸。挂在窗口内容根视图上。
    func keepWindowFrame() -> some View {
        background(WindowFrameKeeper().frame(width: 0, height: 0))
    }
}
