import SwiftUI

/// 日期范围胶囊：显示 起 → 止 · N 天，点击弹出预设 + 双月历。
/// 弹出状态由外层持有 —— 快捷档位条上的「自定义」也要能拉起同一个弹层。
struct DateRangePill: View {
    @EnvironmentObject var store: UsageStore
    @Binding var showPopover: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.gray500)
            Text(Formatters.dayLabel(store.rangeStart)).font(.system(size: 12.5, weight: .medium, design: .rounded))
            Text("→").font(.system(size: 12)).foregroundStyle(Theme.gray500)
            Text(Formatters.dayLabel(store.rangeEnd)).font(.system(size: 12.5, weight: .medium, design: .rounded))
            // 天数固定宽度：不然「· 7 天」和「· 365 天」差两位数，胶囊宽度就会变，
            // 右边的快捷档位条跟着左右平移。日期本身是定长的（yyyy-MM-dd），所以钉住这一格整条就稳了。
            // 50pt 是按最长的内置档位量的：「· 365 天」47.4pt —— 原先的 46pt 差 1.4pt，
            // 结果「近一年」一选中这行就折成两行，整条筛选栏跟着变高。
            // 再长的只可能来自自定义范围，用缩小字号兜底，绝不允许换行。
            Text("· \(store.rangeDayCount) 天")
                .font(.system(size: 12)).foregroundStyle(Theme.gray500)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: 50, alignment: .leading)
            Image(systemName: showPopover ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.gray500)
        }
        .foregroundStyle(Theme.gray800)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(showPopover ? Theme.primary : Theme.cardBorder, lineWidth: showPopover ? 1.5 : 1))
        .shadow(color: showPopover ? Theme.primary.opacity(0.15) : .black.opacity(0.03), radius: showPopover ? 0 : 1.5, y: showPopover ? 0 : 1)
        .overlay { if showPopover { RoundedRectangle(cornerRadius: 9).stroke(Theme.primary.opacity(0.15), lineWidth: 6).padding(-3) } }
        .contentShape(Rectangle())
        .onTapGesture { showPopover.toggle() }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DateRangePopover(start: store.rangeStart, end: store.rangeEnd) { s, e in
                store.setRange(start: s, end: e)
                showPopover = false
            }
        }
    }
}

// MARK: - 弹层

private enum RangePreset: CaseIterable, Identifiable {
    case today, yesterday, d7, d30, d90, thisMonth, lastMonth, thisYear
    var id: Self { self }
    var label: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .d7: return "近7天"
        case .d30: return "近30天"
        case .d90: return "近90天"
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .thisYear: return "本年"
        }
    }
    var range: (Date, Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: today)! }
        switch self {
        case .today: return (today, today)
        case .yesterday: return (daysAgo(1), daysAgo(1))
        case .d7: return (daysAgo(6), today)
        case .d30: return (daysAgo(29), today)
        case .d90: return (daysAgo(89), today)
        case .thisMonth:
            return (cal.date(from: cal.dateComponents([.year, .month], from: today))!, today)
        case .lastMonth:
            let first = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            let lastMonthFirst = cal.date(byAdding: .month, value: -1, to: first)!
            return (lastMonthFirst, cal.date(byAdding: .day, value: -1, to: first)!)
        case .thisYear:
            return (cal.date(from: cal.dateComponents([.year], from: today))!, today)
        }
    }
}

struct DateRangePopover: View {
    @State private var start: Date
    @State private var end: Date?
    @State private var rightMonth: Date
    @State private var hoverDay: Date?
    let onApply: (Date, Date) -> Void
    @Environment(\.dismiss) private var dismiss

    private let cal = Calendar.current

    init(start: Date, end: Date, onApply: @escaping (Date, Date) -> Void) {
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _rightMonth = State(initialValue: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: end))!)
        self.onApply = onApply
    }

    private var leftMonth: Date { cal.date(byAdding: .month, value: -1, to: rightMonth)! }
    private var today: Date { cal.startOfDay(for: Date()) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            presets
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(alignment: .trailing, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    MonthGrid(month: leftMonth, start: start, end: end ?? hoverDay, today: today, showPrev: true, showNext: false,
                              onNav: { rightMonth = cal.date(byAdding: .month, value: $0, to: rightMonth)! }, onPick: pick, onHover: { hoverDay = $0 })
                    MonthGrid(month: rightMonth, start: start, end: end ?? hoverDay, today: today, showPrev: false, showNext: true,
                              onNav: { rightMonth = cal.date(byAdding: .month, value: $0, to: rightMonth)! }, onPick: pick, onHover: { hoverDay = $0 })
                }
                HStack(spacing: 8) {
                    Text(summary).font(.system(size: 11)).foregroundStyle(Theme.gray500)
                    Spacer()
                    SmallButton(title: "取消") { dismiss() }
                    SmallButton(title: "应用", primary: true) { onApply(start, end ?? start) }
                        .disabled(end == nil)
                        .opacity(end == nil ? 0.5 : 1)
                }
            }
        }
        .padding(16)
        .background(Theme.cardBackground)
    }

    private var summary: String {
        guard let end else { return "请选择结束日期" }
        let n = (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return "\(Formatters.dayLabel(start)) → \(Formatters.dayLabel(end)) · \(n) 天"
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RangePreset.allCases) { p in
                let (s, e) = p.range
                let active = end != nil && s == start && e == end
                Text(p.label)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Theme.primary : Theme.gray700)
                    .padding(.horizontal, 10)
                    .frame(width: 108, height: 28, alignment: .leading)
                    .background(active ? Theme.primarySoft : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        start = s; end = e
                        rightMonth = cal.date(from: cal.dateComponents([.year, .month], from: e))!
                    }
            }
        }
    }

    private func pick(_ day: Date) {
        guard day <= today else { return }
        if end == nil {
            if day < start { end = start; start = day } else { end = day }
        } else {
            start = day; end = nil
        }
    }
}

/// 单月网格
private struct MonthGrid: View {
    let month: Date
    let start: Date
    let end: Date?
    let today: Date
    let showPrev: Bool
    let showNext: Bool
    let onNav: (Int) -> Void
    let onPick: (Date) -> Void
    let onHover: (Date?) -> Void

    private let cal = Calendar.current
    private let cell: CGFloat = 28
    private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private static let titleFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy 年 M 月"; return f }()

    private var days: [Date?] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let count = cal.range(of: .day, in: .month, for: first)!.count
        let weekday = (cal.component(.weekday, from: first) + 5) % 7 // 周一为 0
        var out = [Date?](repeating: nil, count: weekday)
        for d in 0..<count { out.append(cal.date(byAdding: .day, value: d, to: first)!) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                navButton("chevron.left", visible: showPrev) { onNav(-1) }
                Spacer()
                Text(Self.titleFormatter.string(from: month)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.gray800)
                Spacer()
                navButton("chevron.right", visible: showNext) { onNav(1) }
            }
            .frame(width: cell * 7)
            HStack(spacing: 0) {
                ForEach(Self.weekdays, id: \.self) { w in
                    Text(w).font(.system(size: 11)).foregroundStyle(Theme.gray500).frame(width: cell, height: 18)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: 7), spacing: 2) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(width: cell, height: cell) }
                }
            }
            .frame(height: cell * 6 + 10, alignment: .top)
        }
    }

    private func navButton(_ name: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.gray500)
            .frame(width: 20, height: 20).contentShape(Rectangle())
            .opacity(visible ? 1 : 0).onTapGesture { if visible { action() } }
    }

    private func dayCell(_ day: Date) -> some View {
        let lo = min(start, end ?? start), hi = max(start, end ?? start)
        let inRange = end != nil && day > lo && day < hi
        let isEdge = day == lo || day == hi
        let future = day > today
        let isToday = day == today
        return Text("\(cal.component(.day, from: day))")
            .font(.system(size: 11.5, weight: isEdge || isToday ? .bold : .regular, design: .rounded))
            .foregroundStyle(isEdge ? .white : future ? Theme.gray500.opacity(0.4) : isToday ? Theme.primary : Theme.gray800)
            .frame(width: cell, height: cell)
            .background {
                if inRange { Rectangle().fill(Theme.primarySoft).padding(.vertical, 2) }
                if isEdge { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.primary).padding(1) }
            }
            .contentShape(Rectangle())
            .onTapGesture { onPick(day) }
            .onHover { onHover($0 && !future ? day : nil) }
    }
}
