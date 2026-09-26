import Foundation

/// 导出格式。命名照 `BreakdownMode` 的规矩：给人看的 `label` 用中文，机器读的 `fileTag` 用 ASCII。
enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, tsv, json

    var id: String { rawValue }

    var label: String {
        switch self {
        case .csv: return "CSV（逗号分隔）"
        case .tsv: return "TSV（制表符，粘进 Excel 不串列）"
        case .json: return "JSON（含 token 分量与单价）"
        }
    }

    /// 文件名与 `--export` 参数用的 ASCII 标记。**不要**改成中文：
    /// `rawValue` 现在恰好是 ASCII，但这个属性存在的意义是「即使以后 rawValue 变了，
    /// 进文件名和命令行的那份仍然是 ASCII」。
    var fileTag: String { rawValue }

    /// 只有给人拿 Excel 打开的表格才要 BOM；JSON 的读取方按 UTF-8 解，多一个 BOM 反而噎住
    var needsBOM: Bool { self != .json }

    var fileExtension: String { rawValue }
}

/// 一次导出的**全部输入**。全是值与闭包，没有任何 IO ——
/// 这样 `--selftest` 能拿构造出来的数据逐字节比对，不用起窗口、不用扫盘。
///
/// 「占比」和「价格」用闭包传进来，是为了让导出与屏幕**共用同一个来源**：
/// 界面上那份占比来自 `UsageSnapshot.share(of:by:)`、价格来自 `PricingService`，
/// 导出如果自己再算一遍，两边迟早会出现「表格写 12.3%、CSV 写 12.4%」这种没法解释的差。
struct ExportContext {
    var mode: BreakdownMode
    var sort: BreakdownSort
    /// 屏幕上那一份行（`UsageStore.visibleRows`），顺序就是用户看到的顺序
    var rows: [BreakdownRow]
    var totals: UsageTotals
    /// 该行在「占比」列的值（0..1）。口径由 `sort.shareBasis` 决定，与表头副标题那句话一致
    var share: (BreakdownRow) -> Double?
    /// 价格查表，查不到返回 nil（**nil 不是 0**）
    var price: (String) -> ModelPrice?
    /// 这条价格是从哪来的（手动填的 / 价格表里的 / 没有）
    var priceSource: (String) -> PriceSource
    /// 价格表版本。见 `UsageExporter.json` 里 `price_table_updated` 的说明 —— 这个字段不能省
    var priceTableUpdated: Date?
    var rangeStart: Date
    var rangeEnd: Date
    /// 当前勾选的环境，用来在元信息里说清「这份数据被筛过」
    var selectedProviders: [ProviderKind]
    var deviceLabel: String
    var appVersion: String
}

/// 导出。**纯序列化，不碰文件系统** —— 落盘由调用方（菜单里的 NSSavePanel / `--export`）负责。
///
/// 几条口径是刻意照抄 `token-monitor/src/shared/exporter.js` 的先例的，
/// 因为那些坑别人已经踩过一遍：
/// - **表格带 UTF-8 BOM**：否则 Excel 打开中文标签（`claude-sonnet-5（日常使用）`）是乱码。
/// - **RFC 4180**：CRLF 行尾；只对含 `"` `,` `\n` `\r` 的值加引号，值里的 `"` 翻倍。
/// - **`null` ≠ `0`**：「没有这个数」与「就是 0」在导出里必须分得开，
///   另用 `*_partial` 布尔列表达「这是下界」。
/// - **分量不全报 `unclassified`，绝不猜成 input** —— 跟界面上「数不出来就写 ≥ / —」是同一条原则。
///
/// 还有一条本项目自己的：**金额只在「那个价格表版本」下成立**。档案里只存 4 个 token 桶、
/// 从不存钱（见 `AggregateRow` 的注释），费用是每次展示时按当时的价格表现算的。
/// 所以 JSON 的元信息里必须带上价格表版本，否则几个月后回头对这份 CSV，
/// 差额是哪来的将无从解释。
enum UsageExporter {
    // MARK: 表格格式的列

    /// 机器读的列名一律 ASCII。`date` 与 `label` 在「按日期」维度下内容重复 ——
    /// 仍然保留两列：一个是给机器读的（`DayKey`，钉死 POSIX 区域），一个是给人看的。
    /// 合成一列会让下游得猜这一列到底是哪种。
    static let tableColumns = ["dimension", "date", "label", "providers", "tokens",
                               "requests", "requests_partial", "cost_usd", "cost_partial", "share"]

    /// 金额小数位。6 位是因为单价本身是「每 token 美元」（1e-6 量级），
    /// 再少就会把便宜模型的费用截成 0；界面上的 $X.XX 是给人看的，不是给账本读的。
    private static let costDecimals = 6
    private static let shareDecimals = 6

    // MARK: 表格（CSV / TSV）

    static func table(_ ctx: ExportContext, format: ExportFormat) -> String {
        let separator: Character = format == .tsv ? "\t" : ","
        var out = ""
        if format.needsBOM { out += "\u{FEFF}" }
        out += tableColumns.map { escape($0, separator: separator) }.joined(separator: String(separator)) + "\r\n"
        for r in ctx.rows {
            out += tableRow(r, ctx: ctx, separator: separator).joined(separator: String(separator)) + "\r\n"
        }
        return out
    }

    private static func tableRow(_ r: BreakdownRow, ctx: ExportContext, separator: Character) -> [String] {
        let unknown = requestsUnknown(r)
        return [
            ctx.mode.fileTag,
            r.day.map(DayKey.key) ?? "",
            r.label,
            r.providers.map(\.displayName).sorted().joined(separator: ";"),
            String(r.tokens),
            unknown ? "" : String(r.requests),
            bool(unknown || r.requestsPartial),
            r.cost.map { number($0, decimals: costDecimals) } ?? "",
            bool(costPartial(r)),
            ctx.share(r).map { number($0, decimals: shareDecimals) } ?? "",
        ].map { escape($0, separator: separator) }
    }

    /// RFC 4180：只在必要时加引号，值里的引号翻倍。
    /// 制表符分隔时还要防字段里本身带 `\t`（不然会多切出一列）。
    static func escape(_ value: String, separator: Character) -> String {
        let needsQuote = value.contains("\"") || value.contains(separator)
            || value.contains("\n") || value.contains("\r")
        guard needsQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    static func json(_ ctx: ExportContext) -> String {
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [            "exported_at": iso.string(from: Date()),
            "app_version": ctx.appVersion,
            "currency": "USD",
            "dimension": ctx.mode.fileTag,
            "dimension_label": ctx.mode.rawValue,
            "range_start": DayKey.key(ctx.rangeStart),
            "range_end": DayKey.key(ctx.rangeEnd),
            "sort": ctx.sort.key.rawValue,
            "sort_ascending": ctx.sort.ascending,
            "share_basis": ctx.sort.shareBasis.rawValue,
            "providers": ctx.selectedProviders.map(\.displayName).sorted(),
            "devices": ctx.deviceLabel,
            "row_count": ctx.rows.count,
            // 价格表版本：**这一份导出里的金额只在这个版本下成立**。档案只存 token 桶、
            // 不存钱，费用是展示时按当时的价格表现算的，所以缺了它就等于给不出一份可复算的账。
            "price_table_updated": ctx.priceTableUpdated.map { iso.string(from: $0) } ?? NSNull(),
            "note": "金额单位为美元；null 表示「没有这个数」，与 0 不同。"
                + "requests_partial / cost_partial 为 true 时，对应的数是下界。",
        ]

        var rows: [[String: Any]] = []
        for r in ctx.rows {
            let unknown = requestsUnknown(r)
            var item: [String: Any] = [
                "dimension": ctx.mode.fileTag,
                "date": r.day.map(DayKey.key) ?? NSNull(),
                "label": r.label,
                "providers": r.providers.map(\.displayName).sorted(),
                "tokens": r.tokens,
                // 分量之和恒等于 tokens；`unclassified` 正常情况下是 0，
                // 留着是因为一旦某个数据源给出对不上的数，要如实报出来而不是悄悄摊进 input
                "tokens_components": components(r),
                "requests": (unknown ? nil : r.requests).map { $0 as Any } ?? NSNull(),
                "requests_partial": unknown || r.requestsPartial,
                "cost_usd": r.cost.map { $0 as Any } ?? NSNull(),
                "cost_partial": costPartial(r),
                "share": ctx.share(r).map { $0 as Any } ?? NSNull(),
                // 单价只对「按模型」这一维有意义（其余维度一行跨多个模型）。
                // 其余维度恒为 null，让下游不用自己判断维度就知道这一格能不能读。
                "prices": ctx.mode == .model ? prices(r.label, ctx: ctx) : NSNull(),
            ]
            // 未计价但金额非 nil 的行（「按日期」「按设备」维度整行给下界）也把单价列成 null
            if ctx.mode == .model && ctx.price(r.label) == nil { item["prices"] = NSNull() }
            rows.append(item)
        }

        // totals 与 rows 平级放进根对象：它是「这个范围内一共多少」，
        // 跟 meta（这份文件是怎么生成的）不是一类东西，塞进 meta 会让读者以为它也是元信息
        let root: [String: Any] = ["meta": meta, "totals": totals(ctx.totals), "rows": rows]
        // sortedKeys：不排序的话每次导出的键序都可能变，diff 全是噪音
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: opts),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text + "\n"
    }

    private static func totals(_ t: UsageTotals) -> [String: Any] {
        [
            "tokens": t.processed,
            "tokens_components": [
                "input_uncached": t.uncachedInput,
                "cache_read": t.cachedInput,
                "cache_write": t.cacheWrite,
                "output": t.output,
            ],
            "cost_usd": t.cost,
            "cost_partial": t.unpricedTokens > 0,
            "unpriced_tokens": t.unpricedTokens,
            "requests": t.requests,
            "sessions": t.sessions,
        ]
    }

    private static func components(_ r: BreakdownRow) -> [String: Any] {
        let c = r.components
        return [
            "input_uncached": c.inputUncached,
            "cache_read": c.cacheRead,
            "cache_write": c.cacheWrite,
            "output": c.output,
            // clamp 到 ≥0：分量之和理论上恒等于 tokens，但真出现对不上时，
            // 宁可把差额报成一个负数之外的数，也不要静默地摊进 input
            "unclassified": max(0, r.tokens - c.total),
        ]
    }

    private static func prices(_ model: String, ctx: ExportContext) -> Any {
        guard let p = ctx.price(model) else { return NSNull() }
        let source: String
        switch ctx.priceSource(model) {
        case .manual: source = "manual"
        case .table: source = "table"
        case .none: source = "none"
        }
        return [
            "input": p.input,
            "output": p.output,
            "cache_read": p.cacheRead.map { $0 as Any } ?? NSNull(),
            "cache_write": p.cacheWrite.map { $0 as Any } ?? NSNull(),
            "source": source,
        ]
    }

    // MARK: 共用口径

    /// 请求数**数不出来**：有 token 却一条都没记到（旧版 App 写的档案）。
    /// 「真的是 0 次」不长这样 —— 那是有 token 但 requests 确实为 0 的相反情形，
    /// 而 token > 0 时一条记录都没有意味着档案缺列，不是没调用过。
    static func requestsUnknown(_ r: BreakdownRow) -> Bool {
        r.requests == 0 && r.tokens > 0
    }

    /// 金额只有下界：整行含未计价模型（`unpriced`），或者「按模型」维度下压根查不到价（`cost == nil`）。
    /// 两种都要标 `cost_partial=true`，因为下游拿这个数去求和时得知道它偏小。
    static func costPartial(_ r: BreakdownRow) -> Bool {
        r.cost == nil || r.unpriced
    }

    /// 布尔值在表格里写成 `true` / `false`（不是 1/0）：
    /// 这两种写法 Excel 会分别当文本和数字，混着看更容易误读。
    private static func bool(_ v: Bool) -> String { v ? "true" : "false" }

    /// 定点小数，**强制 POSIX 小数点**。`String(format:)` 本身不做本地化，
    /// 但显式传 locale 可以让「以后有人换成 `String(format:locale:)`」时不至于悄悄变成逗号。
    private static func number(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    // MARK: 文件名

    /// 默认文件名：`AI用量-按模型-2026-06-28至2026-09-25.csv`。
    /// 带维度与范围，是因为用户导完多半会攒一堆同名文件。
    static func defaultFileName(_ ctx: ExportContext, format: ExportFormat) -> String {
        let range = "\(DayKey.key(ctx.rangeStart))至\(DayKey.key(ctx.rangeEnd))"
        return "AI用量-\(ctx.mode.rawValue)-\(range).\(format.fileExtension)"
    }
}
