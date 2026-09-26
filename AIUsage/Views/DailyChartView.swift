import SwiftUI
import Charts

/// 每日趋势折线卡：2px 折线 + 10% 面积浅晕 + 顶部图例 + 十字准线悬浮明细。
///
/// 规范要点（dataviz）：
/// - 网格/轴是**实线发丝线**，比载体深一档就够，绝不用虚线
/// - 面积填充是「一层浅晕」（~10%），不是饱和色块；饱和只留给细线和标记点
/// - 用 `.monotone` 而非 `.catmullRom`：后者会过冲，在两点之间造出实际不存在的峰值
/// - 颜色跟随实体（ProviderKind），筛选后存活序列不会被重新着色
struct DailyChartView: View {
    @EnvironmentObject var store: UsageStore
    @State private var hoverDay: Date?
    /// 这张卡自己的指标口径。**跟环境分布那张卡各管各的** —— 原先是一个全局开关，
    /// 点一下两张图一起变；但那两张图回答的是不同的问题（趋势 vs 构成），
    /// 想一边看费用趋势、一边看 token 构成是常态。默认 Tokens：这张卡的纵轴是量，
    /// token 是原始单位，费用是换算值。
    @State private var metric: Metric = .tokens

    /// 悬浮动画只作用在提示卡这一层（见 chartOverlay）：十字线本身必须跟手，
    /// 给它加动画只会让准线追着鼠标跑，还白白多渲染几十帧图表。
    private static let tooltipAnimation = Animation.easeOut(duration: 0.13)

    var body: some View {
        // 一次算好：providers / series 在下面被引用十几次，而它们每次都要全量扫一遍
        // 所有数据点。滚动时每个 body 都重算是纯浪费，这里收敛成一次。
        let data = ChartData(points: store.snapshot.daily, metric: metric)
        VStack(alignment: .leading, spacing: 12) {
            // 副标题不再重复指标名 —— 右边那个开关已经写着当前看的是哪个了
            CardHeader("每日趋势", subtitle: "按日聚合 · 各环境用量") {
                HStack(spacing: 12) {
                    metricToggle
                    legend(data)
                }
            }
            if data.series.isEmpty {
                emptyState
            } else {
                chart(data).frame(height: 252)
            }
        }
        .card()
        .frame(height: 336)
        // 换范围后原来悬浮的那天可能已经不在区间里，准线和提示卡会留在图外
        .onChange(of: store.rangeStart) { _, _ in hoverDay = nil }
        .onChange(of: store.rangeEnd) { _, _ in hoverDay = nil }
        // 换指标后纵轴量纲全变，原来悬浮的那天留着会画出一条对不上的准线
        .onChange(of: metric) { _, _ in hoverDay = nil }
    }

    private var metricToggle: some View {
        SegmentedControl(options: Metric.allCases.map { ($0, $0.rawValue) },
                         selection: $metric, itemWidth: 54, height: 26)
    }

    /// 折线图的图例用「短线键」而不是圆点，形状与图上标记一致
    private func legend(_ data: ChartData) -> some View {
        HStack(spacing: 14) {
            ForEach(data.providers) { p in
                HStack(spacing: 5) {
                    Capsule().fill(p.accent).frame(width: 12, height: 2.5)
                    Text(p.displayName).font(.system(size: 12)).foregroundStyle(Theme.gray600)
                }
            }
        }
    }

    private var emptyState: some View {
        Text("所选范围内暂无数据")
            .font(.system(size: 13)).foregroundStyle(Theme.gray500)
            .frame(maxWidth: .infinity, minHeight: 252)
    }

    private func chart(_ data: ChartData) -> some View {
        Chart {
            ForEach(data.series) { p in
                AreaMark(x: .value("日期", p.day, unit: .day), y: .value("值", data.value(p)), stacking: .unstacked)
                    .foregroundStyle(by: .value("环境", p.provider.displayName))
                    .interpolationMethod(.monotone)
                    .opacity(0.10)
                LineMark(x: .value("日期", p.day, unit: .day), y: .value("值", data.value(p)))
                    .foregroundStyle(by: .value("环境", p.provider.displayName))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let hoverDay {
                RuleMark(x: .value("日期", hoverDay, unit: .day))
                    .foregroundStyle(Theme.gray500.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(data.hits(on: hoverDay)) { p in
                    PointMark(x: .value("日期", p.day, unit: .day), y: .value("值", data.value(p)))
                        .symbol {
                            // 2px 载体色描环，让标记点压在线上时仍然可读
                            Circle().fill(p.provider.accent)
                                .overlay(Circle().stroke(Theme.cardBackground, lineWidth: 2))
                                .frame(width: 9, height: 9)
                        }
                }
            }
        }
        .chartForegroundStyleScale(domain: data.providers.map(\.displayName), range: data.providers.map(\.accent))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(8, store.rangeDayCount))) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(Formatters.shortDay(d)).font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.gridline)
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(data.axisLabel(d)).font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let x = loc.x - geo[plotFrame].origin.x
                            guard let d: Date = proxy.value(atX: x) else { return }
                            // onContinuousHover 每次鼠标移动都会回调，这里只在「换了那一天」时才写状态：
                            // 每帧都赋值会把动画反复打断，看着反而更抖。
                            let day = Calendar.current.startOfDay(for: d)
                            if hoverDay != day { hoverDay = day }
                        case .ended:
                            hoverDay = nil
                        }
                    }
                if let plotFrame = proxy.plotFrame {
                    // 提示卡自己带一小段淡入/位移动画（`.animation(value:)` 只作用于这棵子树，
                    // 图表本体不受影响）——原来它是硬生生蹦出来的，就是「生硬」的来源。
                    ZStack(alignment: .topLeading) {
                        if let hoverDay, let x = proxy.position(forX: hoverDay) {
                            let px = geo[plotFrame].origin.x + x
                            tooltip(for: hoverDay, data: data)
                                .offset(x: px + 196 > geo.size.width ? px - 196 : px + 12, y: 4)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                        }
                    }
                    .animation(Self.tooltipAnimation, value: hoverDay)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// 悬浮明细：只列当日有值的环境，按值降序，并给出合计 —— 零值行只制造噪声
    private func tooltip(for day: Date, data: ChartData) -> some View {
        let rows = data.hits(on: day).sorted { data.value($0) > data.value($1) }
        let total = rows.reduce(0.0) { $0 + data.value($1) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(Formatters.dayLabel(day)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.gray800)
            if rows.isEmpty {
                Text("当日无用量").font(.system(size: 12)).foregroundStyle(Theme.gray500)
            }
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    Circle().fill(r.provider.accent).frame(width: 7, height: 7)
                    Text(r.provider.displayName).font(.system(size: 12)).foregroundStyle(Theme.gray600)
                    Spacer(minLength: 12)
                    Text(data.format(data.value(r))).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.gray900).monospacedDigit()
                }
            }
            if rows.count > 1 {
                Divider()
                HStack {
                    Text("合计").font(.system(size: 12)).foregroundStyle(Theme.gray600)
                    Spacer(minLength: 12)
                    Text(data.format(total)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.gray900).monospacedDigit()
                }
            }
        }
        .padding(10)
        .frame(width: 184)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

/// 图表输入的一次性整理：参与绘制的环境、按环境筛过的点、按天索引的点。
///
/// 之前这三样都是计算属性，一个 body 里被引用十几次，每次都对全部点位重扫一遍；
/// 悬浮时的 `Calendar.isDate` 更是每次鼠标移动都要跑几百遍 —— 这是掉帧的一部分来源。
private struct ChartData {
    let providers: [ProviderKind]
    let series: [DailyPoint]
    /// 按「当天 0 点」索引，鼠标移到哪天就取哪天的，不再全量过滤 + 日历比较
    private let byDay: [Date: [DailyPoint]]
    private let metric: Metric

    init(points: [DailyPoint], metric: Metric) {
        self.metric = metric
        let active = ProviderKind.allCases.filter { k in points.contains { $0.provider == k && Self.rawValue($0, metric) > 0 } }
        self.providers = active
        self.series = points.filter { active.contains($0.provider) }
        self.byDay = Dictionary(grouping: series) { Calendar.current.startOfDay(for: $0.day) }
    }

    func value(_ p: DailyPoint) -> Double { Self.rawValue(p, metric) }
    private static func rawValue(_ p: DailyPoint, _ m: Metric) -> Double { m == .tokens ? Double(p.tokens) : p.cost }

    /// 当天有值的点，降序 —— 零值行只制造噪声
    func hits(on day: Date) -> [DailyPoint] {
        (byDay[Calendar.current.startOfDay(for: day)] ?? []).filter { value($0) > 0 }
    }

    func axisLabel(_ v: Double) -> String { metric == .tokens ? Formatters.tokens(Int(v)) : Formatters.cost(v) }
    func format(_ v: Double) -> String { metric == .tokens ? Formatters.tokens(Int(v)) : Formatters.cost(v) }
}
