import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService

    /// 当前打开详情的模型。状态放在**窗口这一层**，不在明细表的行上 —— 原因见 `ModelDetailOverlay`。
    @State private var detailModel: String?

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()
            // overlayScroller 要挂在 ScrollView **里面**：它靠往上找最近的 NSScrollView 生效
            ScrollView { DashboardBody().overlayScroller() }
        }
        .background(Theme.pageBackground)
        .overlay(alignment: .bottom) {
            if store.isScanning { scanningBanner }
        }
        .environment(\.modelDetail, $detailModel)
        // 浮层挂在 ScrollView 外面：它因此不属于任何一行，也不受滚动影响，永远落在窗口正中。
        // 外面再包一层 ZStack 是为了把 `.animation` 的作用域圈在这棵子树里 ——
        // 直接挂在外层 VStack 上的话，这段动画会罩住整个仪表盘。
        .overlay {
            ZStack {
                if let model = detailModel {
                    ModelDetailOverlay(model: model) { detailModel = nil }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.16), value: detailModel)
        }
        // 换维度 / 换范围后原来的行可能已经不在表里，留着状态会让浮层挂在一个不存在的模型上
        .onChange(of: store.breakdown) { _, _ in
            detailModel = nil
            // 「按日期」那一列的名称就是时间，A→Z 读起来是从最早开始，跟这张表「新的在前」的
            // 默认相反。切过去时把方向掰回来，否则一按日期就是倒着的，得手点两下才正。
            store.sort.normalize(for: store.breakdown)
        }
        .onChange(of: store.rangeStart) { _, _ in detailModel = nil }
    }

    private var scanningBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在扫描本地会话…").font(.system(size: 12)).foregroundStyle(Theme.gray700)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.cardBackground, in: Capsule())
        .overlay(Capsule().stroke(Theme.cardBorder))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .padding(.bottom, 16)
    }
}

/// 模型详情浮层的选中项，由 `ContentView` 持有、经环境下发。
///
/// 走环境而不是逐层传 Binding：明细表埋在 `ScrollView > DashboardBody > BreakdownTable` 里，
/// 逐层透传要改三个视图的签名，还会连带改离屏渲染那边的调用点；环境键的默认值是
/// `.constant(nil)`，渲染快照不需要详情浮层，调用点一个都不用动。
struct ModelDetailKey: EnvironmentKey {
    static let defaultValue: Binding<String?> = .constant(nil)
}

extension EnvironmentValues {
    var modelDetail: Binding<String?> {
        get { self[ModelDetailKey.self] }
        set { self[ModelDetailKey.self] = newValue }
    }
}

/// 仪表盘主体单独拆出来：离屏渲染时不能套 ScrollView（懒加载内容不会出图），
/// 用它就能在无窗口环境里出完整快照。
struct DashboardBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            StatCardsView()
            CompositionStrip()
            HStack(alignment: .top, spacing: 16) {
                DailyChartView().frame(maxWidth: .infinity)
                DistributionView().frame(width: 340)
            }
            BreakdownTable()
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

// MARK: - 顶部占位带（交通灯 + 窗口拖动）

/// `.windowStyle(.hiddenTitleBar)` 下没有可见标题栏，但红黄绿三个按钮仍压在内容顶部
/// （实测中心 y≈14、底边 y≈26）。这条 28pt 的空白带就是它们的位置，整条同时是窗口拖动区。
///
/// 它必须留在 `ScrollView` **外面**：放进去的话一滚动，内容就会滑到交通灯底下。
/// 原先这里是一整行 52pt 的标题栏，右端放指标切换 / 刷新 / 设置 —— 左三分之二永远是空的，
/// 而交通灯只要 28pt。那三个控件已搬到日期行右端（见 `FilterBar.viewOptions`），
/// 于是凭空少掉一整行、顶部也矮了 24pt。
struct TitleStrip: View {
    /// 28pt = 系统标题栏高度，交通灯正好落在带子中间
    static let height: CGFloat = 28

    var body: some View {
        // allowsHitTesting(false)：这一条对事件是**透明的**，点/双击/拖动都落到它下面的标题栏上
        // —— 拖动窗口、双击缩放（如果系统偏好这么设）才跟原生窗口一致。
        // 留着一层能接收事件的透明视图，等于把标题栏盖住。
        Color.clear
            .frame(height: Self.height)
            .allowsHitTesting(false)
    }
}

// MARK: - 筛选栏：日期胶囊 + 快捷档位 + 环境 chips
// 所有筛选集中在图表上方一行，图表本身不再各带筛选器。

struct FilterBar: View {
    @EnvironmentObject var store: UsageStore
    @Environment(\.openSettings) private var openSettings
    /// 日期弹层由这一层持有：日期胶囊和「自定义」都开它，弹层锚点就一直钉在胶囊上，
    /// 不会因为从哪边点开而换位置。
    @State private var showDatePicker = false

    var body: some View {
        // 三行：日期、设备、环境。行序是**由粗到细**：先框住时间（总量），再框住机器（哪几台），
        // 最后框住工具（哪些环境）。跟明细表的层级也一致 —— 按设备那几行里嵌的就是环境 chips，
        // 所以设备必须排在环境上面。每行同一个读法：左边一个图标入口开概览弹层，右边 chips 平铺。
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DateRangePill(showPopover: $showDatePicker)
                QuickRangeBar(selection: Binding(
                    // 范围恰好等于某个内置档位就是它，手动改过日期则落在「自定义」上
                    get: { store.activeQuickRange.map(QuickRangeItem.range) ?? .custom },
                    // 点「自定义」不是选了一个范围，而是拉开日期弹层
                    set: { if case .range(let q) = $0 { store.apply(q) } else { showDatePicker = true } }
                ))
                Spacer(minLength: 16)
                viewOptions
            }
            DeviceSelector()
            EnvironmentSelector()
        }
    }

    /// 定时刷新 + 刷新 + 导出 + 设置。原先这上面还挂着一个全局的 费用/Tokens 开关，左三分之二是空的，
    /// 于是整行搬到日期行右端。那个开关后来**又拆掉了** —— 它管的是两张图的读法，
    /// 而每日趋势和环境分布各自有更合适的默认口径，一个全局开关两边都将就；
    /// 现在两张卡各带一个自己的开关（见 DailyChartView / DistributionView），
    /// 这里就只剩几个动作控件，跟着日期行靠右站，组成一个工具组。
    ///
    /// 定时刷新排在手动刷新**左边**：两个都管「数据什么时候更新」，挨着放，
    /// 而手点的那颗仍是这一组的第一个图标按钮（位置没动过，老用户不用重找）。
    ///
    /// 宽度账：日期胶囊 304 + 档位条 565 + 定时刷新约 92 + 三个 34pt 按钮 102
    /// + 按钮间距 40 + 卡内间距 16 + 页面留白 48 ≈ 1167，**离最小窗口宽度 1180 只剩十几 pt**。
    /// 定时刷新那一条因此不带图标（见 `RefreshIntervalControl`），否则这一行会被挤到
    /// 让日期去换行 —— 日期是定长的标识符，换行处正好落在数字中间，看着像坏了。
    /// 这一行现在靠 `--render` 的 `main-*-narrow` 那几张盯住（改这里之前先看它们）。
    private var viewOptions: some View {
        HStack(spacing: 10) {
            RefreshIntervalControl(store: store)
            IconButton(systemName: "arrow.clockwise",
                       help: store.lastScan.map { "上次扫描 \($0.formatted(date: .omitted, time: .shortened))，耗时 \(String(format: "%.1fs", store.scanDuration))" } ?? "扫描本地会话并同步各设备",
                       disabled: store.isScanning,
                       size: 34) { Task { await store.refresh() } }
            ExportMenu()
            IconButton(systemName: "gearshape", help: "设置", size: 34) { openSettings() }
        }
    }
}

// MARK: - Token 构成条

struct CompositionStrip: View {
    @EnvironmentObject var store: UsageStore

    /// 4 个 token 桶 = 4 个分类，取色板前 4 槽（固定顺序，不随数值变化）
    private var parts: [(String, Int, Color)] {
        let t = store.snapshot.totals
        return [("缓存读取", t.cachedInput, Theme.series[0]), ("未缓存输入", t.uncachedInput, Theme.series[2]),
                ("缓存写入", t.cacheWrite, Theme.series[3]), ("输出", t.output, Theme.series[4])]
    }

    /// 相邻堆叠段之间留 2px 载体色缝隙来分隔，而不是给每段描边
    private static let gap: CGFloat = 2

    var body: some View {
        let total = max(1, store.snapshot.totals.processed)
        let visible = parts.filter { $0.1 > 0 }.count
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token 构成").font(.system(size: 12)).foregroundStyle(Theme.gray600)
                Text("\(Formatters.tokens(store.snapshot.totals.processed)) 合计").font(.system(size: 12)).foregroundStyle(Theme.gray500)
                AltUnit(text: Formatters.tokensCN(store.snapshot.totals.processed), size: 10)
            }
            GeometryReader { geo in
                let usable = max(0, geo.size.width - Self.gap * CGFloat(max(0, visible - 1)))
                HStack(spacing: Self.gap) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.2)
                            .frame(width: p.1 > 0 ? max(3, usable * CGFloat(p.1) / CGFloat(total)) : 0)
                    }
                }
                .clipShape(Capsule())
                .background(Capsule().fill(Theme.divider))
            }
            .frame(height: 10)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 34)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(p.2).frame(width: 8, height: 8)
                            Text(p.0).font(.system(size: 11.5)).foregroundStyle(Theme.gray500)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(Formatters.tokens(p.1)).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Theme.gray900)
                            Text(Formatters.percent(Double(p.1) / Double(total))).font(.system(size: 11)).foregroundStyle(Theme.gray500)
                        }
                        AltUnit(text: Formatters.tokensCN(p.1), size: 10)
                    }
                    .frame(width: 130, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .card(padding: 0)
    }
}
