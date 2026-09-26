import SwiftUI
import Charts

/// 环境分布环形卡：扇环 + 中心汇总 + 图例。
///
/// 这里修掉的一个真问题：环上画的是**所有**有值的环境，图例却只列前 4 行，
/// 第 5 个环境在环上有扇区却无从辨认。现在环与图例共用同一份分段：
/// 前 4 名 + 「其他」（中性灰，不生成第 9 个色相），零值的「仅会话」环境
/// 单独用一行说明，不再让环与图例各说各话。
///
/// 悬浮层（dataviz 规范里图表默认要有的一层）：环和图例互为高亮 ——
/// 指到哪个扇区，中心数字就换成那个环境的值，其余扇区退到 32%，
/// 对应图例行同时高亮。指图例也一样。中心读数比跟随鼠标的气泡更好读，
/// 视线不用离开环形去找数字。
struct DistributionView: View {
    @EnvironmentObject var store: UsageStore
    /// 当前悬浮的分段 id（环境 rawValue 或 "other"）；nil = 没悬浮
    @State private var hovered: String?
    /// 这张卡自己的指标口径，跟每日趋势那张卡各管各的（理由见 DailyChartView.metric）。
    /// 默认 Tokens：环上算的是「占多少」，token 是原始单位。
    @State private var metric: Metric = .tokens

    private static let maxSegments = 4
    /// 相邻扇区之间留 2px 载体色缝隙来分隔
    private static let gap: CGFloat = 2
    private static let hoverAnimation = Animation.easeOut(duration: 0.12)
    /// 非悬浮扇区退到的透明度：够看出「被压下去了」，又不至于读不出来
    private static let dimmed: Double = 0.32

    /// 环上的一段：前 4 名环境各一段，「其他」合成一段
    private struct Segment: Identifiable {
        let id: String
        let title: String
        let color: Color
        let value: Double
        let sessions: Int
    }

    /// 一次算好整张卡要用的全部派生数据（等价于折线卡里的 ChartData）：
    /// 这些在 body 里被引用近十次，每次重算都是对全部环境的全量扫描。
    private struct RingData {
        /// 一个环境都没有：连「仅会话」都没得说，整张卡才走空状态
        let isEmpty: Bool
        let segments: [Segment]
        /// 本地数据加密、只有会话数、环上画不出来的那些环境
        let sessionsOnly: [ProviderSummary]
        let metric: Metric

        init(providers: [ProviderSummary], metric: Metric) {
            func v(_ p: ProviderSummary) -> Double { metric == .tokens ? Double(p.tokens) : p.cost }
            self.metric = metric
            self.isEmpty = providers.isEmpty
            let valued = providers.filter { v($0) > 0 }
            var segs = valued.prefix(DistributionView.maxSegments).map {
                Segment(id: $0.kind.rawValue, title: $0.kind.displayName, color: $0.kind.accent,
                        value: v($0), sessions: $0.sessionCount)
            }
            let tail = valued.dropFirst(DistributionView.maxSegments)
            let tailValue = tail.reduce(0) { $0 + v($1) }
            if tailValue > 0 {
                // 第 9 个及以后不生成新色相，统一并进中性灰的「其他」
                segs.append(Segment(id: "other", title: "其他 \(tail.count) 个环境", color: Theme.seriesOther,
                                    value: tailValue, sessions: tail.reduce(0) { $0 + $1.sessionCount }))
            }
            self.segments = segs
            self.sessionsOnly = providers.filter { v($0) == 0 && $0.sessionCount > 0 }
        }

        var segmentIds: [String] { segments.map(\.id) }
        var segmentTotal: Double { segments.reduce(0) { $0 + $1.value } }
        func display(_ v: Double) -> String { metric == .tokens ? Formatters.tokens(Int(v)) : Formatters.cost(v) }
    }

    var body: some View {
        let data = RingData(providers: store.snapshot.providers, metric: metric)
        VStack(alignment: .leading, spacing: 12) {
            // 这张卡只有 340pt 宽，标题 + 副标题 + 开关刚好排满：副标题因此省掉了指标名
            // （开关上写着），只说这张卡在看什么。多一个字都会把副标题挤成省略号。
            CardHeader("环境分布", subtitle: "范围内各环境占比") {
                SegmentedControl(options: Metric.allCases.map { ($0, $0.rawValue) },
                                 selection: $metric, itemWidth: 54, height: 26)
            }
            if data.isEmpty {
                Text("所选范围内暂无数据")
                    .font(.system(size: 13)).foregroundStyle(Theme.gray500)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ring(data).frame(height: 122).frame(maxWidth: .infinity)
                legend(data)
                Spacer(minLength: 0)
            }
        }
        .card()
        .frame(height: 336)
        // 鼠标离开整张卡时清掉悬浮，避免指针走了环还停在退让状态
        .onHover { if !$0 { hovered = nil } }
        // 分段集合变了（切指标 / 换范围）也清一次：留着一个已经不存在的 id
        // 会让整圈都停在退让态，看着像坏了
        .onChange(of: data.segmentIds) { _, _ in hovered = nil }
    }

    private func ring(_ data: RingData) -> some View {
        Chart {
            ForEach(data.segments) { s in
                SectorMark(angle: .value("值", s.value), innerRadius: .ratio(0.76), angularInset: Self.gap)
                    .cornerRadius(2)
                    .foregroundStyle(s.color)
                    .opacity(segmentOpacity(s.id))
            }
        }
        .chartLegend(.hidden)
        .animation(Self.hoverAnimation, value: hovered)
        .chartBackground { _ in
            // 中心读数在「总计」和「当前悬浮的环境」之间切换 —— 这就是饼图的悬浮反馈：
            // 视线本来就在环心，不必再追一个跟着鼠标跑的气泡
            centerReadout(data)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let hit = sector(at: loc, proxy: proxy, geo: geo, data: data)
                            if hovered != hit { hovered = hit }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    /// 命中判定自己算：扇区顺序和占比都是已知的，不依赖 ChartProxy 的角度 API
    /// （那套在 macOS 14 上还要再兜一层版本判断）。Charts 的扇形从 12 点起顺时针排。
    private func sector(at loc: CGPoint, proxy: ChartProxy, geo: GeometryProxy, data: RingData) -> String? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let rect = geo[plotFrame]
        let radius = min(rect.width, rect.height) / 2
        guard radius > 0 else { return nil }
        let dx = loc.x - rect.midX, dy = loc.y - rect.midY
        let dist = (dx * dx + dy * dy).squareRoot()
        // 只认环带本身：中心圆孔和环外都算「没指到」
        guard dist >= radius * 0.70, dist <= radius * 1.08 else { return nil }
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let total = data.segmentTotal
        guard total > 0 else { return nil }
        let fraction = angle / (2 * .pi)
        var acc = 0.0
        for s in data.segments {
            acc += s.value / total
            if fraction < acc { return s.id }
        }
        return data.segments.last?.id
    }

    private func segmentOpacity(_ id: String) -> Double {
        guard let hovered else { return 1 }
        return hovered == id ? 1 : Self.dimmed
    }

    private func centerReadout(_ data: RingData) -> some View {
        let seg = hovered.flatMap { id in data.segments.first { $0.id == id } }
        return VStack(spacing: 1) {
            if let seg {
                Text(seg.title)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray700)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            Text(seg.map { data.display($0.value) } ?? data.display(data.segmentTotal))
                .font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(Theme.gray900)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            // 第二单位顶掉 "Tokens" 这个字：卡片副标题已经写明是 Tokens 占比了
            if let seg {
                Text(data.segmentTotal > 0 ? Formatters.percent(seg.value / data.segmentTotal) : "—")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.gray500).monospacedDigit()
            } else if data.metric == .tokens {
                AltUnit(text: Formatters.tokensCN(Int(data.segmentTotal)), size: 11)
            } else {
                Text("费用").font(.system(size: 11)).foregroundStyle(Theme.gray500)
            }
        }
        .frame(width: 92)
        .animation(Self.hoverAnimation, value: hovered)
    }

    private func legend(_ data: RingData) -> some View {
        VStack(spacing: 6) {
            ForEach(data.segments) { s in
                row(s, total: data.segmentTotal)
            }
            if !data.sessionsOnly.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.gray500)
                    Text("仅会话：" + data.sessionsOnly.map { "\($0.kind.displayName) \($0.sessionCount)" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.gray500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(Self.hoverAnimation, value: hovered)
    }

    /// 图例行同时也是环上那一段的悬浮热区：从图例指进去，环上同样会亮起来
    private func row(_ s: Segment, total: Double) -> some View {
        HStack(spacing: 8) {
            Circle().fill(s.color).frame(width: 8, height: 8)
            Text(s.title).font(.system(size: 12)).foregroundStyle(Theme.gray700).lineLimit(1)
            Text("\(s.sessions) 会话").font(.system(size: 11)).foregroundStyle(Theme.gray500)
            Spacer()
            Text(display(s.value)).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Theme.gray900).monospacedDigit()
            Text(total > 0 ? Formatters.percent(s.value / total) : "—")
                .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.gray500).monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(hovered == s.id ? Theme.tableHeader : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { if $0 { hovered = s.id } else if hovered == s.id { hovered = nil } }
    }

    private func display(_ v: Double) -> String {
        metric == .tokens ? Formatters.tokens(Int(v)) : Formatters.cost(v)
    }
}
