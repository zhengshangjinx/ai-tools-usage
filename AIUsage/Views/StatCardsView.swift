import SwiftUI

/// 4 张 KPI 卡：处理 Tokens / 估算费用 / 会话数 / 缓存命中率
///
/// 环比徽标用**方向色**（升/降），取状态色而非序列色 —— 序列色只用来表达身份，
/// 拿它当状态用会让读者以为「绿色 = 某个环境」。
struct StatCardsView: View {
    @EnvironmentObject var store: UsageStore

    private struct Item: Identifiable {
        let label: String
        let value: String
        var trend: (text: String, up: Bool)? = nil
        /// B/M 之外的第二单位小字（亿 / 万）
        var alt: String? = nil
        let sub: String
        let icon: String
        let color: Color
        var id: String { label }
    }

    private var items: [Item] {
        let t = store.snapshot.totals
        let prev = store.snapshot.previous
        let inputTotal = t.cachedInput + t.uncachedInput + t.cacheWrite
        let hitRate = inputTotal == 0 ? 0 : Double(t.cachedInput) / Double(inputTotal)
        let days = store.rangeDayCount
        return [
            Item(label: "处理 Tokens", value: Formatters.tokens(t.processed),
                 trend: Self.delta(t.processed, prev.processed), alt: Formatters.tokensCN(t.processed),
                 sub: "较前 \(days) 天",
                 icon: "sum", color: Theme.series[0]),
            Item(label: "估算费用", value: Formatters.cost(t.cost),
                 trend: Self.delta(t.cost, prev.cost),
                 sub: t.unpricedTokens > 0 ? "未计价 \(Formatters.percent(t.unpricedShare)) · \(Formatters.tokens(t.unpricedTokens)) tokens" : "较前 \(days) 天",
                 icon: "dollarsign", color: Theme.series[3]),
            Item(label: "会话数", value: "\(t.sessions)",
                 trend: t.sessions - prev.sessions == 0 ? nil : ("\(t.sessions - prev.sessions > 0 ? "▲" : "▼") \(abs(t.sessions - prev.sessions))", t.sessions >= prev.sessions),
                 sub: "较前 \(days) 天", icon: "ellipsis.bubble", color: Theme.series[2]),
            Item(label: "缓存命中率", value: Formatters.percent(hitRate),
                 sub: "节省 \(Formatters.cost(t.cacheSavings)) · 相比全价输入", icon: "bolt.fill", color: Theme.series[5]),
        ]
    }

    private static func delta(_ cur: Int, _ prev: Int) -> (String, Bool)? { delta(Double(cur), Double(prev)) }
    private static func delta(_ cur: Double, _ prev: Double) -> (String, Bool)? {
        guard prev > 0 else { return nil }
        let r = (cur - prev) / prev
        let pct = abs(r) >= 10 ? String(format: "%.0f×", cur / prev) : Formatters.percent(abs(r))
        return ("\(r >= 0 ? "▲" : "▼") \(pct)", r >= 0)
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items) { StatCard(item: $0) }
        }
    }

    private struct StatCard: View {
        let item: Item
        @State private var hovering = false

        var body: some View {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    // 右上角图标只压得到标题和数值这两行（它在卡片顶部 40pt 里，副标题那行在 90 往下），
                    // 所以让位只给这两行。整块都留 52pt 的话，最长那档副标题
                    // 「未计价 100.0% · 175.4B tokens」在 1240 宽下会被截成省略号。
                    Group {
                        Text(item.label).font(.system(size: 12.5)).foregroundStyle(Theme.gray600)
                        // 大号独立数字保持比例数字（非等宽）：等宽会让 121 这类数字显得松散
                        Text(item.value)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.gray900)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.top, 6)
                            .contentTransition(.numericText())
                    }
                    .padding(.trailing, 52)
                    // 固定占位：只有第一张卡有第二单位，不占位会让四张卡的基线错开
                    AltUnit(text: item.alt)
                        .frame(height: 13, alignment: .leading)
                        .padding(.top, 1)
                    HStack(spacing: 6) {
                        if let trend = item.trend {
                            Text(trend.text)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(trend.up ? Theme.deltaUp : Theme.deltaDown)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background((trend.up ? Theme.statusGood : Theme.statusCritical).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        Text(item.sub).font(.system(size: 12)).foregroundStyle(Theme.gray500).lineLimit(1)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: item.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(item.color)
                    .frame(width: 40, height: 40)
                    .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(height: 118)
            .card(padding: 0)
            .offset(y: hovering ? -2 : 0)
            .animation(.easeOut(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
        }
    }
}
