import SwiftUI
import AppKit

/// 面板自己的尺寸令牌。**刻意不放进 `Theme`**：那等于顺手做一次全项目的圆角令牌化
/// （主界面现在散着 9 / 7 / 6 / 5 各种字面量），那是另一件事、另一轮。
/// 这里只保证这一个面板内部自己是一致的。
///
/// 圆角三档取自 calendar-plus 的收敛结论：按元素尺寸分档、**外大内小**。
/// 那一套是 panel 14 / card 12 / tile 8 / control 6 / xs 4 / bar 2，面板里用得到的只有后三档。
private enum PanelMetric {
    /// 面板宽度。**放在这里是因为工装也要用**（`--render` 得按同一个宽度量高度），
    /// 两处各写一个数字的话，改了面板宽度快照就先失真。
    /// 参考项目那份面板是 330，我们 320 —— 少的那 10pt 是给菜单栏省地方。
    static let width: CGFloat = 320
    /// 面板左右内边距。**比上下大 4pt，不是笔误**：
    /// 数值是右对齐、贴着右边沿的，眼睛会把那条齐边当成面板的边，
    /// 同样 12pt 在右边看起来就是比上面挤（2026-09-25 用户反馈「两边间距太小」）。
    /// 左右给到 16 之后，齐边到面板边沿的留白和上下的观感才对得上。
    static let paddingH: CGFloat = 16
    /// 面板上下内边距
    static let paddingV: CGFloat = 12
    /// 标题行高度
    static let headerHeight: CGFloat = 30
    /// 区块头（「今日」「本月」「近 7 天」）高度
    static let sectionHeaderHeight: CGFloat = 20
    /// 页脚高度。28pt 的图标按钮 + 上下各 2pt，与 32pt 的实心圆同居中
    static let footerHeight: CGFloat = 32
    /// 指标行左侧那枚瓷片图标的边长
    static let tile: CGFloat = 20
    /// 瓷片与标题文字的间距。**下面所有「缩进到文字左边缘」的算术都用这两个数**
    /// （`tile + tileGap`），改其中一个就自动跟着走，不会再出现「分线差 3pt」那类毛病。
    static let tileGap: CGFloat = 10
    /// 指标行的上下内边距
    static let rowPadding: CGFloat = 7

    enum Radius {
        /// 20pt 瓷片（control 档）
        static let tile: CGFloat = 6
        /// 28pt 图标按钮的悬停底（tile 档）
        static let button: CGFloat = 8
        /// 迷你柱（bar 档）
        static let bar: CGFloat = 2
    }

    /// 迷你柱里「不是今天」那一档色。
    ///
    /// **不用 `Theme.primary.opacity(0.3)`**：透明度是「自动反色」，同一个 0.3
    /// 叠在白底上是一档浅蓝（好看），叠在深色底（#1E1E23）上就成了一块发浑的暗蓝，
    /// 色相都快看不出来（2026-09-25 出图时在深色那张上看到的就是这个）。
    /// 深浅各取一个值，两边都是「同一色相、比今天弱一档」——
    /// 深色那档特意**提亮**，因为「弱」在深底上不等于「更暗」。
    static let barMuted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: 0x3F5296)
            : NSColor(hex: 0xCEDBFF)
    })
}

/// 菜单栏那张富面板（`.menuBarExtraStyle(.window)`）。
///
/// 三件事：今日/本月的指标、固定 7 天的迷你柱、三个动作。
/// 指标行与菜单栏文字都**只读** `store.menuBarSummary` —— 那份摘要是固定窗口（今日 / 本月 / 近 7 天），
/// 与主窗口选的日期范围无关。**绝不能在这里改 `store.rangeStart`/`rangeEnd` 来「取今日」**：
/// 那两个字带 `didSet { recompute() }`，等于点一下菜单栏就把主窗口的日期范围劫持了。
/// （`--render` 工装里直接改 `store.breakdown` 那套手法在这儿不成立 —— 那边没有别的观察者会受害。）
///
/// 2026-09-25 按用户要求对着 `/calendar-plus` 的面板语言重排过（「面板缺少这种质感」）。
/// 借来的是**排版纪律**，不是它的颜色与组件：令牌仍走我们自己的 `Theme`。
/// 具体借了四条，都在下面各自的注释里写了理由：
/// 标题/说明两级文字 + 右侧等宽数值、分隔线缩进到文字左边缘、
/// 区块头而不是「一段同质的数排到底」、页脚只留三个图标且主操作是实心强调色圆。
struct MenuBarPanel: View {
    /// 面板宽度。给 `--render` 工装用的出口 —— 它得按同一个宽度量贴合高度（见 `PanelMetric.width`）。
    static let panelWidth = PanelMetric.width

    @ObservedObject var store: UsageStore
    @ObservedObject var settings: MenuBarSettings
    @Environment(\.openWindow) private var openWindow

    private var summary: MenuBarSummary { store.menuBarSummary }
    private var config: MenuBarConfig { settings.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            metrics
            weekSection
                .padding(.top, 14)
            footer
                .padding(.top, 12)
        }
        .padding(.horizontal, PanelMetric.paddingH)
        .padding(.vertical, PanelMetric.paddingV)
        .frame(width: PanelMetric.width)
        // `.window` 风格的面板默认没有底色，不铺一层就是半透明的，深色下文字直接糊在壁纸上
        .background(Theme.cardBackground)
    }

    // MARK: - 标题行

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("AI 用量统计")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.gray900)
                .lineLimit(1)
            // 次要信息与标题**同一行**、靠基线对齐（不是另起一行压在标题下面）：
            // 320pt 宽的面板里，把「几点扫的」降一级并排放在标题右边，
            // 眼睛扫过标题时顺带就读到了，而标题下面那一行要留给真正的数据。
            Text(scanText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.gray500)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 定时刷新。跟在主窗口工具组里那颗是同一份状态（见 `RefreshIntervalControl`），
            // 放这一行是因为它解释的正是左边那句「几点更新」——「多久更新一次」与
            // 「上次更新是什么时候」是同一个问题的两半，分开放两边反而要来回找。
            RefreshIntervalControl(store: store, compact: true)
        }
        .frame(height: PanelMetric.headerHeight)
    }

    /// 扫描状态一句话说完。三种状态互斥，不并列 —— 面板顶部只有一个位置。
    /// 扫描中**不留上次的时间**：两个时间挨在一起，读者要停下来分辨哪个是现在的。
    private var scanText: String {
        if store.isScanning { return "正在扫描…" }
        guard let last = store.lastScan else { return "尚未扫描" }
        return "\(last.formatted(date: .omitted, time: .shortened)) 更新"
    }

    // MARK: - 指标

    @ViewBuilder
    private var metrics: some View {
        if config.panel.isEmpty {
            Text("面板没有选中任何指标，去「设置 → 显示与留存」里勾")
                .font(.system(size: 12))
                .foregroundStyle(Theme.gray500)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(scopes.enumerated()), id: \.element.id) { i, scope in
                    if i > 0 { Spacer().frame(height: 10) }
                    sectionHeader(scope.title)
                    ForEach(Array(scope.items.enumerated()), id: \.element) { j, metric in
                        if j > 0 { rowDivider }
                        MetricRow(metric: metric, summary: summary)
                    }
                }
            }
        }
    }

    /// 按「今日 / 本月」分成两段。
    ///
    /// 原来的做法是「相邻两项的窗口不同就插一条分隔线」，六行同质的数排在一起时
    /// 一条线说明不了「上面是今天、下面是这个月」—— 线两侧都是同一套标签（费用 / Tokens / 请求数），
    /// 读者得自己往回找。改成显式的区块头，界标本身就是一句话。
    /// 段序固定「今日 → 本月」（抬头先看今天），**段内保持用户在设置里勾选的顺序**。
    private var scopes: [Scope] {
        [Scope(title: "今日", items: config.panel.filter { !$0.isMonth }),
         Scope(title: "本月", items: config.panel.filter { $0.isMonth })]
            .filter { !$0.items.isEmpty }
    }

    private struct Scope: Identifiable {
        let title: String
        let items: [MenuBarMetric]
        var id: String { title }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.gray600)
            .frame(height: PanelMetric.sectionHeaderHeight, alignment: .bottom)
    }

    /// 行间分隔线：缩进到标题文字的左边缘（瓷片 20 + 间距 10），不是横贯整块面板。
    /// 齐左的短线把「图标列」和「文字列」分开了；贯通线会把刚分好的两列又焊回一整块。
    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.leading, PanelMetric.tile + PanelMetric.tileGap)
    }

    /// 一行 = 瓷片图标 + 标题 + 右侧数值，说明文字另起一行、缩进到标题左边缘。
    ///
    /// 说明**不做悬停底**：这一行不可点（点了没有任何事发生）。悬停反馈是「这里能点」的承诺，
    /// 给一个不可点的行铺底色，比没有反馈更糟 —— 那是在骗人。
    private struct MetricRow: View {
        let metric: MenuBarMetric
        let summary: MenuBarSummary

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: PanelMetric.tileGap) {
                    Image(systemName: metric.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .frame(width: PanelMetric.tile, height: PanelMetric.tile)
                        .background(Theme.primarySoft,
                                    in: RoundedRectangle(cornerRadius: PanelMetric.Radius.tile, style: .continuous))
                    Text(metric.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.gray700)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 数值是这一行的主角：比标题大一档、颜色最重、等宽数字（六行一起看时小数点对齐）
                    Text(metric.text(summary))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.gray900)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Text(metric.sub(summary))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.gray500)
                    .lineLimit(1)
                    .padding(.leading, PanelMetric.tile + PanelMetric.tileGap)
            }
            .padding(.vertical, PanelMetric.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 近 7 天

    /// 迷你趋势与上面的指标之间**不画线**：区块头「近 7 天」自己就是界标，
    /// 再加一条横线是同一个意思说两遍。间距（14pt）比段内的 10pt 大一档，
    /// 眼睛靠疏密就能把两块分开。
    private var weekSection: some View {
        WeekBars(days: summary.last7)
    }

    // MARK: - 页脚

    /// 页脚只留三件，主操作是中间那枚实心强调色的圆 —— 照 calendar-plus 页脚的排法
    /// （之前是三个等重的整行按钮，一行「退出 AI 用量统计」和「打开主窗口」一样大，
    /// 视线没有落点，也白占了 3×26pt 的高度）。
    ///
    /// 退出放最左：它是唯一不可逆的一个，离视线第一落点（中间的主操作）最远。
    /// 悬停时染成危险色，让它在按下去之前先自己亮一下身份。
    private var footer: some View {
        HStack(spacing: 0) {
            PanelIconButton(icon: "power", help: "退出 AI 用量统计", hoverTint: Theme.statusCritical) {
                NSApp.terminate(nil)
            }
            Spacer(minLength: 0)
            PrimaryActionButton(icon: "macwindow", help: "打开主窗口") {
                // 顺序不能换：App 退成纯状态栏之后是 `.accessory`，那个形态下 `makeKeyAndOrderFront`
                // 拿不到键盘焦点 —— 先开窗再改策略，开出来的窗口是死的（⌘W 都不响应）。
                // `activateForWindow()` 里已经含 `NSApp.activate(ignoringOtherApps:)`
                // （菜单栏点出来的窗口不会自己抢焦点，不激活的话它开在别的窗口后面），别在这里再写一遍。
                ActivationPolicyController.activateForWindow()
                openWindow(id: "main")
            }
            Spacer(minLength: 0)
            PanelIconButton(icon: "arrow.clockwise", help: "立即刷新", disabled: store.isScanning) {
                Task { await store.refresh() }
            }
        }
        .frame(height: PanelMetric.footerHeight)
    }

    /// 28pt 图标按钮：静止时无底，悬停铺一层 `Theme.hover` 并给图标染色。
    /// 静止态不画底是**故意的** —— 页脚三个按钮各顶着一个灰方块，看着像三个待填的空位。
    private struct PanelIconButton: View {
        let icon: String
        let help: String
        var disabled = false
        var hoverTint: Color? = nil
        let action: () -> Void
        @State private var hovering = false

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: PanelMetric.Radius.button, style: .continuous)
        }

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(disabled ? Theme.gray500 : (hovering ? (hoverTint ?? Theme.primary) : Theme.gray600))
                    .frame(width: 28, height: 28)
                    .background(hovering && !disabled ? Theme.hover : .clear, in: shape)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(help)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }

    /// 主操作：32pt 实心圆（淡强调色底 + 强调色图标），悬停加深。
    /// 用「淡底 + 同色图标」而不是「实心底 + 白图标」：页脚不是主界面，一块饱和的实心色
    /// 在 320pt 宽的面板里会把上面六行数字全部压下去。
    private struct PrimaryActionButton: View {
        let icon: String
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 32, height: 32)
                    .background(Theme.primary.opacity(hovering ? 0.28 : 0.15), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - 近 7 天

/// 近 7 天的迷你柱。**自绘，不用 Swift Charts** —— `DailyChartView` 是给大卡片做的，
/// 带坐标轴、图例、悬停，塞进 320pt 的面板里只剩噪声。
///
/// 七根柱是**同一个量的七天**，不是七个身份，所以只用一档色相的两个明度：
/// 今天最重、其余压淡。给每天各配一个颜色是把「序列身份色」用在了没有身份的地方，
/// 读者会去找这七种颜色各自代表什么。
private struct WeekBars: View {
    let days: [MenuBarSummary.Day]

    private static let barWidth: CGFloat = 24
    private static let barMaxHeight: CGFloat = 44
    /// 柱底那条基线到日期数字的间距
    private static let baselineGap: CGFloat = 5
    /// 日期数字那一行的高度（10pt 字）
    private static let dayLabelHeight: CGFloat = 13

    private var peak: Int { max(1, days.map(\.tokens).max() ?? 0) }
    private var total: Int { days.reduce(0) { $0 + $1.tokens } }

    /// 柱高按当周峰值取比例。**没有用量的那天不画柱**（高度 0），
    /// 靠下面那条基线表达「这天在窗口里，只是没有量」——
    /// 原来给了个 2pt 的小墩子，浅色下像一根脏线，深色下和底色几乎一样看不见，
    /// 一个「看起来像柱子其实只有 2pt」的东西比什么都没有更容易被误读成小数值。
    private func height(_ tokens: Int) -> CGFloat {
        guard tokens > 0 else { return 0 }
        return max(4, Self.barMaxHeight * CGFloat(tokens) / CGFloat(peak))
    }

    private func color(_ d: MenuBarSummary.Day) -> Color {
        Calendar.current.isDateInToday(d.day) ? Theme.primary : PanelMetric.barMuted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("近 7 天")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.gray600)
                Spacer(minLength: 8)
                Text("合计 \(Formatters.tokens(total))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.gray500)
                    .monospacedDigit()
            }
            .frame(height: PanelMetric.sectionHeaderHeight, alignment: .bottom)

            // 每格等宽、柱子居中：柱子宽度写死 24，靠格子等分撑出等距，
            // 不写死的话柱子会随 token 数变化的文本宽度左右乱跑。
            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(days) { d in
                        RoundedRectangle(cornerRadius: PanelMetric.Radius.bar, style: .continuous)
                            .fill(color(d))
                            .frame(width: Self.barWidth, height: height(d.tokens))
                            .frame(maxWidth: .infinity)   // 柱子在格子里居中，格子本身撑满等分
                            .help("\(Formatters.dayLabel(d.day))：\(Formatters.tokens(d.tokens)) tokens · \(Formatters.cost(d.cost))")
                    }
                }
                .frame(height: Self.barMaxHeight, alignment: .bottom)
                // 基线。用 `cardBorder`（8% 黑白）而不是 `Theme.divider`：后者在深色下
                // 几乎和面板底色同色，等于深色模式里没有这条线。
                Rectangle()
                    .fill(Theme.cardBorder)
                    .frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(days) { d in
                        Text("\(Calendar.current.component(.day, from: d.day))")
                            .font(.system(size: 10))
                            .foregroundStyle(Calendar.current.isDateInToday(d.day) ? Theme.primary : Theme.gray500)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: Self.dayLabelHeight)
                .padding(.top, Self.baselineGap)
            }
        }
    }
}
