import SwiftUI

// MARK: - 页签模型

/// 设置窗口左侧的五个页。顺序就是侧栏里的顺序，**由 `group` 分组**。
///
/// 用枚举而不是 `TabView`：侧栏要能分组、要在底部钉一行更新提示，
/// 那两件事都不是 `TabView` 的页签表达得了的。
enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case sources, devices, pricing, display, about

    var id: Self { self }

    var title: String {
        switch self {
        case .sources: return "数据源"
        case .devices: return "设备与同步"
        case .pricing: return "模型单价"
        case .display: return "显示与留存"
        case .about: return "关于"
        }
    }

    /// 详情页标题下面那行小字。说清「这一页管什么」，不是重复标题。
    var subtitle: String {
        switch self {
        case .sources: return "每个工具扫哪里，能拿到什么口径"
        case .devices: return "本机身份与 iCloud 档案目录"
        case .pricing: return "LiteLLM 价格表与手动覆盖"
        case .display: return "菜单栏显示什么，本地日志留多久"
        case .about: return "版本、更新与仓库"
        }
    }

    var symbol: String {
        switch self {
        case .sources: return "folder"
        case .devices: return "laptopcomputer.and.iphone"
        case .pricing: return "dollarsign.circle"
        case .display: return "menubar.rectangle"
        case .about: return "info.circle"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .sources, .devices, .pricing: return .data
        case .display, .about: return .general
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case data, general

    var id: Self { self }

    var title: String {
        switch self {
        case .data: return "数据"
        case .general: return "应用"
        }
    }

    var panes: [SettingsPane] { SettingsPane.allCases.filter { $0.group == self } }
}

// MARK: - 详情页外壳

/// 右侧那一页的外框：标题 + 副标题 + 右侧动作槽 + 一条分隔线 + 可滚动的内容。
///
/// **表头留在滚动区外面**，这是它读起来像「一页」而不是「一张长表单」的关键。
/// 所以内容自带滚动容器（交给 `SettingsScroll`，见 `SettingsControls.swift`），
/// 这一层不要再套一个 —— 嵌套滚动容器会让里层的高度算错
/// （`Form` 尤其明显，见 `App.swift` 里那段 `ImageRenderer` 的踩坑记录）。
struct SettingsDetailPage<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.gray900)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.gray500)
                    }
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Rectangle().fill(Theme.paneDivider).frame(height: 1)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.pageBackground)
    }
}

extension SettingsDetailPage where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - 卡片

/// 一节设置。**白卡 + 圆角 + 细边**，直接复用主窗口那套 `.card()` ——
/// 设置页和主界面从此是同一套语言。原先用的 `Form(.grouped)` 在 macOS 14 上给的是
/// **浅灰**卡片，跟主窗口的白卡摆在一起就是「不像一个 App」的来源。
///
/// `footer` 是这一节的说明文字，放在卡片下方而不是卡内：说明是给「想深究的人」看的，
/// 压进卡片会把它变成正文的一部分。
struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, footer: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.gray800)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.gray500)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 18)

            if let footer {
                // `Text(String)` 走的是 `StringProtocol` 那条重载，**不解析 Markdown**；
                // 而这几条说明里用 `**…**` 做强调（原先 `Section(footer: "字面量")` 走的是
                // `LocalizedStringKey`，本来就解析）。包一层把强调找回来 ——
                // 不包的话图上会直接印出两个星号，且不影响构建，只有看图才发现。
                Text(LocalizedStringKey(stringLiteral: footer))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.gray500)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

// MARK: - 行

/// 卡片里的一行：左边定宽标签，右边控件。
///
/// **这是 `Form` 唯一真正给对了的东西**，换成卡片就得自己补回来：没有它，
/// 同一张卡里几个 `Toggle` 的开关会各自贴着不同长度的标签站，左边缘参差不齐。
/// 定宽 92 是照这一批标签里最长的「关闭主窗口后保留在菜单栏」那一类折行后的宽度定的。
struct SettingsRow<Control: View>: View {
    let label: String
    var labelWidth: CGFloat = 92
    /// 说明文字，排在控件下面（副标题的位置），不是标签的延长
    var note: String? = nil
    @ViewBuilder var control: () -> Control

    init(_ label: String, labelWidth: CGFloat = 92, note: String? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.labelWidth = labelWidth
        self.note = note
        self.control = control
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.gray700)
                .frame(width: labelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                control()
                    // 行首已经有标签了，控件自己的标题再画一遍就成了「自动检查　自动检查更新 [开关]」。
                    // **不删控件的标题** —— `labelsHidden` 只影响绘制，VoiceOver 仍然读得到它。
                    // 挂在这一层（而不是逐个 `Toggle` 上）是因为它只是个环境值，会往下传；
                    // 对 `TextField` / `Button` 这类没有独立标签的控件是个无害的空操作。
                    .labelsHidden()
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.gray500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 卡片内的一段说明文字（相当于原来 `Form` 的 footer，但排在卡内某几行之后）。
struct SettingsNote: View {
    let text: String
    var error = false

    init(_ text: String, error: Bool = false) {
        self.text = text
        self.error = error
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(error ? Theme.statusCritical : Theme.gray500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 卡片内一条分隔线。用于把卡片里语义不同的几段分开。
struct SettingsRule: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}
