import SwiftUI
import AppKit

/// 视觉基线：对齐 cloud-number-admin-web-pro 的 z-card 与灰阶变量（明暗两套）。
///
/// 序列色（`series`）为 8 槽固定分类色板，已用 dataviz 校验器在本 App 实际载体底色上
/// 通过全部硬门槛（明暗自适应）：
///   - 亮度带、彩度下限、相邻色 CVD ΔE（最差 9.1 亮 / 8.4 暗，≥8）、常规视觉 ΔE（最差 19.6 / 19.3，≥15）
///   - 亮色底上有 3 个槽位对比度低于 3:1（aqua/yellow/magenta），按「救助规则」必须
///     同时提供可见文字标签或表格视图 —— 本 App 的「用量明细」表即为表格孪生体。
enum Theme {
    /// 8 槽分类色板：明暗自适应，顺序即校验顺序，**不可重排**
    static let series: [Color] = [
        dynamic(light: NSColor(hex: 0x5D87FF), dark: NSColor(hex: 0x5D87FF)), // 1 blue（品牌）
        dynamic(light: NSColor(hex: 0xEB6834), dark: NSColor(hex: 0xD95926)), // 2 orange
        dynamic(light: NSColor(hex: 0x1BAF7A), dark: NSColor(hex: 0x199E70)), // 3 aqua
        dynamic(light: NSColor(hex: 0xEDA100), dark: NSColor(hex: 0xC98500)), // 4 yellow
        dynamic(light: NSColor(hex: 0xE87BA4), dark: NSColor(hex: 0xD55181)), // 5 magenta
        dynamic(light: NSColor(hex: 0x008300), dark: NSColor(hex: 0x008300)), // 6 green
        dynamic(light: NSColor(hex: 0x4A3AA7), dark: NSColor(hex: 0x9085E9)), // 7 violet
        dynamic(light: NSColor(hex: 0xE34948), dark: NSColor(hex: 0xE66767)), // 8 red
    ]

    /// 第 9 个及以后的序列不生成新色，统一归入「其他」中性灰
    static let seriesOther = dynamic(light: NSColor(hex: 0x949EB7), dark: NSColor(hex: 0x73738C))

    /// 兼容旧调用点：品牌强调色（非序列身份，不承担图表语义）
    static let chartColors: [Color] = series

    static let primary = Color(hex: 0x5D87FF)
    static let primarySoft = primary.opacity(0.1)

    // 页面底 / 卡片底 / 卡片边框（--default-bg-color / --default-box-color / --z-card-border）
    static let pageBackground = dynamic(light: NSColor(hex: 0xF5F7FA), dark: NSColor(hex: 0x141417))
    static let cardBackground = dynamic(light: .white, dark: NSColor(hex: 0x1E1E23))
    static let cardBorder = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
    static let hover = dynamic(light: NSColor(hex: 0xEDEFF0), dark: NSColor(hex: 0x2A2A33))
    static let divider = dynamic(light: NSColor(hex: 0xF2F4F5), dark: NSColor(hex: 0x23232A))
    static let segmentBackground = dynamic(light: NSColor(hex: 0xE9EDF3), dark: NSColor(hex: 0x2A2A33))
    static let tableHeader = dynamic(light: NSColor(hex: 0xF9FAFB), dark: NSColor(hex: 0x23232A))

    // 输入控件的底与边（设置页的输入框、多行编辑器）。
    // 卡片本来就是白的，输入框再白一层就分不出边界 —— 所以填一档比卡片**浅**的底（深色下反过来，比卡片亮），
    // 再补一道比 `cardBorder` 略重的边：这一道要说的不是「这里有个卡片」而是「这里可以打字」。
    static let fieldBackground = dynamic(light: NSColor(hex: 0xF8F9FB), dark: NSColor(hex: 0x25252C))
    static let fieldBorder = dynamic(light: NSColor(hex: 0xDCE0E8), dark: NSColor(hex: 0x3A3A44))

    // 设置窗口的两列。侧栏底色比页面底各**深/浅一档**：这样两列不用硬边框就分得开，
    // 而深色下侧栏比内容略亮，与 macOS 对「这一列是窗口镶边」的读法一致。
    static let sidebarBackground = dynamic(light: NSColor(hex: 0xF0F2F5), dark: NSColor(hex: 0x18181C))
    /// 设置窗口里那条竖分隔线。比 `cardBorder` 略重一点 —— 它要分开的是两个面，不是卡片的边。
    static let paneDivider = dynamic(light: NSColor(hex: 0xE6E9EF), dark: NSColor(hex: 0x2A2A33))

    // 图表 chrome：网格与轴是实线发丝线（禁用虚线），各比载体深一档，保持退让
    static let gridline = dynamic(light: NSColor(hex: 0xEDEFF3), dark: NSColor(hex: 0x2E2E36))
    static let axisLine = dynamic(light: NSColor(hex: 0xDFE3EA), dark: NSColor(hex: 0x3A3A44))
    static let muted = dynamic(light: NSColor(hex: 0x949EB7), dark: NSColor(hex: 0x8A8A9C))

    // 灰阶（--z-gray-500/600/700/800/900）
    static let gray500 = dynamic(light: NSColor(hex: 0x949EB7), dark: NSColor(hex: 0x73738C))
    static let gray600 = dynamic(light: NSColor(hex: 0x7987A1), dark: NSColor(hex: 0x8F8FA3))
    static let gray700 = dynamic(light: NSColor(hex: 0x4D5875), dark: NSColor(hex: 0xABABBA))
    static let gray800 = dynamic(light: NSColor(hex: 0x383853), dark: NSColor(hex: 0xC7C7D1))
    static let gray900 = dynamic(light: NSColor(hex: 0x323251), dark: NSColor(hex: 0xE3E3E8))

    // 状态色：保留语义，绝不复用为「第 N 个序列」
    static let statusGood = dynamic(light: NSColor(hex: 0x0CA30C), dark: NSColor(hex: 0x0CA30C))
    static let statusWarning = dynamic(light: NSColor(hex: 0xFAB219), dark: NSColor(hex: 0xFAB219))
    static let statusSerious = dynamic(light: NSColor(hex: 0xEC835A), dark: NSColor(hex: 0xEC835A))
    static let statusCritical = dynamic(light: NSColor(hex: 0xD03B3B), dark: NSColor(hex: 0xD03B3B))

    /// 环比文字色：升/降各一档，保证在浅底与深底都读得清
    static let deltaUp = dynamic(light: NSColor(hex: 0x006300), dark: NSColor(hex: 0x0CA30C))
    static let deltaDown = dynamic(light: NSColor(hex: 0xB03A2E), dark: NSColor(hex: 0xE66767))

    static let cardRadius: CGFloat = 12

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// z-card：白底 + 1px 边框 + 圆角 + 极浅阴影
struct CardModifier: ViewModifier {
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
    }
}

extension View {
    func card(padding: CGFloat = 20) -> some View { modifier(CardModifier(padding: padding)) }

    /// 表格列与轴刻度专用：等宽数字，保证纵向对齐。
    /// 大号独立数字（KPI 值）不要用，等宽会让 121 这类数字显得松散。
    func tabularNumbers() -> some View { monospacedDigit() }
}

/// z-chart-card__header：h4 16px/600 + 12px 灰色说明
struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.gray800)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.gray500)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension ProviderKind {
    /// 环境序列色：按固定槽位分配给实体，**不随排名或筛选变化**（筛掉一个不会让其余重新着色）。
    /// 色板仅 8 槽；第 9 个及以后归入中性灰「其他」，不生成新色相。
    var accent: Color {
        switch self {
        case .codex: return Theme.series[0]
        case .codexCLI: return Theme.series[1]
        case .claudeCode: return Theme.series[2]
        case .devin: return Theme.series[3]
        case .cursor: return Theme.series[4]
        case .windsurf: return Theme.series[5]
        case .antigravity: return Theme.series[6]
        case .qoder: return Theme.series[7]
        case .trae, .codebuddy: return Theme.seriesOther
        }
    }
}
