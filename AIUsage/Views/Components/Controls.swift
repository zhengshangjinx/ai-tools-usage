import SwiftUI

/// 自绘分段控件：浅灰槽 + 白色滑块。Tokens/费用、按设备/按模型/按日期、日期档位条共用一套。
///
/// 选中块是**一整块滑过去的底板**，不是各格自己显隐。格子定宽、间距固定，
/// 落点直接算得出来（`3 + index * (itemWidth + 2)`），不需要 matchedGeometryEffect 去量。
///
/// 动画只挂在这块底板上（`.animation(_:value:)` 的作用域限于它这棵子树），点按本身
/// **不再包 `withAnimation`**。早先那样写，动画会罩住这次状态变化引发的**整页**布局差异 ——
/// 包括下方表格从 2 行变 90 行的高度变化，在 ScrollView 里动画一个大幅度的尺寸变化，
/// 就是肉眼可见的抖动/闪动。现在的口径是「底板滑过去，内容直接换」。
struct SegmentedControl<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var itemWidth: CGFloat = 62
    var height: CGFloat = 30
    var style: Style = .neutral

    enum Style {
        /// 浅灰槽 + 白色滑块：标题栏的指标切换、明细表的维度切换
        case neutral
        /// 白底描边槽 + 主色滑块：日期档位条
        case accent
    }

    private static var pillAnimation: Animation { .spring(response: 0.28, dampingFraction: 0.78) }

    private var selectedIndex: Int { options.firstIndex { $0.0 == selection } ?? 0 }
    private var innerHeight: CGFloat { height - 6 }
    private var fontSize: CGFloat { style == .accent ? 12.5 : 12 }

    var body: some View {
        ZStack(alignment: .leading) {
            pill
            HStack(spacing: 2) {
                ForEach(options, id: \.0) { value, label in
                    Text(label)
                        .font(.system(size: fontSize, weight: labelWeight(value)))
                        .foregroundStyle(labelColor(value))
                        .frame(width: itemWidth, height: innerHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = value }
                }
            }
            .padding(3)
        }
        .background(track)
    }

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Group {
            switch style {
            case .neutral:
                shape.fill(Theme.cardBackground).shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            case .accent:
                shape.fill(Theme.primary)
            }
        }
        .frame(width: itemWidth, height: innerHeight)
        .offset(x: 3 + CGFloat(selectedIndex) * (itemWidth + 2))
        .animation(Self.pillAnimation, value: selectedIndex)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var track: some View {
        switch style {
        case .neutral:
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.segmentBackground)
        case .accent:
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.cardBorder))
                .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
        }
    }

    private func labelWeight(_ v: T) -> Font.Weight {
        switch style {
        case .neutral: return v == selection ? .semibold : .medium
        case .accent: return v == selection ? .medium : .regular
        }
    }

    private func labelColor(_ v: T) -> Color {
        if v == selection { return style == .accent ? .white : Theme.gray900 }
        return Theme.gray600
    }
}

/// 日期档位条的选项：内置档位 + 常驻的「自定义」入口
enum QuickRangeItem: Hashable {
    case range(QuickRange)
    /// 自定义范围：点它拉起日期弹层，本身不是一个范围
    case custom

    var label: String {
        switch self {
        case .range(let q): return q.label
        case .custom: return "自定义"
        }
    }

    static var allCases: [QuickRangeItem] { QuickRange.allCases.map(QuickRangeItem.range) + [.custom] }
}

/// 快捷档位条：和标题栏的指标切换、明细表的维度切换共用同一块滑动底板。
///
/// 选中态由 `selection` 表达：当前范围恰好等于某个内置档位就是它，手动改过日期则是 `.custom`
/// —— 「自定义」是个真入口（外层绑定的 set 会拉开日期弹层），不是纯状态标记。
struct QuickRangeBar: View {
    @Binding var selection: QuickRangeItem

    /// 格子必须定宽才算得出滑块落点。68pt = 最宽的「近30天」（12.5pt 下实测 44.2pt）两侧各留 11.9pt。
    /// 原先每格按文字宽度自适应，长短不一（「今日」24.8pt vs「近30天」44.2pt），滑块就没法算位置。
    /// 代价是 8 格总宽比自适应时多约 40pt，1180pt 窗口下仍然宽松放得下。
    private static let itemWidth: CGFloat = 68

    var body: some View {
        SegmentedControl(options: QuickRangeItem.allCases.map { ($0, $0.label) },
                         selection: $selection,
                         itemWidth: Self.itemWidth, height: 34, style: .accent)
    }
}

/// 白底圆角图标按钮。`size` 默认 32 —— 环境行/设备行那两个入口是 32（挨着 30pt 的 chips）；
/// 筛选区第一行整体是 34（日期胶囊与档位条决定的），那里的按钮要跟着 34 才在同一条水平线上。
/// 图标按钮的「底」：圆角白底、细边、悬停变灰。`IconButton` 与 `MenuIconButton` 共用 ——
/// 两个按钮并排站着却长得不一样，比少一个功能还刺眼。
struct IconChrome: ViewModifier {
    var size: CGFloat
    var disabled = false
    var hovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(disabled ? Theme.gray500 : Theme.gray600)
            .frame(width: size, height: size)
            .background(hovering ? Theme.hover : Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.cardBorder))
            .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var disabled = false
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).modifier(IconChrome(size: size, disabled: disabled, hovering: hovering))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// 与 `IconButton` 同款外观，但点开是一个菜单。给导出按钮用 ——
/// 三个格式塞进一个下拉，比在筛选行上再排三个按钮省地方。
struct MenuIconButton<Content: View>: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 32
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemName).modifier(IconChrome(size: size, hovering: hovering))
        }
        .menuStyle(.borderlessButton)
        // 菜单默认自带一个小箭头，会把图标挤得偏离中心；这排按钮的视觉基准是图标居中
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .onHover { hovering = $0 }
    }
}

extension View {
    /// 条件式选中：`.textSelection` 是泛型（enabled / disabled 是两个不同类型），
    /// 三元表达式过不了编译，只能靠这个包一层。
    @ViewBuilder func textSelectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { self }
    }
}

/// 筛选 chip：圆点 + 名称 + 可选计数，未选中半透明。
/// 环境行和设备行共用一套 —— 两行的交互语义本来就一样（全部=汇总，点单项=只看它），长得也该一样。
struct FilterChip: View {
    let title: String
    let color: Color
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static var selectionAnimation: Animation { .spring(response: 0.26, dampingFraction: 0.82) }
    private static var hoverAnimation: Animation { .easeOut(duration: 0.12) }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.gray700)
            if let count {
                Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.gray500)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // fixedSize：宁可让外层换行，也不让文字被压成两行省略号
        .fixedSize()
        .background(selected ? Theme.cardBackground : Color.clear, in: Capsule())
        .overlay(Capsule().stroke(Theme.cardBorder))
        .shadow(color: .black.opacity(selected ? 0.03 : 0), radius: 1.5, y: 1)
        // 选中/取消是底色与不透明度的过渡，不带尺寸变化 —— 一旦动到尺寸，外层 FlowLayout
        // 就要重排整行，chip 会跳着换行，反而更乱。两个 value 各挂一个作用域动画。
        .opacity(selected ? 1 : (hovering ? 0.75 : 0.5))
        .animation(Self.selectionAnimation, value: selected)
        .animation(Self.hoverAnimation, value: hovering)
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

/// 主数值下方的第二单位小字。B/M 旁边补一行「多少亿」，让量级一眼可读。
/// 没有可读的中文量级时整行不占位。
struct AltUnit: View {
    let text: String?
    var size: CGFloat = 10.5

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(Theme.gray500)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

/// 卡片小按钮（弹层底部 取消 / 应用）
struct SmallButton: View {
    let title: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .medium : .regular))
                .foregroundStyle(primary ? .white : Theme.gray700)
                .frame(width: 60, height: 28)
                .background(primary ? Theme.primary : Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(primary ? Color.clear : Theme.cardBorder))
        }
        .buttonStyle(.plain)
    }
}
