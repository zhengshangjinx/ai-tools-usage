import SwiftUI

/// 设置页里的输入控件与按钮。
///
/// 存在的理由是一句话：**别再用 AppKit 那套默认外观**。
/// `.textFieldStyle(.roundedBorder)` / `.buttonStyle(.bordered)` 画出来的是内凹白底 + 一圈很重的灰边
/// （按钮还带渐变与描边），摆在自绘的白卡上跟整页不是同一个时代的东西 —— 这是「设置页看着原始」
/// 的全部来源。这里改成跟主窗口同一套语言：细边、圆角、扁平底、悬停才变色，
/// 数字与路径用等宽字体。参考物是 `PricingBrowser` 里那个搜索框，它本来就是对的。
///
/// 尺寸口径也统一在这里：输入框高 26、按钮高 28 —— 与主窗口 30pt 的 chips 是同一族的矮控件，
/// 彼此并排（比如「恢复默认」挨着路径框）不会一高一低。

// MARK: - 滚动容器

/// 设置页的滚动容器：统一的 24pt 页边距 + 浮层滚动条。
///
/// 浮层滚动条不是装饰：macOS 默认那档「根据输入设备自动」在插着鼠标的机器上会给**老式粗滚动条**，
/// 它常驻不退、还要占掉十几 pt 宽度，在一张自绘卡片旁边格外扎眼（主窗口早就为此加了
/// `OverlayScroller`，设置页一直漏着）。五个页共用这一个容器，就不会再漏。
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                content()
            }
            .padding(24)
            // 必须挂在 ScrollView **里面**，见 `OverlayScroller` 开头那段
            .overlayScroller()
        }
    }
}

// MARK: - 输入框外观

/// 输入框的底与边。刻意**不做内阴影**（AppKit 那套靠内阴影表达「这是个可以打字的地方」，
/// 但在这个扁平界面里内阴影只会显脏）：靠一层比卡片浅一档的底 + 一道细边就够读出来了。
private struct FieldChrome: ViewModifier {
    var focused: Bool
    var radius: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(focused ? Theme.primary.opacity(0.7) : Theme.fieldBorder,
                            lineWidth: focused ? 1.5 : 1)
            )
            // 聚焦时补一圈极淡的光晕。只描边不加粗的话，深色模式下这条边几乎看不出来
            .shadow(color: Theme.primary.opacity(focused ? 0.13 : 0), radius: 2.5)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// 单行输入框。`width` 不传就撑满可用宽度（表单里那些「标识」「名称」都是这种）。
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var monospaced = false
    var alignment: TextAlignment = .leading

    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, width: CGFloat? = nil,
         monospaced: Bool = false, alignment: TextAlignment = .leading) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
        self.monospaced = monospaced
        self.alignment = alignment
    }

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .multilineTextAlignment(alignment)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .modifier(FieldChrome(focused: focused))
    }

    @ViewBuilder private var field: some View {
        if let width {
            TextField(placeholder, text: $text).frame(width: width)
        } else {
            TextField(placeholder, text: $text).frame(maxWidth: .infinity)
        }
    }
}

/// 带标签的数字输入框。**标签在框外面**，不像原先那样拿 placeholder 当标签 ——
/// 一旦填了值，placeholder 就没了，一排四个框谁也认不出哪个是哪个。
struct SettingsNumberField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = "0"
    var width: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.gray500)
            // 数字右对齐：跟价格表里那几列一个读法，位数不同也能一眼比大小
            SettingsTextField(placeholder, text: $text, width: width,
                              monospaced: true, alignment: .trailing)
        }
    }
}

/// 多行输入框（数据源那几栏路径）。
///
/// 底层是**自己搭的 `NSTextView`**，没用 SwiftUI 的 `TextEditor`：后者背后的 `NSScrollView`
/// 永远带着一条滚动槽，里面的 `NSTextView` 还会自己画一层白底 —— 在自绘的浅色输入壳里，
/// 右边缘就是一道十几 pt 宽的接缝（`.scrollContentBackground(.hidden)` 只管得到滚动视图，
/// 管不到里面那个 text view；`overlayScroller()` 也接管不了它，因为从外面挂进去的探针
/// 落在 `TextEditor` 之外，往上找到的是整页那个 `ScrollView`）。自己搭一次，
/// 底色、内边距、字体、以及「这么矮的框根本不需要滚动条」就能一次说清。
struct SettingsTextEditor: View {
    @Binding var text: String
    var height: CGFloat = 56

    @State private var focused = false

    var body: some View {
        PathTextEditor(text: $text, focused: $focused)
            .frame(height: height)
            .modifier(FieldChrome(focused: focused))
    }
}

private struct PathTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focused: $focused) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = FocusReportingTextView(frame: .zero)
        textView.onFocusChange = { coordinator.setFocused($0) }
        textView.delegate = coordinator
        textView.drawsBackground = false          // 让壳的底色透上来，别自己铺白
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 7)
        // 路径里出现弯引号、全角破折号、"..." 就是错的，智能替换一律关掉 ——
        // 这类替换平时看不出来，等发现时路径已经被改坏了。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        // 「文字视图放进滚动视图」的标准搭法（NSTextView 默认是按内容撑开的固定宽高，
        // 不写这几行它不会跟着滚动框伸缩）。原来是 `NSTextView.scrollableTextView()` 一句话
        // 搞定，但那个工厂方法造的是 `NSTextView` 本体、换不掉子类 —— 而焦点要靠子类
        // 覆写 `becomeFirstResponder` 才拿得到（见 `FocusReportingTextView`）。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // 关掉滚动条而不是把它调细：这里最多三四行，槽位占掉的那十几 pt 比滚动条本身值钱，
        // 而触控板/滚轮照样能滚（有没有滚动条跟能不能滚是两件事）。
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // 只在外部真的换了内容时回写（比如「恢复默认」）。无脑赋值会把光标顶回开头，
        // 用户每敲一个字就跳一次。
        if textView.string != text { textView.string = text }
    }

    /// 焦点**不能**靠 `NSTextViewDelegate.textDidBeginEditing` 拿：实测它要到**第一次真的输入**
    /// 才发（`makeFirstResponder` 之后是不发的），于是点进输入框时那圈高亮要等到敲下第一个字才亮 ——
    /// 而「点进去就该亮」正是这圈高亮的全部意义。覆写响应链上那两个方法才是准的。
    private final class FocusReportingTextView: NSTextView {
        var onFocusChange: ((Bool) -> Void)?

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocusChange?(true) }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok { onFocusChange?(false) }
            return ok
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let focused: Binding<Bool>

        init(text: Binding<String>, focused: Binding<Bool>) {
            self.text = text
            self.focused = focused
        }

        func setFocused(_ value: Bool) {
            guard focused.wrappedValue != value else { return }
            focused.wrappedValue = value
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

// MARK: - 按钮

/// 扁平按钮。三档：普通（白底细边）、主色（实心蓝，一页只该有一个）、危险（红字）。
/// `compact` 给表格行里那种 24pt 高的位置用 —— 那里塞不进 28pt 的常规按钮。
///
/// 用 `ButtonStyle` 而不是给每个 `Button` 加一堆修饰符：hover 需要 `@State`，
/// 而 `ButtonStyle` 里挂不了状态 —— 所以真正的实现是里面那个私有 `View`（这是唯一稳的写法）。
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case normal, primary, danger }

    var kind: Kind = .normal
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, kind: kind, compact: compact)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool

        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous) }
        private var height: CGFloat { compact ? 22 : 28 }
        private var horizontalPadding: CGFloat { compact ? 8 : 12 }

        private var foreground: Color {
            // 禁用态一律退回灰字。主色那一档尤其要收掉白色 —— 蓝色底 + 灰白字看着像
            // 「半按下」而不是「点了没用」，实测比原来的系统按钮还难读。
            guard enabled else { return Theme.gray500 }
            switch kind {
            case .normal: return Theme.gray700
            case .primary: return .white
            case .danger: return Theme.statusCritical
            }
        }

        private var background: Color {
            guard enabled else { return kind == .primary ? Theme.segmentBackground : .clear }
            switch kind {
            case .normal: return hovering ? Theme.hover : Theme.cardBackground
            case .primary: return Theme.primary.opacity(hovering ? 0.88 : 1)
            case .danger: return hovering ? Theme.statusCritical.opacity(0.1) : .clear
            }
        }

        private var border: Color {
            guard enabled else { return kind == .primary ? .clear : Theme.cardBorder }
            switch kind {
            case .normal: return Theme.cardBorder
            case .primary: return .clear
            case .danger: return hovering ? Theme.statusCritical.opacity(0.35) : Theme.cardBorder
            }
        }

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(background, in: shape)
                .overlay(shape.stroke(border))
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.65 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// 只有图标的按钮（删除设备、打开链接）。默认低调，悬停在删除上才变红 ——
/// 一排行里常驻四个红色垃圾桶比什么都吵。
struct SettingsIconButton: View {
    let systemName: String
    var help: String = ""
    var destructive = false
    var size: CGFloat = 26
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(destructive && hovering ? Theme.statusCritical : Theme.gray600)
                .frame(width: size, height: size)
                .background(hovering ? Theme.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// `.settingsButton()` / `.settingsButton(.primary)` / `.settingsButton(.normal, compact: true)`。
    /// 默认走普通档。
    func settingsButton(_ kind: SettingsButtonStyle.Kind = .normal, compact: Bool = false) -> some View {
        buttonStyle(SettingsButtonStyle(kind: kind, compact: compact))
    }
}

// MARK: - 页头动作槽

/// 页头右上角那个动作（「立即同步」「刷新」「检查更新」）。三页共用同一个形态：
/// 主色实心 + 转圈时换 `ProgressView` —— 各写各的，迟早会有一页忘了在忙的时候禁用。
struct SettingsHeaderAction: View {
    let title: String
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Text(title)
            }
        }
        .settingsButton(.primary)
        .disabled(busy || disabled)
    }
}
