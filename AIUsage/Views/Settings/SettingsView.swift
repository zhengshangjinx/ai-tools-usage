import SwiftUI

/// 设置窗口。
///
/// ## 为什么是手搭的 `HStack`，不是 `NavigationSplitView`
///
/// 1. `NavigationSplitView` 背后是 `NSSplitViewController`，侧栏宽度会**自存进 UserDefaults**
///    （`NSSplitView` 的 autosave）。那正是 `DemoRuntime.restoreAppKitKeys` 要拦的一类 AppKit 自写，
///    而它的 `guardedPrefixes` 只覆盖 `NSWindow Frame ` / `NSStatusItem ` ——
///    `scripts/shoot.sh` 出图前后比对真实配置域时会因此报红。
/// 2. 它在 `Settings` scene 里会自带一个工具栏的侧栏折叠按钮，而关掉它的
///    `.toolbar(removing:)` 是 **macOS 15** 才有的 API，本工程最低 14。
/// 3. 侧栏是静态的（两组五行 + 一行钉底），split view 什么也没买到。
///
/// 代价是没有方向键导航 —— 行做成真 `Button` + `.accessibilityAddTraits(.isSelected)` 补回来。
struct SettingsView: View {
    /// 设置窗口尺寸的**唯一**来源。`RenderHarness` 也读它，别再写第二处。
    /// 880 = 200 侧栏 + 1 分隔线 + 679 内容 —— **内容列宽度与改造前的 680 基本一致**，
    /// 所以四个面板的排版一行都不用重调，这次变的只是外壳。
    static let size = CGSize(width: 880, height: 620)
    static let sidebarWidth: CGFloat = 200
    /// 详情列宽度。**必须显式定死**，理由见 `body` 里那段。
    static var detailWidth: CGFloat { size.width - sidebarWidth - 1 }

    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService
    @EnvironmentObject var menuBar: MenuBarSettings
    @EnvironmentObject var behavior: AppBehaviorSettings
    @EnvironmentObject var update: UpdateService

    /// 出图工装注入用。**必须从这里透到 `.display`** ——
    /// `DisplaySettings` 的报告是在 `.task` 里算的，而离屏工装不跑 `.task`；
    /// 注入断了不会报错，只会让 `settings-display-*.png` 变成「正在统计…」的占位，
    /// 然后被 `shoot.sh` 照常拷进仓库。
    var injectedRetention: RetentionReport?
    /// 工装逐页出图用；正常打开时固定落在「数据源」。
    var initialPane: SettingsPane = .sources

    @State private var selection: SettingsPane?

    private var active: SettingsPane { selection ?? initialPane }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: Binding(get: { active }, set: { selection = $0 }))
                .frame(width: Self.sidebarWidth)
            Rectangle().fill(Theme.paneDivider).frame(width: 1)
            // 详情列**显式定宽**，不写成 `maxWidth: .infinity`。
            //
            // 起因：切到「显示与留存」时侧栏会被挤窄 3pt（实测分隔线落在 197 而不是 200），
            // 换回别的页又弹回去 —— 一眼能看出的横向抖动。原因是这一页里有一行内容
            // （六个指标 chip 排成一个 `HStack`）的最小宽度超过了内容列，`HStack` 分配宽度时
            // 就把这个亏空按比例摊到了同级的侧栏头上，而侧栏只是 `.frame(width:)`、
            // 并不是不可压缩的。两列都定死之后 200 + 1 + 679 正好等于窗口宽度，
            // 没有亏空可摊，切页签时布局就完全不动了。
            //
            // 代价：内容列放不下的东西会被裁掉，而不是把侧栏推歪。**这是有意的** ——
            // 一页撑破窗口是排版 bug，应该在出图时看见并改掉那一页，而不是让侧栏替它受过。
            detail
                .frame(width: Self.detailWidth, alignment: .top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.pageBackground)
    }

    @ViewBuilder private var detail: some View {
        switch active {
        case .sources: SourcesSettings()
        case .devices: DeviceSyncSettings()
        case .pricing: PricingSettings()
        case .display: DisplaySettings(injectedReport: injectedRetention)
        case .about: AboutSettings()
        }
    }
}
