import SwiftUI
import AppKit

/// 单个模型的详情面板：双击明细表的模型行、或点行尾的「详情」都会开这个。
///
/// 明细表只有五列，读得出「花了多少」但读不出「为什么是这个数」—— 这张面板补的就是后半截：
/// token 构成、单价从哪来、用了多少天、分布在哪些环境和设备，顺带把手动单价也放在这儿改，
/// 不用再跳去设置的「模型单价」页。
struct ModelDetailPopover: View {
    let model: String
    var dismiss: () -> Void = {}
    /// 卡片高度上限。给 nil 就完全不限（离屏渲染、以及任何高度够用的场合）。
    ///
    /// 面板内容在「按模型 + 近一年」这类范围下能到 700pt 上下，而窗口最小高度只有 640 ——
    /// 不设上限就会顶出窗口。给了上限之后，中间那段（头部以下、操作栏以上）走内部 `ScrollView`：
    /// 内容矮的时候卡片仍然贴着内容收紧，只有真放不下才封顶、头尾钉住、滚中间。见 `middleHeight`。
    var maxHeight: CGFloat? = nil

    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService

    /// 三段各自量出来的高度（见 `measured(into:)`），用来决定中间那段该给多高
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var actionsHeight: CGFloat = 0

    @State private var editing = false
    @State private var draftInput = ""
    @State private var draftCacheRead = ""
    @State private var draftCacheWrite = ""
    @State private var draftOutput = ""

    private var detail: ModelDetail? { store.snapshot.modelDetails[model] }
    private var source: PriceSource { pricing.source(for: model) }
    private var manual: ModelPrice? { pricing.override(for: model) }
    private var effective: ModelPrice? { pricing.price(for: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.measured(into: $headerHeight)
            Divider().overlay(Theme.divider)
            middle
            Divider().overlay(Theme.divider)
            actions.measured(into: $actionsHeight)
        }
        .frame(width: 440)
        // 只有设了上限时才需要它：中段高度还没量出来的第一帧，让卡片先贴着内容，
        // 而不是被外层那个「整窗高」的提议撑满。量到之后中段有确定高度，这里就只是个保险。
        .fixedSize(horizontal: false, vertical: maxHeight != nil)
        .background(Theme.cardBackground)
    }

    @ViewBuilder private var middle: some View {
        if maxHeight == nil {
            content
        } else {
            ScrollView(.vertical) {
                // 量的是**内容自己的**高度：竖直方向不受限，拿到的就是自然高度
                content.measured(into: $contentHeight).overlayScroller()
            }
            .frame(height: middleHeight)
        }
    }

    /// 中间段的高度：自然高度放得下就贴合，放不下才封顶（封顶后内部滚动，头尾钉住）。
    ///
    /// 早先这里用的是 `ViewThatFits`（“放得下就整块露出、放不下就滚”），但实测它选出来的卡片
    /// 会撑满上限、内容还居中浮在中间，上下各空出约 100pt —— 不是要的「贴合」。
    /// 换成自己量：中段内容的自然高度、头部与操作栏的高度各量一次，上限减掉头尾就是能给的额度。
    ///
    /// `max(120, …)`：窗口被压到极矮时也得给中段留一口气，不然头尾会把中间挤成 0。
    private var middleHeight: CGFloat? {
        guard let maxHeight, contentHeight > 0 else { return nil }
        let chrome = headerHeight + actionsHeight + 2   // 两条分隔线
        return min(contentHeight, max(120, maxHeight - chrome))
    }

    @ViewBuilder private var content: some View {
        if let d = detail {
            VStack(alignment: .leading, spacing: 16) {
                kpis(d)
                tokenBreakdown(d)
                priceSection(d)
                usage(d)
                providers(d)
            }
            .padding(16)
        } else {
            Text("当前范围内没有这个模型的用量。")
                .font(.system(size: 12)).foregroundStyle(Theme.gray500)
                .padding(16)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model)
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.gray900)
                    .textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { copy(model) } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.borderless).help("复制模型标识")
            }
            if let d = detail {
                HStack(spacing: 5) {
                    ForEach(orderedProviders(d), id: \.self) { p in
                        HStack(spacing: 5) {
                            Circle().fill(p.accent).frame(width: 6, height: 6)
                            Text(p.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray700)
                        }
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: 关键数字

    private func kpis(_ d: ModelDetail) -> some View {
        HStack(alignment: .top, spacing: 0) {
            kpi("处理 Tokens", Formatters.tokens(d.tokens), alt: Formatters.tokensCN(d.tokens))
            Rectangle().fill(Theme.divider).frame(width: 1, height: 34)
            // 跟明细表的列序一致（Tokens / 请求数 / 费用），从表里点进来视线不用重新找位置
            kpi("请求数",
                (d.requestsPartial ? "≥ " : "") + (d.requests > 0 ? Formatters.count(d.requests) : "—"),
                // 均值只在数得准的时候给：拿一个下界去除 tokens，得出的「每次多少」只会偏大
                alt: d.requests > 0 && !d.requestsPartial ? "平均 \(Formatters.tokens(d.tokens / d.requests)) / 次" : nil)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 34)
            kpi("估算费用", d.priced ? Formatters.cost(d.cost) : "≥ " + Formatters.cost(d.cost),
                alt: d.unpricedTokens > 0 ? "未计价 \(Formatters.tokens(d.unpricedTokens))" : nil)
            Rectangle().fill(Theme.divider).frame(width: 1, height: 34)
            // 占比口径跟明细表当前那一列一致（表里排的是费用就读费用占比）——
            // 这个浮层是从表里点开的，两处数字对不上会让人以为哪儿算错了
            kpi("占比",
                store.snapshot.byModel.first { $0.label == model }
                    .flatMap { store.snapshot.share(of: $0, by: store.sort.shareBasis) }
                    .map(Formatters.percent) ?? "—",
                alt: "按\(store.sort.shareBasis.shareLabel)")
        }
    }

    private func kpi(_ label: String, _ value: String, alt: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.gray500)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.gray900).monospacedDigit().lineLimit(1)
            AltUnit(text: alt, size: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Token 构成

    private func tokenBreakdown(_ d: ModelDetail) -> some View {
        let total = max(d.tokens, 1)
        let parts: [(String, Int, Color)] = [
            ("缓存读取", d.cacheRead, Theme.series[0]),
            ("未缓存输入", d.uncachedInput, Theme.series[2]),
            ("缓存写入", d.cacheWrite, Theme.series[3]),
            ("输出", d.output, Theme.series[4]),
        ]
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Token 构成")
            ForEach(parts, id: \.0) { name, value, color in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.gray700).frame(width: 62, alignment: .leading)
                    Capsule().fill(Theme.divider).frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: value > 0 ? max(3, 150 * CGFloat(value) / CGFloat(total)) : 0)
                        }
                        .frame(width: 150)
                    Text(Formatters.tokens(value)).font(.system(size: 11.5)).foregroundStyle(Theme.gray900)
                        .monospacedDigit().frame(width: 62, alignment: .trailing)
                    Text(Formatters.percent(Double(value) / Double(total)))
                        .font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
            if d.cacheSavings > 0 {
                Text("缓存读取比全价输入省了 \(Formatters.cost(d.cacheSavings))")
                    .font(.system(size: 11)).foregroundStyle(Theme.gray500)
            }
        }
    }

    // MARK: 单价

    @ViewBuilder
    private func priceSection(_ d: ModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                sectionTitle("单价（美元 / 百万 tokens）")
                sourceBadge
                Spacer(minLength: 0)
            }
            if editing {
                priceEditor
            } else if let p = effective {
                HStack(spacing: 0) {
                    rate("输入", p.input); rate("缓存读", p.cacheRead); rate("缓存写", p.cacheWrite); rate("输出", p.output)
                }
                if source == .table, let key = pricing.matchedTableKey(for: model), key.lowercased() != model.lowercased() {
                    // 模糊匹配要明说：否则用户以为价格表里真有这么一条
                    Text("按价格表中的 \(key) 计费（模型标识去掉了日期 / 档位后缀）")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.gray500)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.statusWarning)
                    Text("价格表里没有这个模型，费用按 0 计 —— 也就是上方的费用只是下界。")
                        .font(.system(size: 11)).foregroundStyle(Theme.gray600)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sourceBadge: some View {
        let (text, color): (String, Color) = {
            switch source {
            case .manual: return ("手动单价", Theme.primary)
            case .table: return ("LiteLLM 价格表", Theme.statusGood)
            case .none: return ("未收录", Theme.statusWarning)
            }
        }()
        return Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func rate(_ label: String, _ v: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.gray500)
            Text(PricingService.formatPerMillion(v))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.gray900).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var priceEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                numField("输入", $draftInput); numField("缓存读", $draftCacheRead)
                numField("缓存写", $draftCacheWrite); numField("输出", $draftOutput)
            }
            HStack(spacing: 8) {
                Text("缓存字段留空则按输入单价计费").font(.system(size: 10.5)).foregroundStyle(Theme.gray500)
                Spacer(minLength: 0)
                SmallButton(title: "取消") { editing = false }
                SmallButton(title: "保存", primary: true) { save() }
                    .disabled(Double(draftInput) == nil || Double(draftOutput) == nil)
            }
        }
    }

    private func numField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.gray500)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(.system(size: 11.5))
        }
    }

    // MARK: 使用情况

    private func usage(_ d: ModelDetail) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("使用情况")
            HStack(alignment: .center, spacing: 12) {
                Sparkline(values: sparklineValues(d))
                    .frame(width: 148, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("使用 \(d.activeDays) 天 · 首用 \(d.firstDay.map(Formatters.shortDay) ?? "—") · 最近 \(d.lastDay.map(Formatters.shortDay) ?? "—")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.gray700)
                    if let peak = d.peak {
                        Text("峰值 \(Formatters.shortDay(peak.day)) · \(Formatters.tokens(peak.tokens)) tokens")
                            .font(.system(size: 11)).foregroundStyle(Theme.gray500)
                    }
                    Text(deviceLine(d)).font(.system(size: 11)).foregroundStyle(Theme.gray500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 按范围内每一天补齐（没有用量的那天记 0），否则曲线会把空档挤掉、看着像连续在用
    private func sparklineValues(_ d: ModelDetail) -> [Int] {
        let cal = Calendar.current
        var out: [Int] = []
        var day = store.rangeStart
        while day <= store.rangeEnd {
            out.append(d.daily[day] ?? 0)
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    private func deviceLine(_ d: ModelDetail) -> String {
        let names = store.devices.filter { d.devices.contains($0.id) }.map(\.name)
        return names.isEmpty ? "" : "涉及 \(names.count) 台设备：\(names.joined(separator: "、"))"
    }

    // MARK: 环境分布

    private func providers(_ d: ModelDetail) -> some View {
        let ordered = orderedProviders(d)
        let total = max(d.tokens, 1)
        return VStack(alignment: .leading, spacing: 7) {
            sectionTitle("环境分布")
            ForEach(ordered, id: \.self) { p in
                let v = d.providers[p] ?? 0
                HStack(spacing: 8) {
                    Circle().fill(p.accent).frame(width: 8, height: 8)
                    Text(p.displayName).font(.system(size: 11.5)).foregroundStyle(Theme.gray700)
                        .frame(width: 92, alignment: .leading)
                    Capsule().fill(Theme.divider).frame(height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(p.accent).frame(width: v > 0 ? max(3, 130 * CGFloat(v) / CGFloat(total)) : 0)
                        }
                        .frame(width: 130)
                    Text(Formatters.tokens(v)).font(.system(size: 11.5)).foregroundStyle(Theme.gray900)
                        .monospacedDigit().frame(width: 62, alignment: .trailing)
                    Text(Formatters.percent(Double(v) / Double(total)))
                        .font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    // MARK: 底部操作

    private var actions: some View {
        HStack(spacing: 10) {
            if editing {
                Text("改完点「保存」立即生效，费用会按新单价重算。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.gray500)
            } else {
                Button(manual == nil ? "设置手动单价" : "修改手动单价") { beginEdit() }
                    .controlSize(.small)
                if manual != nil {
                    Button("恢复 LiteLLM 价格", role: .destructive) {
                        pricing.overrides.removeValue(forKey: manualKey ?? model)
                    }
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("关闭") { dismiss() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// 手动单价的键大小写可能与模型标识不同，删的时候要用原始键
    private var manualKey: String? {
        pricing.overrides.keys.first { $0 == model } ?? pricing.overrides.keys.first { $0.lowercased() == model.lowercased() }
    }

    private func beginEdit() {
        // 已有手动单价就先填它，否则拿当前生效的价格当草稿 —— 改一个数比从空白敲四个数快
        let p = manual ?? effective
        draftInput = p.map { ModelPrice.perMillionText($0.input) } ?? ""
        draftCacheRead = p?.cacheRead.map(ModelPrice.perMillionText) ?? ""
        draftCacheWrite = p?.cacheWrite.map(ModelPrice.perMillionText) ?? ""
        draftOutput = p.map { ModelPrice.perMillionText($0.output) } ?? ""
        editing = true
    }

    private func save() {
        guard let i = Double(draftInput), let o = Double(draftOutput) else { return }
        pricing.overrides[model] = ModelPrice.perMillion(
            input: i, output: o,
            cacheRead: Double(draftCacheRead), cacheWrite: Double(draftCacheWrite)
        )
        editing = false
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.gray600)
    }

    private func orderedProviders(_ d: ModelDetail) -> [ProviderKind] {
        d.providers.keys.sorted { (d.providers[$0] ?? 0) > (d.providers[$1] ?? 0) }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// 模型详情浮层：半透明遮罩 + 窗口正中的详情卡片。挂在 `ContentView` 顶层（`ScrollView` 之外），
/// 不是挂在明细表的某一行上 —— 这就是「永远居中」的关键。
///
/// 早先用的是挂在每个行 `Row` 上的 `.popover`：锚点是一整行，宽度几乎等于窗口，
/// 行又躺在 `LazyVStack` 里会被回收，AppKit 拿不到稳定的锚点矩形，
/// 于是弹窗有时落到窗口最左 / 最右 / 最上边。现在浮层不属于任何一行，也不受滚动影响，
/// 位置只由窗口自己决定。
///
/// 关闭方式有三条：点遮罩、按 ESC、面板自带的「关闭」按钮 —— 三条都走同一个 `dismiss`。
struct ModelDetailOverlay: View {
    let model: String
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 遮罩自己画，不用系统 sheet：sheet 是独立窗口，尺寸和位置都不受我们控制，
                // 而这里要的是「落在窗口正中、跟着窗口变」。遮罩同时兼作关闭热区。
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                // 上下各留 40pt：卡片再高也不贴边，看得出是「浮」在上面的一层
                ModelDetailPopover(model: model, dismiss: dismiss,
                                   maxHeight: max(280, geo.size.height - 80))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardBorder))
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // ESC 关闭。用隐藏按钮而不是 `.onExitCommand`：后者要视图在响应链上、拿到键盘焦点才触发，
        // 浮层里没有可聚焦控件（单价编辑区全是 TextField，聚焦的是它们）时它会静默失效。
        // `.opacity(0)` 而不是 `.hidden()` —— 隐藏的视图不参与快捷键分发，等于没写。
        .background(
            Button("", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

private extension View {
    /// 把自身高度写回绑定。放在 `background` 里：不改动布局，也不参与命中测试。
    /// 写状态发生在布局之后（`onAppear` / `onChange`），不会踩到「布局中改状态」。
    func measured(into binding: Binding<CGFloat>) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { binding.wrappedValue = geo.size.height }
                .onChange(of: geo.size.height) { _, height in binding.wrappedValue = height }
        })
    }
}

/// 每日用量缩略图。没有坐标轴，只交代形状 —— 具体数值由旁边的文字给。/// 单独一天（或全为 0）时画一条平线，不留空白让人猜。
private struct Sparkline: View {
    let values: [Int]

    var body: some View {
        let maxV = max(values.max() ?? 0, 1)
        let pts = points(maxV: maxV)
        ZStack {
            Theme.divider
            if pts.count > 1 {
                Path { p in
                    p.move(to: CGPoint(x: pts[0].x, y: 34))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: 34))
                    p.closeSubpath()
                }
                .fill(Theme.primary.opacity(0.15))
                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Theme.primary, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func points(maxV: Int) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = 148 / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * step, y: 34 - 30 * CGFloat(v) / CGFloat(maxV))
        }
    }
}
