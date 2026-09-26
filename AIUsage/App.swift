import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var pricing = PricingService()
    @StateObject private var store: UsageStore
    /// 菜单栏配置。`MenuBarExtra` 是独立 scene，拿不到 `WindowGroup` 的环境对象，
    /// 所以它由这里持有、显式传进面板与标签。
    @StateObject private var menuBar: MenuBarSettings
    /// 关窗行为（「关掉主窗口后留在菜单栏」）。语义上是 App 生命周期，与菜单栏显示配置无关，
    /// 所以单独一个对象，没有并进 `MenuBarSettings`（理由见 `AppBehaviorSettings` 开头）。
    @StateObject private var behavior: AppBehaviorSettings

    init() {
        // 先于任何窗口创建：清掉 SwiftUI 自带的窗口尺寸记录，让尺寸只由 WindowFrameKeeper 说了算
        WindowFrameKeeper.prepareAtLaunch()
        let pricing = PricingService()
        _pricing = StateObject(wrappedValue: pricing)
        _store = StateObject(wrappedValue: UsageStore(pricing: pricing))
        // 这两个**在 init 里显式建出来**再交给 StateObject，不写成 `= MenuBarSettings()`：
        // `StateObject(wrappedValue:)` 收的是 autoclosure，声明式写法要等 SwiftUI 第一次装它才求值，
        // 而下面 `WindowLifecycle.install` 现在就要用同一个实例 —— 那样会建出两个，
        // 观察者拿到的是一份没人再动的配置，用户在设置里改了开关它永远不知道。
        let menuBar = MenuBarSettings()
        _menuBar = StateObject(wrappedValue: menuBar)
        let behavior = AppBehaviorSettings()
        _behavior = StateObject(wrappedValue: behavior)
        // 只注册观察者，一个 NSApp 都不碰 —— 这一刻 App 还没起完，NSApp 是 nil。见 WindowLifecycle 开头
        WindowLifecycle.install(behavior: behavior, menuBar: menuBar)
        // 三个「跑完就打印一行行文本再退出」的出口。都走同一条路：**换扫描 → 现算 → 打印 → exit**，
        // 这样它们跟界面看到的是同一份数据；`--dump` 的输出是回归基线，一个字都不能动。
        let dumpMode: String? = {
            let a = CommandLine.arguments
            if a.contains("--dump") { return "dump" }
            if a.contains("--menu") { return "menu" }
            if a.contains("--retention") { return "retention" }
            return nil
        }()
        if let dumpMode {
            let store = UsageStore(pricing: pricing)
            Task { @MainActor in
                await pricing.loadCachedThenRefresh()
                await store.refresh()
                if let days = CommandLine.arguments.compactMap({ Int($0) }).first,
                   let q = QuickRange.matching(days: days) { store.apply(q) }
                switch dumpMode {
                case "menu":
                    print(store.debugMenuDump())
                    // 菜单栏上**真正显示的那行字**（由用户配置决定）。数字对得上不等于那行字对 ——
                    // 「今日 $ $16.86」这种拼写毛病只有把拼好的串打出来才看得见：
                    // 菜单栏既不在 `--render` 的出图范围里，也不该为了核一句话去截用户的整条菜单栏。
                    print("label: \(MenuBarSettings().config.labelText(store.menuBarSummary))")
                case "retention":
                    // 档案读取要走 DeviceSync，所以这一句留在工装里；UsageStore 不必认识留存那套类型
                    let report = RetentionReport.make(records: store.records,
                                                      deviceFiles: store.deviceSync.readAll().files)
                    print(report.debugDump())
                default: print(store.debugDump())
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        // id 是给菜单面板的 `openWindow(id: "main")` 用的 —— 没有它，点「打开主窗口」不会有反应。
        // 窗口尺寸记忆不受影响：`WindowFrameKeeper` 用的是自己那个固定名（`NSWindow Frame AIUsage.MainWindow`），
        // 不是 SwiftUI 按视图类型链生成的自存名（见那个文件开头那段账）。
        WindowGroup("AI 用量统计", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(pricing)
                .frame(minWidth: WindowFrameKeeper.minSize.width, minHeight: WindowFrameKeeper.minSize.height)
                // 尺寸记忆：`.defaultSize` 只管「从没存过尺寸」的那一次，
                // 恢复与保存由它负责（SwiftUI 自带的那套在这个 app 上恢复不回来，见 WindowFrameKeeper）
                .keepWindowFrame()
                // 登记主窗口：关掉它时才分得清「关的是主窗口」还是「关的是设置窗口」
                .markAsMainWindow()
                .bridgeOpenMainWindow()
                .task {
                    await pricing.loadCachedThenRefresh()
                    await store.refresh()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: WindowFrameKeeper.designSize.width, height: WindowFrameKeeper.designSize.height)

        // 常驻菜单栏。`isInserted` 直接绑配置里的开关：关掉只是不显示，
        // 主窗口与 Dock 图标照旧（**不加 `LSUIElement`** —— 那会把 Dock 图标一起去掉，是另一个功能）。
        MenuBarExtra(isInserted: $menuBar.config.showInMenuBar) {
            MenuBarPanel(store: store, settings: menuBar)
                .environmentObject(store)
                .environmentObject(pricing)
        } label: {
            // 标签单独抽成一个视图：它要跟着 `menuBarSummary` 刷新，
            // 直接在 scene 那一层读 store 是不保证重画的
            MenuBarLabel(store: store, settings: menuBar)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(pricing)
                .environmentObject(menuBar)
        }
    }
}

/// 菜单栏上那段文字。空配置就只剩图标。
private struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: MenuBarSettings

    var body: some View {
        Text(settings.config.labelText(store.menuBarSummary))
    }
}

/// 离屏渲染的启动挂点：`--render` 不能挂在 SwiftUI 的 `.task` 上 ——
/// 屏幕锁定时窗口不会出现，`.task` 也就永远不触发，而 applicationDidFinishLaunching 照常。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 自测放在最前面、**同步**跑完就 exit：这时 SwiftUI 还没建窗口，
        // 跑一遍断言不会在屏幕上闪出主窗口。它不联网、不碰扫描缓存，见 SelfTest 顶部那段红线。
        if SelfTest.isRequested { SelfTest.runAndExit() }
        let dir = RenderHarness.outputDirectory
        let export = ExportHarness.request
        guard dir != nil || RenderHarness.benchMode || export != nil else { return }
        let pricing = PricingService()
        let store = UsageStore(pricing: pricing)
        Task { @MainActor in
            await pricing.loadCachedThenRefresh()
            await store.refresh()
            if let dir { await RenderHarness.run(store: store, pricing: pricing, into: dir) }
            if let export { ExportHarness.run(store: store, pricing: pricing, request: export) }
            RenderHarness.bench(store: store, pricing: pricing)
        }
    }
}

/// 离屏渲染快照（`--render <目录>`）：把主界面与设置页在浅色/深色两种外观下各出一张 PNG。
/// 只用于开发期核对排版 —— 屏幕锁定时截不了图，但它照样能出图。
enum RenderHarness {
    static var outputDirectory: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    @MainActor
    static func run(store: UsageStore, pricing: PricingService, into dir: String) async {
        // 菜单面板要一份配置。**只能用默认配置去出图** —— 它 `didSet` 就写 UserDefaults，
        // 在工装里改它等于把用户自己设的菜单栏指标覆盖掉。要核对别的组合，
        // 就在界面上改（那是用户自己的选择），不要在这里造。
        let menuBar = MenuBarSettings()
        // Form / TextEditor 这类 AppKit 承载的控件只认 NSAppearance、不认 \.colorScheme 环境值，
        // 两种外观都要设：环境值管 SwiftUI 自绘，NSApp.appearance 管 AppKit 控件。
        // 主体不能套 ScrollView —— 懒加载内容不会进离屏快照，所以直接用 DashboardBody。
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                           ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            // TitleStrip 也要出图：它占着顶部 28pt，漏掉的话快照和真窗口差一条
            // alignment: .top —— 这一张是模拟真窗口（1520×950 上下）：内容比画布略高，
            // 真窗口也是从顶部开始显示、底部露不全，居中反而会把顶部那条标题带切掉。
            capture(VStack(spacing: 0) { TitleStrip(); DashboardBody() }
                        .background(Theme.pageBackground)   // 漏掉它页面底会透明，深色下看着像白底
                        .environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                    size: CGSize(width: WindowFrameKeeper.designSize.width, height: 1010),
                    alignment: .top, to: "\(dir)/main-\(name).png")
            // ── 设置页走**真窗口**截图，不走 ImageRenderer ──
            // 这里踩过一个坑，记下来：这几张原先是用 `capture(...)`（ImageRenderer）出的，
            // 出来的其实**是纯空白** —— `settings-devices-light.png` 与 `settings-display-light.png`
            // 连 md5 都一样（`2e3c7483…`），也就是说那两张图从加进来那天起什么都没验证过。
            // 原因是 `Form { }.formStyle(.grouped)` 由 AppKit 承载、按需铺排，`ImageRenderer`
            // 拿不到它的内容；跟 `TabView` 无关（当时那句注释把责任记错了）。
            // 现在改成真挂一个 NSWindow 再 cache 出来，`Form` 才画得出来。
            await captureWindow(SettingsView().environmentObject(store).environmentObject(pricing).environmentObject(menuBar).environment(\.colorScheme, scheme),
                                size: CGSize(width: 680, height: 620), to: "\(dir)/settings-\(name).png")
            // 单个页签各出一张：设置窗口只有 680 宽，一屏只看得到一个页签，
            // 而 TabView 的一屏到底停在哪个页签上是运行期状态，不能指望
            await captureWindow(DeviceSyncSettings().environmentObject(store).environmentObject(pricing).environmentObject(menuBar).environment(\.colorScheme, scheme),
                                size: CGSize(width: 680, height: 620), to: "\(dir)/settings-devices-\(name).png")
            // 留存那一页的行数随环境数走，620 是设置窗口的高度、内容更高就自己滚，
            // 快照只核对「看得见的那一屏」排版对不对。
            // **必须注入报告**：那一页的数据是在 `.task` 里算的，而离屏工装不跑 `.task`，
            // 不注入就只能拍到「正在统计…」的占位。现算一份真的进去（只读，不改任何东西）。
            let retention = RetentionReport.make(records: store.records,
                                                 deviceFiles: store.deviceSync.readAll().files)
            await captureWindow(DisplaySettings(injectedReport: retention)
                        .environmentObject(store).environmentObject(pricing).environmentObject(menuBar).environment(\.colorScheme, scheme),
                    size: CGSize(width: 680, height: 620), to: "\(dir)/settings-display-\(name).png")
            // 菜单栏那张富面板本身是普通视图，直接渲染就能核对排版。
            // 高度不写死，让工装自己量（面板有几行、开了几个区块都会影响高度）。
            // 六项全勾的面板更高，但工装**只能出默认配置这一张** —— 改配置会写用户自己的 UserDefaults。
            captureFitting(MenuBarPanel(store: store, settings: menuBar)
                        .environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                    width: MenuBarPanel.panelWidth, to: "\(dir)/menubar-panel-\(name).png")
            // 弹层内容本身是普通视图，只是没法在离屏里当弹层弹出来 —— 直接渲染就能核对排版
            capture(PricingBrowser().environmentObject(pricing).environment(\.colorScheme, scheme),
                    size: CGSize(width: 600, height: 380), to: "\(dir)/pricing-browser-\(name).png")
            if let m = store.snapshot.byModel.first?.label {
                capture(ModelDetailPopover(model: m).environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                        size: CGSize(width: 440, height: 760), to: "\(dir)/model-detail-\(name).png")
                // 详情浮层：窗口高度不同，卡片一个贴内容、一个被压到内部滚动，顺带核对居中与遮罩。
                // 注意这里只能核对**几何**（卡片多大、落在哪）—— 中段一旦真的需要滚动，
                // ImageRenderer 就画不出那个 ScrollView 的内容（离屏渲染的已知限制，
                // 单独渲染一个内容超高的 ScrollView 会得到一片空白），内容得靠真窗口看。
                capture(ModelDetailOverlay(model: m, dismiss: {}).environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                        size: CGSize(width: 1180, height: 820), to: "\(dir)/overlay-tall-\(name).png")
                capture(ModelDetailOverlay(model: m, dismiss: {}).environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                        size: CGSize(width: 960, height: 640), to: "\(dir)/overlay-short-\(name).png")
            }
            // 三个维度各出一张：明细表的列宽与标签溢出只有在真实行数下才看得出来。
            // alignment 同样要 .top —— 「按日期」77 行、整页 4000 多 pt 高，居中之后这一张
            // 正好截在表格中段，表头根本不在图里（量的就是表头跟数据对不对齐，等于白出）。
            for mode in [BreakdownMode.model, .day] {
                store.breakdown = mode
                capture(VStack(spacing: 0) { TitleStrip(); DashboardBody() }
                            .background(Theme.pageBackground)
                            .environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                        size: CGSize(width: WindowFrameKeeper.designSize.width, height: 1420),
                        alignment: .top,
                        to: "\(dir)/main-\(name)-\(mode.fileTag).png")
            }
            // 最小窗口宽度下每个维度各出一张（只出浅色，两种外观的排版完全一样）：
            // 筛选区那一行和「折线卡 + 环形卡」并排都压到极限，是最容易互相挤坏的一档，
            // 1520 宽下怎么看都是好的。三个维度都出，是因为卡住最小宽度的正是明细表第一列
            // （模型名 / 设备名 / 日期三种长短不一，见 WindowFrameKeeper.minSize 那段账）。
            // 改 minSize、往表里加列、或者动两张图卡之后，先看这几张。
            if scheme == .light {
                for mode in [BreakdownMode.model, .device, .day] {
                    store.breakdown = mode
                    // alignment 必须是 .top：`.frame(height:)` 默认居中，而「按设备」只有两行、
                    // 整页不到 1420 高，居中之后顶部会空出一大条、表头跑到半空中 ——
                    // 快照看着像排版坏了，其实只是这一张没填满。贴顶就和真窗口一致。
                    capture(VStack(spacing: 0) { TitleStrip(); DashboardBody() }
                                .background(Theme.pageBackground)
                                .environmentObject(store).environmentObject(pricing).environment(\.colorScheme, scheme),
                            size: CGSize(width: WindowFrameKeeper.minSize.width, height: 1420),
                            alignment: .top,
                            to: "\(dir)/main-\(name)-narrow-\(mode.fileTag).png")
                }
            }
        }
        print("rendered \(dir)")
        exit(0)
    }

    static var benchMode: Bool { CommandLine.arguments.contains("--bench") }

    /// `--bench`：把整页光栅化几遍报中位数。
    ///
    /// 离屏环境里量不到真实帧率（没有窗口、没有 vsync），但「滚一帧要重画多少东西」
    /// 是同一个成本：滚动掉帧的优化改完必须有个客观标尺，否则只能靠感觉说「好像顺了」。
    /// 尺寸固定成整页高度，三种维度都渲染全部内容，横向可比。
    @MainActor
    static func bench(store: UsageStore, pricing: PricingService) {
        guard benchMode else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        for mode in [BreakdownMode.device, .model, .day] {
            store.breakdown = mode
            // 行数读 visibleRows（表格实际画的那份），不是 snapshot.rows —— 基准要量的就是屏幕上那份
            let rows = store.visibleRows.count
            // 两种口径：
            // - 整页：整个内容一次性画出来，量的是「一屏到底有多重」
            // - 视口：真的套一层 ScrollView 只画看得见的那部分 —— 这才是滚动时每帧的帐。
            //   懒加载只有在这个口径下才成立：不套 ScrollView，LazyVStack 会老老实实全建出来。
            let w = WindowFrameKeeper.designSize.width
            let fullSize = CGSize(width: w, height: 4200), frameSize = CGSize(width: w, height: 820)
            print(String(format: "bench %@: rows=%d full=%.1fms viewport=%.1fms",
                         mode.rawValue, rows,
                         median { raster(page(store, pricing), size: fullSize) },
                         median { raster(page(store, pricing, scrolled: true), size: frameSize) }))
        }
        exit(0)
    }

    @MainActor
    private static func page(_ store: UsageStore, _ pricing: PricingService, scrolled: Bool = false) -> some View {
        VStack(spacing: 0) {
            TitleStrip()
            if scrolled { ScrollView { DashboardBody() } } else { DashboardBody() }
        }
        .background(Theme.pageBackground)
        .environmentObject(store).environmentObject(pricing)
        .environment(\.colorScheme, .light)
    }

    /// 预热一遍再取 5 次中位数：首帧含字体与着色器缓存，算进去只会让数字难看
    @MainActor
    private static func median(_ body: () -> Int) -> Double {
        _ = body()
        var times: [Double] = []
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = body()
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        return times.sorted()[2]
    }

    @MainActor
    private static func raster<V: View>(_ view: V, size: CGSize) -> Int {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh
    }

    /// 真窗口截图，专治 `Form` / `TabView` 这类 AppKit 承载的界面（见上面那段踩坑记录）。
    ///
    /// 跟 `capture` 的区别：这条路上视图真的被挂进一个 `NSWindow`、真的跑过一次布局，
    /// 所以 `Form` 的行会出现。**不 `orderFront`** —— 屏幕上不该闪出一个窗口来，
    /// 用户正在用这台机器；不显示也不影响布局与 `cacheDisplay`。
    ///
    /// 中间那一下 `Task.sleep` 是**必须**的：SwiftUI 的铺排在这个 runloop 轮次之后才落地，
    /// 建完窗口立刻截图只会得到一张空白（最早那几张快照就是这么废掉的）。
    /// 用 `sleep` 而不是 `RunLoop.current.run(until:)`：后者是在主线程里套一层跑圈，
    /// 而这个函数本来就是 `async`，让出去一拍更干净。
    @MainActor
    private static func captureWindow<V: View>(_ view: V, size: CGSize, to path: String) async {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("window capture failed: \(path)"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("window capture encode failed: \(path)"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        // 拆掉，免得它跟真窗口抢 `NSApp.windows` 里的位置（后面还要截别的页面）
        window.contentView = nil
    }

    /// 高度由内容决定的视图（菜单栏面板就是）：先量一次贴合高度，再按量到的尺寸出图。
    ///
    /// 这里原来写死 420。2026-09-25 按 calendar-plus 的排版重排面板之后，面板长到了 500 出头，
    /// 快照把页脚整个裁掉了 —— 而**裁掉的部分在图上看起来只是「到底了」**，
    /// 不对着源码比根本发现不了。写死的高度迟早和内容脱节，这种静默失效正是快照最不该有的，
    /// 所以让它自己量：以后往面板里加一行，图跟着长。
    @MainActor
    private static func captureFitting<V: View>(_ view: V, width: CGFloat, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        let measured = host.fittingSize.height
        guard measured > 1 else {
            // 量不到就退回一个「肯定够」的高度并在日志里说一声：
            // 悄悄退回写死值的话，就成了同一个坑换个地方再踩一次。
            print("fittingSize 量不到高度（\(path)），退回 560")
            capture(view, size: CGSize(width: width, height: 560), alignment: .top, to: path)
            return
        }
        capture(view, size: CGSize(width: width, height: ceil(measured)), alignment: .top, to: path)
    }

    /// `alignment` 只管内容比 `size` 矮时往哪边靠 —— 定尺寸的 `.frame` 默认居中，
    /// 页面类的快照要 `.top`（跟真窗口一样贴顶），卡片类的保持默认居中。
    @MainActor
    private static func capture<V: View>(_ view: V, size: CGSize, alignment: Alignment = .center, to path: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: alignment))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed: \(path)"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
