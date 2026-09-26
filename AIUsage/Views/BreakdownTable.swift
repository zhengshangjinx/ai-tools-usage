import SwiftUI

/// 用量明细表：浅灰圆角表头、序号徽标、环境彩色标签、占比条。
/// 这张表同时是趋势图与环形图的**表格孪生体** —— 序列色在浅色底上有几档对比度
/// 低于 3:1，规范要求必须有一条不依赖颜色也能读到全部数值的路径，就是它。
struct BreakdownTable: View {
    @EnvironmentObject var store: UsageStore
    /// 详情浮层的选中模型。状态在窗口那一层，这里只负责写入 —— 原先 `.popover` 挂在每一行上，
    /// 锚点几乎和窗口一样宽、行又会被 LazyVStack 回收，位置会飘到窗口边上。
    @Environment(\.modelDetail) private var modelDetail

    private var rows: [BreakdownRow] { store.snapshot.rows(for: store.breakdown) }

    /// 表里真正渲染的顺序 = 数据层的固定顺序 + 用户点的那个排序（怎么比见 `BreakdownSort.apply`）。
    ///
    /// 排序放在视图这层、不放进 `recompute()`：它只改读法，不改数值。哈希顺序每次重算都不一样，
    /// 所以数据层那三份行是在 recompute 里按「费用降序」排好才发布的 —— 这样 `snapshot` 的内容
    /// 不随视图状态变，也让这里拿到一个确定的输入。
    ///
    /// 取值收敛到 `UsageStore.visibleRows`：导出与离屏渲染读的是同一份，
    /// 「导出的就是屏幕上看到的」才是结构上成立的，而不是靠几处手动对齐。
    private var sortedRows: [BreakdownRow] { store.visibleRows }

    private var firstColumnTitle: String { store.breakdown.rawValue }

    /// 含未计价模型时金额是下界，必须在标题里说清楚，不能让读者把 ≥ 当成精确值
    private var subtitle: String {
        // 占比跟着排序口径走 —— 排的是费用就别在旁边读 token 占比（见 BreakdownSort.shareBasis）
        let base = "共 \(rows.count) 条 · 占比按\(store.sort.shareBasis.shareLabel)计算"
        return rows.contains(where: \.unpriced) ? base + " · ≥ 含未计价模型" : base
    }

    var body: some View {
        let shown = sortedRows
        VStack(alignment: .leading, spacing: 14) {
            CardHeader("用量明细", subtitle: subtitle) {
                SegmentedControl(options: BreakdownMode.allCases.map { ($0, $0.rawValue) }, selection: $store.breakdown, itemWidth: 64, height: 28)
            }
            VStack(spacing: 0) {
                header
                // LazyVStack：这张表最长的一档是「按日期」，90 天范围下就是 90 行，
                // 再加每行的 onHover / 可选中文字 / 弹层锚点 —— 全部提前建出来，
                // 外层 ScrollView 每滚一帧都要连着伺候这些视图，就是掉帧的主要来源。
                // 懒加载后只有视口内的行真实存在，视口外的连 tracking area 都不建。
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().overlay(Theme.divider) }
                        Row(index: i + 1, row: row,
                            share: store.snapshot.share(of: row, by: store.sort.shareBasis),
                            mode: store.breakdown,
                            isLocalDevice: store.breakdown == .device && row.deviceIds == [DeviceIdentity.id],
                            onDetail: store.breakdown == .model ? { modelDetail.wrappedValue = row.id } : nil)
                    }
                }
                if shown.isEmpty {
                    Text("暂无数据").font(.system(size: 13)).foregroundStyle(Theme.gray500).padding(.vertical, 24)
                }
            }
        }
        .card()
    }

    private var header: some View {
        // spacing 必须跟下面 `Row` 里那个 HStack 一致（默认 8）。差一点，第一列那个弹性格
        // 就会多占或少占同样的宽度，整排定宽列跟着平移 —— 表头跟数据错开一整个身位。
        HStack(spacing: 8) {
            SortHeader(title: firstColumnTitle, key: .label, alignment: .leading, leadingInset: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("环境").frame(width: 300, alignment: .leading)
            SortHeader(title: "Tokens", key: .tokens, width: 92, alignment: .trailing)
            // 请求数紧挨着 Tokens：服务商账单上这两个数就是这么并排的
            // （「请求 2,061 / Token 222.83M」），对账时视线不用横跨整张表
            SortHeader(title: "请求数", key: .requests, width: 68, alignment: .trailing,
                       hint: "本地记录的模型响应条数。一次带用量的响应算 1 次，跟服务商账单上的请求数对得上。\nWindsurf / Antigravity 本地数据加密、只有会话数，显示「—」；有设备的档案是旧版本 App 写的时，缺的那部分数不出来，写成 ≥。")
            SortHeader(title: "费用", key: .cost, width: 110, alignment: .trailing)
            Text("占比").frame(width: 158, alignment: .trailing)
            // 明细列每种维度都留位：只在「按模型」出现的话，切维度整张表会横向跳动
            Text("").frame(width: 56)
        }
        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.gray600)
        .padding(.horizontal, 8).frame(height: 30)
        .background(Theme.tableHeader, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 可点表头。点一下按这列排，再点一下翻方向；当前列右侧一个小三角指示方向。
    ///
    /// 三角在不激活时保持占位（`opacity(0)` 而不是不渲染），否则激活列一换，
    /// 各列表头文字会左右挪一格 —— 表头整排看着抖一下。
    private struct SortHeader: View {
        let title: String
        let key: BreakdownSortKey
        /// nil = 占满剩余宽度（第一列，宽度由别的定宽列决定）
        var width: CGFloat?
        let alignment: Alignment
        /// 第一列的数据格左边有 12pt 内缩，表头文字得跟着，否则列首对不齐
        var leadingInset: CGFloat = 0
        /// 这一列口径的补充说明，追加在排序提示后面
        var hint: String? = nil
        @EnvironmentObject var store: UsageStore
        @State private var hovering = false

        private var isActive: Bool { store.sort.key == key }

        var body: some View {
            Button {
                store.sort.toggle(key, mode: store.breakdown)
            } label: {
                HStack(spacing: 3) {
                    Text(title)
                    // 三角**没激活也占位**（`opacity(0)`，不是不渲染）：按存在与否来布局的话，
                    // 换一列排序时那一列的表头文字会左右跳 9.5pt（7pt 三角 + 3pt 间距）。
                    //
                    // 代价：**右对齐的可排序列**（Tokens / 请求数 / 费用）表头文字比数据的右边缘
                    // 左缩这 9.5pt —— 三角那格留在文字右边，文字自然够不到列右沿。
                    // 像素扫描实测（`--render` 的 2x 图）：Tokens 表头停在 2066、数据停在 2085；
                    // 请求数 2218 / 2237 —— 都是 19px。不可排序的「占比」严格重合（2805 / 2805），
                    // 当前排的那一列也因为三角真的画出来了而重合（费用 2474 / 2472）。
                    // 所以四个数字列的**列边界**是逐像素准确的（窄幅 1180pt 下同样是
                    // 1405 / 1557 / 1793 / 2125，与按定宽推出来的值分毫不差），差的只有表头文字这 9.5pt。
                    // 维持现状：把三角挪出文字宽度（负 padding）会把它推进列间那 8pt 空隙里，
                    // 看着像串到隔壁列去了，比这 9.5pt 更糟。
                    Image(systemName: store.sort.ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 7))
                        .opacity(isActive ? 1 : 0)
                }
                .foregroundStyle(isActive ? Theme.gray900 : Theme.gray600)
                .frame(height: 22)
                // 药丸用负 padding 撑到文字外面：表头文字的左右边缘才跟数据格严格对齐
                // （右对齐的可排序列因上面那个三角格子还要再内缩 9.5pt）
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Theme.divider.opacity(0.7) : .clear)
                        .padding(.horizontal, -6)
                )
                .padding(.leading, leadingInset)
            }
            .buttonStyle(.plain)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            // 放在 frame 之后：整格都能点，不用瞄准文字
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(sortHelp)
        }

        private var sortHelp: String {
            let sort = isActive
                ? "当前按「\(title)」\(store.sort.ascending ? "升序" : "降序")，再点一次切换"
                : "按「\(title)」排序"
            guard let hint else { return sort }
            return "\(sort)\n\n\(hint)"
        }
    }

    private struct Row: View {
        let index: Int
        let row: BreakdownRow
        /// 已经算好的占比（口径由调用方定，见 `UsageSnapshot.share(of:by:)`）。
        /// nil = 该口径下这一行没有占比（费用口径遇到未计价行），画「—」。
        let share: Double?
        let mode: BreakdownMode
        let isLocalDevice: Bool
        /// 只有「按模型」维度给得出详情，其余维度传 nil（按钮与双击都关掉）
        let onDetail: (() -> Void)?
        @State private var hovering = false
        /// 标签宽度预算内能完整显示的环境个数
        private static let maxTags = 3

        var body: some View {
            HStack {
                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Theme.gray600)
                        .monospacedDigit()
                        .frame(width: 20, height: 20)
                        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    // 模型名用等宽体（标识符需要逐字符比对）；日期与设备名用正文体
                    Text(row.label)
                        .font(.system(size: 12.5, design: mode == .model ? .monospaced : .default))
                        .foregroundStyle(Theme.gray900)
                        .lineLimit(1).truncationMode(.middle)
                        // 可选中文字会把双击吃掉（变成选词），而模型行双击要开详情，
                        // 所以只在没有详情动作的行上保留选中
                        .textSelectable(onDetail == nil)
                    if isLocalDevice {
                        Text("本机").font(.system(size: 10))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.primarySoft, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                environmentTags
                    .frame(width: 300, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Formatters.tokens(row.tokens))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.gray900).monospacedDigit()
                    AltUnit(text: Formatters.tokensCN(row.tokens), size: 10)
                }
                .frame(width: 92, alignment: .trailing)
                // 请求数：**不做量级缩写**（不写 2.2K），这个数是拿去跟账单逐位对的
                requestsCell
                    .frame(width: 68, alignment: .trailing)
                Group {
                    if let c = row.cost {
                        // 下界写成 ≥：金额本身仍是数字色，符号退到次要色，避免整格变灰不好扫读
                        if row.unpriced {
                            (Text("≥ ").foregroundColor(Theme.gray500) + Text(Formatters.cost(c)).foregroundColor(Theme.gray900))
                        } else {
                            Text(Formatters.cost(c)).foregroundStyle(Theme.gray900)
                        }
                    } else {
                        Text("未计价").foregroundStyle(Theme.gray500)
                    }
                }
                .font(.system(size: 12.5)).monospacedDigit()
                .frame(width: 110, alignment: .trailing)
                shareBar.frame(width: 158, alignment: .trailing)
                // **这一格必须一直存在**，哪怕没有「详情」可点。`if let onDetail` 落空时 `Group`
                // 是空的，SwiftUI 会把这一格连同它前面那 8pt 间距一起剪掉 —— 整行只剩 6 个格，
                // 第一列那个弹性格就多吃 64pt，右边所有定宽列跟着右移 64pt（表头那边一直留着
                // `Text("").frame(width: 56)` 占位）。于是「按日期」「按设备」两张表的表头跟数据
                // 整整错开一列宽，而「按模型」是对的 —— 因为只有它有详情按钮。
                // 兜底用 Color.clear 而不是空 Group：得是个真视图，外面的 `.frame` 才报得出 56pt。
                Group {
                    if let onDetail {
                        Button(action: onDetail) {
                            Text("详情")
                                .font(.system(size: 11)).foregroundStyle(Theme.gray600)
                                .padding(.horizontal, 9).frame(height: 20)
                                .background(Theme.divider, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("查看这个模型的用量、单价与分布（双击整行同样打开）")
                    } else {
                        // 透明但占位。关掉命中测试，否则这一小块会吃掉整行的双击
                        Color.clear.allowsHitTesting(false)
                    }
                }
                .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 8).frame(height: 44)
            .background(hovering ? Theme.tableHeader : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onDetail?() }
        }

        /// 环境标签：**文字用文本色**，身份由旁边那颗彩色圆点承担。
        /// 浅色底上 aqua/yellow 这类色相当文字读不清，彩色文字是规范里的反面样例。
        ///
        /// 按 token 贡献降序只画前 3 个，其余收进「+N」：
        /// 一行最多可能有 8 个环境，全画出来每个都会被挤成 "Cla ud…" 这种单字母截断，
        /// 反而一个都读不出来。收起的那几个用 tooltip 补全，不丢信息。
        private var environmentTags: some View {
            let ordered = row.providers.sorted {
                let a = row.providerTokens[$0] ?? 0, b = row.providerTokens[$1] ?? 0
                return a == b ? $0.rawValue < $1.rawValue : a > b
            }
            let shown = Array(ordered.prefix(Self.maxTags))
            let hidden = Array(ordered.dropFirst(Self.maxTags))
            return HStack(spacing: 5) {
                ForEach(shown) { p in
                    HStack(spacing: 5) {
                        Circle().fill(p.accent).frame(width: 6, height: 6)
                        Text(p.displayName).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray700)
                    }
                    .fixedSize()
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Theme.divider, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if !hidden.isEmpty {
                    Text("+\(hidden.count)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray600)
                        .fixedSize()
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(Theme.divider, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .help(hidden.map { "\($0.displayName) \(Formatters.tokens(row.providerTokens[$0] ?? 0))" }
                                .joined(separator: "\n"))
                }
            }
        }

        /// 请求数那一格。三种状态：
        /// - 数得准 → 直接写（**不做量级缩写**，这个数是拿去跟账单逐位对的）
        /// - 只有下界（有设备档案是旧版本 App 写的，那台机器升级前补不上）→ `≥ N`，
        ///   沿用费用列那套写法：符号退到次要色，数字仍是数字色
        /// - 本地压根量不到（Windsurf / Antigravity 数据加密，只有会话数）→「—」。
        ///   这里不能写 0：「一次都没调用」和「本地没有这个数」是两回事
        @ViewBuilder
        private var requestsCell: some View {
            if row.requests > 0 {
                if row.requestsPartial {
                    (Text("≥ ").foregroundColor(Theme.gray500)
                     + Text(Formatters.count(row.requests)).foregroundColor(Theme.gray900))
                        .font(.system(size: 12.5)).monospacedDigit()
                        .help("有设备的档案是旧版本 App 写的、没记请求数 —— 真实次数不低于这个数；那台设备升级后会补上")
                } else {
                    Text(Formatters.count(row.requests))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.gray900).monospacedDigit()
                }
            } else {
                Text("—")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.gray500)
                    .help(row.requestsPartial
                          ? "本地量不到调用次数：这个范围里的设备档案是旧版本 App 写的"
                          : "本地量不到：Windsurf / Antigravity 的数据是加密的，只数得出会话数")
            }
        }

        /// 占比条是单序列的量值计，不是身份编码 —— 所有行同一个颜色（槽位 1）
        private var shareBar: some View {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Capsule().fill(Theme.divider).frame(width: 84, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.primary)
                            .frame(width: (share ?? 0) > 0 ? max(4, 84 * CGFloat(min(1, share ?? 0))) : 0)
                    }
                Text(share.map(Formatters.percent) ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(share == nil ? Theme.gray500 : Theme.gray700)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}
