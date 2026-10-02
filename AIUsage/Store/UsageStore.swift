import Foundation
import Combine

/// 快捷档位。窗口 = 「长度」+「贴着哪天结束」两件事，缺一不可：
/// 今日和昨日长度都是 1 天，只看长度区分不开它们，所以两个属性都要有。
/// 声明顺序就是档位条上的顺序，CaseIterable 直接拿来铺。
enum QuickRange: CaseIterable, Identifiable {
    case today, yesterday, week, month, twoMonths, quarter, year

    var id: Self { self }

    /// 范围长度（天，含首尾）
    var days: Int {
        switch self {
        case .today, .yesterday: return 1
        case .week: return 7
        case .month: return 30
        case .twoMonths: return 60
        case .quarter: return 90
        case .year: return 365
        }
    }

    var label: String {
        switch self {
        case .today: return "今日"
        case .yesterday: return "昨日"
        case .week: return "近7天"
        case .month: return "近30天"
        case .twoMonths: return "近60天"
        case .quarter: return "近90天"
        case .year: return "近一年"
        }
    }

    /// 窗口结束日相对今天的偏移：0 = 含今天，1 = 截止到昨天
    var endOffsetDays: Int { self == .yesterday ? 1 : 0 }

    /// 该档位对应的 [起, 止] 日期（均为当天 0 点）
    ///
    /// 「近一年」取 365 天滚动窗口，不是自然年 —— 自然年（1/1 起）是日期弹层里的「本年」。
    var dates: (start: Date, end: Date) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: -endOffsetDays, to: today)!
        return (cal.date(byAdding: .day, value: 1 - days, to: end)!, end)
    }

    /// `--dump <天数>` 按范围长度反查档位。
    /// 今日和昨日同为 1 天，这里取含今天的那个 —— 命令行只报「近 N 天」的账。
    static func matching(days: Int) -> QuickRange? {
        allCases.first { $0.days == days && $0.endOffsetDays == 0 }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cost = "费用", tokens = "Tokens"
    var id: String { rawValue }
}

/// 明细表可点表头排序的列：第一列（按模型 / 按设备 / 按日期）、Tokens、请求数、费用。
enum BreakdownSortKey: String, CaseIterable, Identifiable {
    case label, tokens, requests, cost
    var id: String { rawValue }

    /// 「占比」那一列按什么口径算。**跟着排序口径走** —— 排的是费用就在旁边读 token 占比，
    /// 读者得自己在两个口径之间换算，那是这张表最容易看错的地方。
    /// 第一列（名称 / 日期）本身没有量纲，沿用费用，与加「请求数」之前的行为一致。
    var shareBasis: BreakdownSortKey { self == .label ? .cost : self }

    /// 占比口径的展示名（副标题里写「占比按 X 计算」）
    var shareLabel: String {
        switch shareBasis {
        case .tokens: return "Tokens"
        case .requests: return "请求数"
        default: return "费用"
        }
    }
}

/// 明细表的排序口径。**默认按费用降序** —— 「哪个最烧钱」是这张表最常被问的问题。
struct BreakdownSort {
    var key: BreakdownSortKey = .cost
    var ascending = false

    /// 占比口径 = 当前排序列（见 `BreakdownSortKey.shareBasis`）
    var shareBasis: BreakdownSortKey { key.shareBasis }

    /// 点表头。同一列再点一次翻方向；换列时给一个合理的第一方向 ——
    /// 两个数值列都是「大的在前」；第一列在按日期时是「新的在前」，按模型/设备时是「A→Z」。
    mutating func toggle(_ k: BreakdownSortKey, mode: BreakdownMode) {
        if key == k {
            ascending.toggle()
        } else {
            key = k
            ascending = (k == .label && mode != .day)
        }
    }

    /// 切维度后把方向掰回来。「第一列」在三种维度下分别是名称、名称、日期：
    /// 名称 A→Z 是对的，日期则要「新的在前」（跟这张表的默认一致），否则一切过去就是倒着的。
    mutating func normalize(for mode: BreakdownMode) {
        if key == .label { ascending = (mode != .day) }
    }

    /// 按当前口径排一份行出来。放在这里而不是视图里，是因为「怎么比」是这套排序自己的事，
    /// 视图只该问「排完是什么样」。
    ///
    /// 两处细节：
    /// - 日期维度下 `label` 这一列是**按日期**比的，不是按 "09-24" 这个标签 ——
    ///   字符串序在跨年时会把 12-31 排到 01-01 前面。
    /// - 每个口径都带一个兜底键（名称）。`sorted` 在 Swift 里**不是稳定排序**，
    ///   不给兜底的话，同值的两行每次重排的相对位置都可能变，表格看着会自己抖。
    func apply(to rows: [BreakdownRow]) -> [BreakdownRow] {
        switch key {
        case .label:
            return rows.sorted { a, b in
                if let da = a.day, let db = b.day, da != db { return ascending ? da < db : da > db }
                let r = a.label.localizedStandardCompare(b.label)
                return ascending ? r != .orderedDescending : r != .orderedAscending
            }
        case .tokens:
            return rows.sorted { a, b in
                a.tokens == b.tokens ? a.label < b.label : (ascending ? a.tokens < b.tokens : a.tokens > b.tokens)
            }
        case .requests:
            // 请求数同值时按 tokens 兜第二级：条数相同的两行里，token 多的那行显然更重，
            // 用 tokens 兜比用名称兜更贴这个口径的直觉
            return rows.sorted { a, b in
                if a.requests == b.requests {
                    return a.tokens == b.tokens ? a.label < b.label : a.tokens > b.tokens
                }
                return ascending ? a.requests < b.requests : a.requests > b.requests
            }
        case .cost:
            return rows.sorted { a, b in
                // 未计价行的 cost 是 nil（金额只有下界），排序时当 -1：降序沉底、升序浮顶，
                // 两种方向下读起来都是「这些是没法比价的」
                let x = a.cost ?? -1, y = b.cost ?? -1
                if x == y { return a.label < b.label }
                return ascending ? x < y : x > y
            }
        }
    }
}

enum BreakdownMode: String, CaseIterable, Identifiable {
    case device = "按设备", model = "按模型", day = "按日期"
    var id: String { rawValue }
    /// 离屏快照文件名用的 ASCII 标签
    var fileTag: String {
        switch self {
        case .device: return "device"
        case .model: return "model"
        case .day: return "day"
        }
    }
}

struct ProviderSummary: Identifiable {
    let kind: ProviderKind
    var tokens = 0
    var cost = 0.0
    /// 范围内的模型响应次数。仅会话环境（本地数据加密）没有 token 记录，这里恒为 0。
    var requests = 0
    /// 范围内去重后的会话数。跨设备同步只传每日计数，不传会话 id：
    /// 设备之间会话天然不相交，求和即正确；跨天的单个会话会被计两次（可接受的近似）。
    var sessionCount = 0
    var unpricedTokens = 0
    var id: ProviderKind { kind }
}

struct DailyPoint: Identifiable {
    let day: Date
    let provider: ProviderKind
    var tokens = 0
    var cost = 0.0
    var id: String { "\(day.timeIntervalSince1970)-\(provider.rawValue)" }
}

/// 一行的四个 token 分量。
///
/// 表格只画总数，但导出要给得出构成 —— 否则「这一行的钱花在哪」下游算不出来
/// （缓存读的单价只有 input 的十分之一，只看总数看不出省钱在哪）。
///
/// **分量之和恒等于 `BreakdownRow.tokens`**：`UsageRecord.total` 与
/// `AggregateRow.total` 都是这四个数相加，一路上没有别的来源。
/// 导出时按 `tokens - 分量和` 算一个 `unclassified_tokens`（先 clamp 到 ≥0），
/// 正常情况下它恒为 0；留着这个字段是因为一旦哪天某个数据源给出对不上的数，
/// 要如实报出来而不是悄悄摊进 input。
struct TokenComponents: Hashable {
    var inputUncached = 0
    var cacheRead = 0
    var cacheWrite = 0
    var output = 0

    var total: Int { inputUncached + cacheRead + cacheWrite + output }
}

struct BreakdownRow: Identifiable {
    let id: String
    let label: String
    let providers: Set<ProviderKind>
    let tokens: Int
    let cost: Double?
    let day: Date?
    /// 这一行里的模型响应次数。**跟 tokens 同源** —— 只有带用量的记录才进桶，
    /// 所以「仅会话」环境凑出来的行（Windsurf / Antigravity）这里是 0，表里画「—」。
    var requests: Int = 0
    /// 上面那个数是下界（有设备档案是旧版本 App 写的，见 `AggregateRow.requestsUnknown`）
    var requestsPartial: Bool = false
    /// 该行涉及的设备（仅「按设备」以外的维度会用到；「按设备」维度下是单一设备）
    var deviceIds: Set<String> = []
    /// 该行含未计价模型的 token：cost 因此是**下界**，展示时要写成 ≥
    var unpriced: Bool = false
    /// 各环境在本行里的 token 数。标签按贡献从大到小排、溢出时挑掉最小的，
    /// 所以需要的不只是「出现过哪些环境」，而是各占多少。
    var providerTokens: [ProviderKind: Int] = [:]
    /// 四个 token 分量，只给导出用（表格不画）。见 `TokenComponents`。
    var components = TokenComponents()
}

/// 「按模型」行的完整明细，供详情弹窗用。
/// 明细表只画得下 Tokens/费用/占比五列，但点开一行时想看的是价格来源、token 构成、
/// 用了多久、分布在哪些环境 —— 这些都在 recompute 里顺路攒好，弹窗不用再扫一遍原始记录。
struct ModelDetail {
    var model = ""
    var tokens = 0
    /// 模型响应次数，用来跟服务商账单对账（一次响应算一次）
    var requests = 0
    /// 上面的数是下界（有设备档案是旧版本 App 写的）
    var requestsPartial = false
    var cacheRead = 0, uncachedInput = 0, cacheWrite = 0, output = 0
    var cost = 0.0
    var cacheSavings = 0.0
    /// 未计价模型贡献的 token：cost 因此是下界
    var unpricedTokens = 0
    var priced = true
    var providers: [ProviderKind: Int] = [:]
    var devices: Set<String> = []
    /// 每天的 token 数，用来算使用跨度与趋势缩略图
    var daily: [Date: Int] = [:]

    var firstDay: Date? { daily.keys.min() }
    var lastDay: Date? { daily.keys.max() }
    /// 有使用的天数（不是范围天数）
    var activeDays: Int { daily.count }
    var peak: (day: Date, tokens: Int)? {
        daily.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}

struct UsageTotals {
    var processed = 0, cachedInput = 0, uncachedInput = 0, cacheWrite = 0, output = 0
    var cost = 0.0, cacheSavings = 0.0
    var unpricedTokens = 0
    var sessions = 0
    /// 范围内的模型响应次数合计（「请求数」占比的分母）
    var requests = 0
    var unpricedShare: Double { processed == 0 ? 0 : Double(unpricedTokens) / Double(processed) }
}

/// 前一个等长周期的汇总，用于 KPI 卡环比
struct PeriodComparison {
    var processed = 0
    var cost = 0.0
    var sessions = 0
}

/// 菜单栏常驻摘要。
///
/// **窗口固定为「今日 / 本月 / 近 7 天」，不跟随主窗口选的日期范围。**
/// 这不是实现方便，是语义：菜单栏回答的是「今天花了多少」，
/// 不该因为用户在主窗口点了「近90天」就跟着变成 90 天的数。
/// 筛选口径（环境 / 设备）仍然跟着主窗口走 —— 「算哪些数据」和「算哪段时间」是两回事。
///
/// 这里也**绝不**去改 `rangeStart` / `rangeEnd` 来取今日：那两个属性带 `didSet { recompute() }`，
/// 从菜单栏改一下就等于劫持了主窗口的日期范围（`recompute` 里另有一段说明）。
struct MenuBarSummary {
    struct Totals {
        var tokens = 0
        var cost = 0.0
        var requests = 0
        /// 请求数只有下界（旧版档案缺这个字段），展示时要标 ≥
        var requestsPartial = false
        /// 含未计价模型 → 金额是下界
        var unpriced = false
        var sessions = 0
    }

    /// 近 7 天里的一天，**跨环境合计**：菜单面板那根迷你柱只回答「哪天多」，
    /// 「哪个环境多」是主窗口两张图的事。
    struct Day: Identifiable {
        let day: Date
        var tokens = 0
        var cost = 0.0
        var id: Date { day }
    }

    var today = Totals()
    var month = Totals()
    /// 恒为 7 个点，最早在前、最后一个是今天。没有用量的天补 0，柱子才连续。
    var last7: [Day] = []
}

struct UsageSnapshot {
    var totals = UsageTotals()
    var previous = PeriodComparison()
    var providers: [ProviderSummary] = []
    var daily: [DailyPoint] = []
    var byModel: [BreakdownRow] = []
    var byDay: [BreakdownRow] = []
    var byDevice: [BreakdownRow] = []
    /// 模型标识 → 完整明细（详情弹窗的数据源）
    var modelDetails: [String: ModelDetail] = [:]
    /// 环境 chip 上的会话数。**不受环境筛选影响** —— 否则选中一个环境后其余环境的计数会消失，
    /// chip 变窄、整行重排，看着就像点一下页面抖一下。它描述的是「这个范围内这个环境有多少」。
    var chipSessionCounts: [ProviderKind: Int] = [:]
    var unpricedModels: [String] = []

    /// 维度 → 明细行。表格与基准测试共用，别在两处各写一遍 switch
    func rows(for mode: BreakdownMode) -> [BreakdownRow] {
        switch mode {
        case .device: return byDevice
        case .model: return byModel
        case .day: return byDay
        }
    }

    /// 某一行在某个口径下的占比。口径就是明细表当前的排序键（`BreakdownSortKey.shareBasis`），
    /// 所以「占比」永远在解释旁边那个排序依据。
    ///
    /// 这个值原先是在 `recompute()` 里按当时那个**全局**指标算好、存进 `BreakdownRow.share` 的。
    /// 现在两张图各有各的指标开关、表格另有自己的排序口径，同一个 `snapshot` 会被三种口径读，
    /// 存一份就不成立了；改成现算 —— 都是一次除法，不值得为它多存一个字段。
    ///
    /// 分母取 `totals`（范围内全量），所以一整列占比加起来是 100%。
    /// 费用口径下未计价行没有占比（返回 nil，表格画「—」）：它的 cost 是下界，拿它去除总额会得到
    /// 一个看着精确、其实偏小的数。请求数口径没有这个问题 —— 只有「仅会话」行是 0，
    /// 而它本来就真的是 0 次，如实写成 0.0%。
    func share(of row: BreakdownRow, by basis: BreakdownSortKey) -> Double? {
        switch basis {
        // `.label` 不会从 shareBasis 传进来（它已经折成 .cost），这里只是补全 switch
        case .cost, .label: return row.cost.map { $0 / max(totals.cost, 0.000001) }
        case .tokens: return Double(row.tokens) / Double(max(totals.processed, 1))
        case .requests: return Double(row.requests) / Double(max(totals.requests, 1))
        }
    }
}

/// 聚合行 + 归属设备。跨设备的合并结果就是这个数组：本机当次扫描的 + 各远端设备档案里的。
struct ScopedRow: Hashable {
    let deviceId: String
    let row: AggregateRow
}

struct ScopedSession: Hashable {
    let deviceId: String
    let row: SessionCountRow
}

@MainActor
final class UsageStore: ObservableObject {
    // MARK: 本机扫描产物（原始记录，仅本机）
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var scanDuration: TimeInterval = 0

    // MARK: 跨设备聚合结果（recompute 的唯一输入）
    @Published private(set) var snapshot = UsageSnapshot()
    /// 菜单栏用的固定窗口摘要（今日 / 本月 / 近 7 天）。跟 `snapshot` 同一次 recompute 里算出来，
    /// 但**窗口独立** —— 为什么，见 `MenuBarSummary`。
    @Published private(set) var menuBarSummary = MenuBarSummary()

    // MARK: 设备
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var syncWarnings: [String] = []
    @Published private(set) var lastSync: Date?
    /// 多选：空集 = 全部设备汇总；只勾一个 = 只看那台
    @Published var selectedDevices: Set<String> = [] { didSet { recompute() } }

    private var rows: [ScopedRow] = []
    private var sessions: [ScopedSession] = []

    // MARK: 统计范围
    @Published var rangeStart: Date = QuickRange.quarter.dates.start { didSet { recompute() } }
    @Published var rangeEnd: Date = QuickRange.quarter.dates.end { didSet { recompute() } }
    /// 明细表的排序。跟 `breakdown` 一样**故意不触发 recompute** —— 排序是读的时候的事，
    /// 三个维度的行都已算好，排个序而已，没必要把 7 万条记录重算一遍（那正是切维度抖动的主因）。
    /// 行本身在 recompute 里按「费用降序」这个稳定口径排好，保证 snapshot 每次发布内容一致；
    /// 用户点的排序只作用在视图那一层。
    @Published var sort = BreakdownSort()
    /// 纯展示维度，**故意不触发 recompute**：三个维度的行在同一次 recompute 里都算好了，
    /// 它只是读的时候用 `snapshot.rows(for:)` 挑一份出来。原先这里挂了 `didSet { recompute() }`，
    /// 于是每切一次「按设备 / 按模型 / 按日期」都重新发布一个全新的 UsageSnapshot ——
    /// KPI 卡、折线图、环形图全部跟着重算，而数据一个都没变，是切维度抖动的主因之一。
    @Published var breakdown: BreakdownMode = .device
    @Published var selectedProviders: Set<ProviderKind> = Set(ProviderKind.allCases) { didSet { recompute() } }
    @Published var sourceConfigs: [SourceKind: SourceConfig] { didSet { saveConfigs() } }

    let pricing: PricingService
    private var cancellables = Set<AnyCancellable>()
    private static let configsKey = "sources.config.v1"

    let deviceSync = DeviceSync.shared

    init(pricing: PricingService) {
        self.pricing = pricing
        if let data = DemoRuntime.defaults.data(forKey: Self.configsKey),
           let decoded = try? JSONDecoder().decode([SourceKind: SourceConfig].self, from: data) {
            sourceConfigs = decoded
        } else {
            sourceConfigs = Dictionary(uniqueKeysWithValues: SourceKind.allCases.map { ($0, SourceConfig(paths: $0.configuredDefaultPaths)) })
        }
        for kind in SourceKind.allCases where sourceConfigs[kind] == nil {
            sourceConfigs[kind] = SourceConfig(paths: kind.configuredDefaultPaths)
        }
        pricing.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }

    /// 当前范围恰好等于某档「近 N 天」时返回该档，手动改过日期则为 nil
    var activeQuickRange: QuickRange? {
        QuickRange.allCases.first { $0.dates.start == rangeStart && $0.dates.end == rangeEnd }
    }

    func apply(_ quick: QuickRange) {
        let d = quick.dates
        rangeStart = d.start
        rangeEnd = d.end
    }

    /// 日期选择器回写：规整到当天 0 点并保证起 ≤ 止
    func setRange(start: Date, end: Date) {
        let cal = Calendar.current
        let s = cal.startOfDay(for: start), e = cal.startOfDay(for: end)
        rangeStart = min(s, e)
        rangeEnd = max(s, e)
    }

    var rangeDayCount: Int {
        (Calendar.current.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 0) + 1
    }

    /// **屏幕上那一份行**：数据层的固定顺序 + 用户点的那个排序。
    ///
    /// 提上来是因为它要被三处读：明细表、离屏渲染工装、导出。
    /// 原先表格里自己算一遍、`RenderHarness` 里再算一遍，导出再抄第三遍的话，
    /// 「所见即所得」就变成「三个人手动保持一致」—— 迟早漂。
    ///
    /// 只是个纯计算属性：`sort` 与 `breakdown` 都**故意不触发** `recompute()`
    /// （见那两个属性的注释），所以多一个读法不引入任何新的失效。
    var visibleRows: [BreakdownRow] {
        sort.apply(to: snapshot.rows(for: breakdown))
    }

    func resetPaths(for kind: SourceKind) {
        sourceConfigs[kind]?.paths = kind.configuredDefaultPaths
    }

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(sourceConfigs) {
            DemoRuntime.defaults.set(data, forKey: Self.configsKey)
        }
    }

    /// 留存面板与工装要读的「共享目录里那几份档案」。
    ///
    /// 提出来是因为它有四个读点（`--retention`、出图工装、`DisplaySettings.reload()`、
    /// 以及自测），而演示模式必须一个不漏地换成内存里那份 —— 漏掉任何一个，
    /// 出图就会去读作者真实的 iCloud 目录。`syncNow()` 里那次是写入路径，另说。
    var archiveDeviceFiles: [DeviceFile] {
        if DemoRuntime.isActive { return DemoRuntime.archiveDeviceFiles }
        return deviceSync.readAll().files
    }

    // MARK: 扫描 + 同步

    func refresh() async {
        // 演示模式：不扫盘（`ScanCache` 在用户的 Application Support 里，碰不得），
        // 改用编好的那套记录，然后照常走同步与聚合。出图和「--demo 手工看看」走的是同一条路。
        if DemoRuntime.isActive {
            records = DemoData.localRecords
            lastScan = DemoRuntime.lastScan
            scanDuration = DemoRuntime.scanDuration
            syncNow()
            recompute()
            return
        }
        guard !isScanning else { return }
        isScanning = true
        let started = Date()
        let configs = sourceConfigs
        let all = await Task.detached(priority: .userInitiated) { () -> [UsageRecord] in
            await withTaskGroup(of: [UsageRecord].self) { group in
                for (kind, cfg) in configs where cfg.enabled {
                    group.addTask {
                        let t0 = Date()
                        let r = kind.makeProvider().scan(paths: cfg.paths)
                        NSLog("[AIUsage] %@ scanned %d records in %.2fs", kind.rawValue, r.count, Date().timeIntervalSince(t0))
                        return r
                    }
                }
                var out: [UsageRecord] = []
                for await part in group { out.append(contentsOf: part) }
                ScanCache.shared.finishScan()
                return out.sorted { $0.timestamp < $1.timestamp }
            }
        }.value
        records = all
        lastScan = Date()
        scanDuration = Date().timeIntervalSince(started)
        syncNow()
        isScanning = false
        recompute()
    }

    /// 设置里改目录 / 改设备名 / 移除设备后调用：重新同步并刷新聚合，不重扫本地文件
    func resync() {
        syncNow()
        recompute()
    }

    /// 聚合本机记录 → 写入自己的设备档案 → 读回全部设备档案 → 合并。
    /// 每台设备只写自己那一份，因此不存在并发写冲突，也不需要加锁。
    func syncNow() {
        let local = Self.aggregate(records)
        syncWarnings = []
        let selfId = DeviceIdentity.id

        // 演示模式：不写共享目录、也不读它。档案是内存里编好的那几份，
        // 但**合并规则与真同步完全同一份代码**（下面那个 merge），
        // 否则截图上的「按设备」就可能和真界面算的不是一回事，图也就不再能证明什么。
        if DemoRuntime.isActive {
            merge(local: local,
                  files: DemoRuntime.archiveDeviceFiles.filter { $0.deviceId != selfId },
                  localUpdatedAt: DemoRuntime.localDeviceUpdatedAt)
            return
        }

        var files: [DeviceFile] = []
        if syncEnabled {
            let mine = DeviceFile(
                deviceId: selfId,
                deviceName: DeviceIdentity.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                updatedAt: Date(),
                rows: local.rows,
                sessions: local.sessions
            )
            if let err = deviceSync.write(mine) { syncWarnings.append(err) }
            let (read, warnings) = deviceSync.readAll()
            syncWarnings.append(contentsOf: warnings)
            // 本机那份以刚扫出来的为准，避免读回旧内容
            files = read.filter { $0.deviceId != selfId }
        }
        merge(local: local, files: files, localUpdatedAt: Date())
    }

    /// 把「本机聚合 + 各远端档案」并成界面用的三类数据（合并行、会话行、设备清单）。
    ///
    /// 提出来是因为它有两个入口：正常同步（读 iCloud 目录）与演示模式（档案全在内存里）。
    /// 规则只该有一份 —— 抄一遍的代价是截图和真界面从此可能算出不同的数，
    /// 那这张图就不再能证明界面是对的。
    private func merge(local: (rows: [AggregateRow], sessions: [SessionCountRow]),
                       files: [DeviceFile], localUpdatedAt: Date) {
        let selfId = DeviceIdentity.id

        var merged: [ScopedRow] = local.rows.map { ScopedRow(deviceId: selfId, row: $0) }
        var mergedSessions: [ScopedSession] = local.sessions.map { ScopedSession(deviceId: selfId, row: $0) }
        for f in files {
            merged.append(contentsOf: f.rows.map { ScopedRow(deviceId: f.deviceId, row: $0) })
            mergedSessions.append(contentsOf: f.sessions.map { ScopedSession(deviceId: f.deviceId, row: $0) })
        }
        rows = merged
        sessions = mergedSessions

        var list: [DeviceInfo] = [DeviceInfo(
            id: selfId, name: DeviceIdentity.name, isLocal: true, updatedAt: localUpdatedAt,
            rowCount: local.rows.count, sessionTotal: local.sessions.reduce(0) { $0 + $1.count }
        )]
        list.append(contentsOf: files.map {
            DeviceInfo(id: $0.deviceId, name: $0.deviceName, isLocal: false, updatedAt: $0.updatedAt,
                       rowCount: $0.rows.count, sessionTotal: $0.sessions.reduce(0) { $0 + $1.count })
        })
        devices = list.sorted { ($0.isLocal ? 0 : 1, $0.name) < ($1.isLocal ? 0 : 1, $1.name) }
        // 丢掉已不存在的设备选择
        let live = Set(devices.map(\.id))
        if !selectedDevices.isSubset(of: live) { selectedDevices = selectedDevices.intersection(live) }
        lastSync = localUpdatedAt
    }

    /// 把原始记录压成「日 × 环境 × 模型」的 4 桶聚合 + 每日会话计数。
    /// 5 万多条记录通常压成几十行，这也是跨设备同步体量可控的原因。
    nonisolated static func aggregate(_ records: [UsageRecord]) -> (rows: [AggregateRow], sessions: [SessionCountRow]) {
        let cal = Calendar.current
        var buckets: [String: AggregateRow] = [:]
        var perDay: [String: Set<String>] = [:]
        var providerOfDay: [String: ProviderKind] = [:]

        for r in records {
            let day = DayKey.key(cal.startOfDay(for: r.timestamp))
            let skey = "\(day)|\(r.provider.rawValue)"
            perDay[skey, default: []].insert(r.sessionId)
            providerOfDay[skey] = r.provider

            // 仅会话记录（本地数据加密）只计会话数，不进 token 聚合
            guard r.total > 0 else { continue }
            let key = "\(day)|\(r.provider.rawValue)|\(r.model)"
            var b = buckets[key] ?? AggregateRow(day: day, provider: r.provider, model: r.model,
                                                 inputUncached: 0, cacheRead: 0, cacheWrite: 0, output: 0, requests: 0)
            b.inputUncached += r.inputUncached
            b.cacheRead += r.cacheRead
            b.cacheWrite += r.cacheWrite
            b.output += r.output
            // 一条记录 = 一次模型响应。各 provider 都已经按各自的粒度去过重了
            // （Claude Code 按 message.id + requestId，Codex 按 token_count 事件），
            // 所以这里的条数可以直接跟服务商账单上的请求数对账。
            b.requests += 1
            buckets[key] = b
        }

        let sessionRows = perDay.compactMap { key, ids -> SessionCountRow? in
            guard let p = providerOfDay[key], let day = key.split(separator: "|").first else { return nil }
            return SessionCountRow(day: String(day), provider: p, count: ids.count)
        }
        return (buckets.values.sorted { ($0.day, $0.provider.rawValue, $0.model) < ($1.day, $1.provider.rawValue, $1.model) },
                sessionRows.sorted { ($0.day, $0.provider.rawValue) < ($1.day, $1.provider.rawValue) })
    }

    // MARK: 设备选择

    @Published var syncEnabled: Bool = DemoRuntime.defaults.object(forKey: "sync.enabled.v1") as? Bool ?? true {
        didSet {
            DemoRuntime.defaults.set(syncEnabled, forKey: "sync.enabled.v1")
            syncNow()
            recompute()
        }
    }

    /// 「全部设备」= 选中集覆盖了每一台，判定方式跟下面环境行完全一致。
    /// 逐台勾满时自动折回「全部」：屏幕上同时列着两台、两颗都亮着，却还要另外点一下左侧那颗
    /// 「全部设备」才算数 —— 那个中间状态没有信息量，只会让人以为漏了一项。
    var isAllDevicesSelected: Bool {
        selectedDevices.isEmpty || Set(devices.map(\.id)).isSubset(of: selectedDevices)
    }

    /// 顶部设备选择器展示的文案
    var deviceSelectionLabel: String {
        if devices.count <= 1 { return devices.first?.name ?? DeviceIdentity.name }
        if isAllDevicesSelected { return "全部设备 · \(devices.count) 台" }
        if selectedDevices.count == 1 {
            return devices.first { selectedDevices.contains($0.id) }?.name ?? "1 台设备"
        }
        return selectedDevices.count == devices.count ? "全部 \(devices.count) 台" : "\(selectedDevices.count) 台设备"
    }

    func selectAllDevices() { selectedDevices = [] }

    /// 全部状态下点某一台 = 只看它；否则勾选/取消该台；一台不剩时回到全部
    func toggleDevice(_ id: String) {
        if isAllDevicesSelected { selectedDevices = [id]; return }
        var next = selectedDevices
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        // 勾满就收回到空集 —— 「全部」的规范表示。设备是别的机器同步过来的，
        // 随时会多出一台：留着一份写死的清单，新设备一到就变成「2/3 台」；
        // 空集天然把新来的那台也算进去。
        selectedDevices = next.count == devices.count ? [] : next
    }

    private func isActive(_ deviceId: String) -> Bool {
        selectedDevices.isEmpty || selectedDevices.contains(deviceId)
    }

    private func deviceName(_ id: String) -> String {
        devices.first { $0.id == id }?.name ?? "未知设备"
    }

    // MARK: 环境选择

    var enabledProviders: [ProviderKind] {
        ProviderKind.allCases.filter { sourceConfigs[$0.source]?.enabled ?? true }
    }

    /// 筛选菜单里展示的环境：已启用，且本机检测到数据源、或当前所选设备里有数据
    var visibleProviders: [ProviderKind] {
        let present = Set(rows.filter { isActive($0.deviceId) }.map(\.row.provider))
        return enabledProviders.filter { $0.source.isDetected || present.contains($0) }
    }

    /// 「全部环境」= 未做任何单选（选中集覆盖所有可见环境）
    var isAllProvidersSelected: Bool {
        Set(visibleProviders).isSubset(of: selectedProviders)
    }

    func selectAllProviders() {
        selectedProviders = Set(ProviderKind.allCases)
    }

    /// 全部状态下点某一项 = 只看它；否则切换该项；一个都不剩时回到全部
    func toggleProvider(_ p: ProviderKind) {
        if isAllProvidersSelected {
            selectedProviders = [p]
            return
        }
        var next = selectedProviders
        if next.contains(p) { next.remove(p) } else { next.insert(p) }
        if next.intersection(visibleProviders).isEmpty { next = Set(ProviderKind.allCases) }
        selectedProviders = next
    }

    // MARK: 聚合

    /// recompute 内部的中间桶。「按日期」和「按设备」两个维度本来各自用一个位置元组
    /// （`(tokens:cost:priced:providers:devices:)` 之类），加「请求数」这第三个量时
    /// 位置就对不上号了 —— 换成具名字段，两个维度共用一个类型：
    /// 各自只用得到其中几项，剩下的空着不花钱。
    private struct Bucket {
        var tokens = 0
        var cost = 0.0
        var requests = 0
        /// 请求数只有下界（有设备档案是旧版本 App 写的，见 `AggregateRow.requestsUnknown`）
        var requestsPartial = false
        var priced = true
        var providers: [ProviderKind: Int] = [:]
        var devices: Set<String> = []
        /// 四个 token 分量。桶里本来就在逐个累加它们（`snap.totals` 那几行），
        /// 这里只是**顺路**多留一份到行上 —— 表格不画，导出要用（见 `TokenComponents`）。
        var components = TokenComponents()
    }

    private func recompute() {
        let providers = selectedProviders
        let startKey = DayKey.key(rangeStart)
        let endKey = DayKey.key(rangeEnd)
        let active = rows.filter { isActive($0.deviceId) && $0.row.day >= startKey && $0.row.day <= endKey && providers.contains($0.row.provider) }
        let activeSessions = sessions.filter { isActive($0.deviceId) && $0.row.day >= startKey && $0.row.day <= endKey && providers.contains($0.row.provider) }

        var snap = UsageSnapshot()
        var summaries: [ProviderKind: ProviderSummary] = [:]
        var daily: [String: DailyPoint] = [:]
        var models: [String: ModelDetail] = [:]
        var days: [Date: Bucket] = [:]
        var deviceAgg: [String: Bucket] = [:]
        var unpriced = Set<String>()

        // 仅会话环境（本地数据加密）没有 token 行，靠会话行让它们仍然出现在图例与分布里
        for s in activeSessions {
            var summary = summaries[s.row.provider] ?? ProviderSummary(kind: s.row.provider)
            summary.sessionCount += s.row.count
            summaries[s.row.provider] = summary
            // 只有会话行的环境 / 设备也要出现在「按设备」表里（token 为 0，但会话是真的）
            var sessionOnlyDevice = deviceAgg[s.deviceId] ?? Bucket()
            sessionOnlyDevice.providers[s.row.provider, default: 0] += 0
            deviceAgg[s.deviceId] = sessionOnlyDevice
        }

        // chip 计数单独算一遍：只按设备和日期范围收窄，不按环境 —— 见 chipSessionCounts 的说明
        for s in sessions where isActive(s.deviceId) && s.row.day >= startKey && s.row.day <= endKey {
            snap.chipSessionCounts[s.row.provider, default: 0] += s.row.count
        }

        for scoped in active {
            let r = scoped.row
            guard let day = DayKey.date(r.day) else { continue }
            let price = pricing.price(for: r.model)
            let rowCost = price?.cost(for: r) ?? 0
            // 旧版本 App 写的设备档案缺请求数：这一行（这个模型 / 这一天 / 这台设备）的请求数
            // 只能算成下界，展示时要标 ≥，不能当成「就这么多次」
            let requestsUnknown = r.requestsUnknown
            // 四个分量在下面三个桶（天 / 设备）+ 模型明细里都要各加一遍，先装成一个值搬
            var parts = TokenComponents()
            parts.inputUncached = r.inputUncached
            parts.cacheRead = r.cacheRead
            parts.cacheWrite = r.cacheWrite
            parts.output = r.output

            snap.totals.processed += r.total
            snap.totals.cachedInput += r.cacheRead
            snap.totals.uncachedInput += r.inputUncached
            snap.totals.cacheWrite += r.cacheWrite
            snap.totals.output += r.output
            snap.totals.cost += rowCost
            snap.totals.cacheSavings += price?.cacheSavings(for: r) ?? 0
            snap.totals.requests += r.requests
            if price == nil { snap.totals.unpricedTokens += r.total; unpriced.insert(r.model) }

            var summary = summaries[r.provider] ?? ProviderSummary(kind: r.provider)
            summary.tokens += r.total; summary.cost += rowCost; summary.requests += r.requests
            if price == nil { summary.unpricedTokens += r.total }
            summaries[r.provider] = summary

            let dkey = "\(r.day)-\(r.provider.rawValue)"
            var d = daily[dkey] ?? DailyPoint(day: day, provider: r.provider)
            d.tokens += r.total; d.cost += rowCost
            daily[dkey] = d

            var m = models[r.model] ?? ModelDetail(model: r.model)
            m.tokens += r.total
            m.requests += r.requests
            if requestsUnknown { m.requestsPartial = true }
            m.cacheRead += r.cacheRead; m.uncachedInput += r.inputUncached
            m.cacheWrite += r.cacheWrite; m.output += r.output
            m.cost += rowCost
            m.cacheSavings += price?.cacheSavings(for: r) ?? 0
            if price == nil { m.priced = false; m.unpricedTokens += r.total }
            m.providers[r.provider, default: 0] += r.total
            m.devices.insert(scoped.deviceId)
            m.daily[day, default: 0] += r.total
            models[r.model] = m

            var dd = days[day] ?? Bucket()
            dd.tokens += r.total; dd.cost += rowCost; dd.requests += r.requests
            dd.components.inputUncached += parts.inputUncached
            dd.components.cacheRead += parts.cacheRead
            dd.components.cacheWrite += parts.cacheWrite
            dd.components.output += parts.output
            dd.providers[r.provider, default: 0] += r.total; dd.devices.insert(scoped.deviceId)
            if requestsUnknown { dd.requestsPartial = true }
            if price == nil { dd.priced = false }
            days[day] = dd

            var da = deviceAgg[scoped.deviceId] ?? Bucket()
            da.tokens += r.total; da.cost += rowCost; da.requests += r.requests
            da.components.inputUncached += parts.inputUncached
            da.components.cacheRead += parts.cacheRead
            da.components.cacheWrite += parts.cacheWrite
            da.components.output += parts.output
            da.providers[r.provider, default: 0] += r.total
            if requestsUnknown { da.requestsPartial = true }
            if price == nil { da.priced = false }
            deviceAgg[scoped.deviceId] = da
        }
        snap.totals.sessions = summaries.values.reduce(0) { $0 + $1.sessionCount }
        snap.providers = ProviderKind.allCases.compactMap { summaries[$0] }.sorted { $0.tokens > $1.tokens }

        // 前一等长周期：[start - N 天, start)
        let cal = Calendar.current
        let prevStartKey = DayKey.key(cal.date(byAdding: .day, value: -rangeDayCount, to: rangeStart)!)
        for scoped in rows where isActive(scoped.deviceId) && scoped.row.day >= prevStartKey && scoped.row.day < startKey && providers.contains(scoped.row.provider) {
            snap.previous.processed += scoped.row.total
            snap.previous.cost += pricing.price(for: scoped.row.model)?.cost(for: scoped.row) ?? 0
        }
        for s in sessions where isActive(s.deviceId) && s.row.day >= prevStartKey && s.row.day < startKey && providers.contains(s.row.provider) {
            snap.previous.sessions += s.row.count
        }
        snap.unpricedModels = unpriced.sorted()

        // 补齐范围内每一天，让曲线连续
        let activeProviders = snap.providers.map(\.kind)
        var day = rangeStart
        var series: [DailyPoint] = []
        while day <= rangeEnd {
            for p in activeProviders {
                series.append(daily["\(DayKey.key(day))-\(p.rawValue)"] ?? DailyPoint(day: day, provider: p))
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        snap.daily = series

        // 行序固定按「费用降序」，不受视图里那个排序影响 —— snapshot 是数据层，
        // 换个人点一下表头不该让它重新发布。视图要别的顺序自己排（见 BreakdownTable.sortedRows）。
        // 未计价行的 cost 是 nil，用 -1 兜底让它沉到有价行下面，再按 tokens 兜第二级，
        // 保证同额的两行每次都在同一个位置（顺序不稳的话表格会莫名跳）。
        let byCostDesc: (BreakdownRow, BreakdownRow) -> Bool = {
            ($0.cost ?? -1, $0.tokens) > ($1.cost ?? -1, $1.tokens)
        }
        snap.byModel = models.map { key, v in
            BreakdownRow(id: key, label: key, providers: Set(v.providers.keys), tokens: v.tokens,
                         cost: v.priced ? v.cost : nil, day: nil, requests: v.requests,
                         requestsPartial: v.requestsPartial,
                         deviceIds: v.devices, providerTokens: v.providers,
                         components: TokenComponents(inputUncached: v.uncachedInput, cacheRead: v.cacheRead,
                                                     cacheWrite: v.cacheWrite, output: v.output))
        }.sorted(by: byCostDesc)
        snap.modelDetails = models
        snap.byDay = days.map { key, v in
            BreakdownRow(id: "\(key.timeIntervalSince1970)", label: Formatters.dayLabel(key), providers: Set(v.providers.keys),
                         tokens: v.tokens, cost: v.cost, day: key, requests: v.requests,
                         requestsPartial: v.requestsPartial,
                         deviceIds: v.devices, unpriced: !v.priced, providerTokens: v.providers,
                         components: v.components)
        }.sorted { $0.day! > $1.day! }
        // 设备行永远给出金额（未计价部分作下界），因为「哪台机器更贵」是这一维度的主问题，
        // 整行写「未计价」会让默认视图直接失去意义；下界由 unpriced 标记 + ≥ 号说明。
        snap.byDevice = deviceAgg.map { id, v in
            BreakdownRow(id: id, label: deviceName(id), providers: Set(v.providers.keys), tokens: v.tokens,
                         cost: v.cost, day: nil, requests: v.requests,
                         requestsPartial: v.requestsPartial,
                         deviceIds: [id], unpriced: !v.priced, providerTokens: v.providers,
                         components: v.components)
        }.sorted(by: byCostDesc)

        menuBarSummary = Self.menuBarSummary(rows: rows, sessions: sessions, providers: providers,
                                            isActive: isActive, pricing: pricing)

        snapshot = snap
    }

    // MARK: 菜单栏摘要

    /// 菜单栏那三个数（今日 / 本月 / 近 7 天）。**固定窗口，不看 `rangeStart`/`rangeEnd`** ——
    /// 理由写在 `MenuBarSummary` 上：菜单栏回答的是「今天花了多少」，
    /// 用户在主窗口点「近90天」不该把它的语义改掉。
    ///
    /// 筛选口径（环境 / 设备）跟主窗口一致，因为那是「算哪些数据」，跟「算哪段时间」是两回事。
    ///
    /// 单独一趟遍历而不是复用主循环：主循环的窗口是用户选的日期范围，
    /// 跟这里的三个窗口没有任何包含关系（用户可能正选着「上个月」，那时今日的数据根本不在主循环里）。
    private static func menuBarSummary(rows: [ScopedRow], sessions: [ScopedSession],
                                       providers: Set<ProviderKind>,
                                       isActive: (String) -> Bool,
                                       pricing: PricingService) -> MenuBarSummary {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayKey = DayKey.key(todayStart)
        let monthStartKey = DayKey.key(cal.date(from: cal.dateComponents([.year, .month], from: todayStart)) ?? todayStart)
        // 最早在前、最后一个是今天。恒 7 个点，没用的天补 0（柱子才连续）
        let weekKeys = (0..<7).reversed().compactMap { offset in
            cal.date(byAdding: .day, value: -offset, to: todayStart).map(DayKey.key)
        }
        // 近 7 天可能跨月（例如今天是 3 号），所以下界取两者更早的那个
        let fromKey = min(weekKeys.first ?? todayKey, monthStartKey)
        let weekSet = Set(weekKeys)

        var bar = MenuBarSummary()
        var week: [String: MenuBarSummary.Day] = [:]

        for scoped in rows where isActive(scoped.deviceId) && providers.contains(scoped.row.provider)
            && scoped.row.day >= fromKey && scoped.row.day <= todayKey {
            let r = scoped.row
            let price = pricing.price(for: r.model)
            let rowCost = price?.cost(for: r) ?? 0
            let unknown = r.requestsUnknown

            // 会话数不在这里加：只有会话行、没有 token 行的环境（Windsurf / Antigravity）
            // 压根不进这个循环，混着加会漏，所以统一交给下面那趟 sessions 遍历
            func add(_ t: inout MenuBarSummary.Totals) {
                t.tokens += r.total; t.cost += rowCost; t.requests += r.requests
                if unknown { t.requestsPartial = true }
                if price == nil { t.unpriced = true }
            }
            if r.day == todayKey { add(&bar.today) }
            if r.day >= monthStartKey { add(&bar.month) }
            if weekSet.contains(r.day), let day = DayKey.date(r.day) {
                var d = week[r.day] ?? MenuBarSummary.Day(day: day)
                d.tokens += r.total; d.cost += rowCost
                week[r.day] = d
            }
        }
        for s in sessions where isActive(s.deviceId) && providers.contains(s.row.provider)
            && s.row.day >= monthStartKey && s.row.day <= todayKey {
            if s.row.day == todayKey { bar.today.sessions += s.row.count }
            bar.month.sessions += s.row.count
        }
        bar.last7 = weekKeys.map { key in
            week[key] ?? MenuBarSummary.Day(day: DayKey.date(key) ?? todayStart)
        }
        return bar
    }

    // MARK: Debug

    /// 菜单栏摘要的文本形式。**跟 `debugDump()` 分开**，不是舍不得几行代码：
    /// `debugDump()` 的输出是回归基线（改 `recompute()` 前后要逐字节相同），
    /// 往里加一节就等于把基线作废。核对菜单栏的数用 `--menu`。
    func debugMenuDump() -> String {
        func line(_ name: String, _ t: MenuBarSummary.Totals) -> String {
            let mark = t.requestsPartial ? "≥" : ""
            let money = t.unpriced ? "≥" : ""
            return "\(name): tokens=\(t.tokens) cost=\(money)\(String(format: "%.2f", t.cost)) requests=\(mark)\(t.requests) sessions=\(t.sessions) unpriced=\(t.unpriced)"
        }
        var lines = [line("today", menuBarSummary.today), line("month", menuBarSummary.month)]
        lines.append("last7:")
        for d in menuBarSummary.last7 {
            lines.append("  \(DayKey.key(d.day)) tokens=\(d.tokens) cost=\(String(format: "%.2f", d.cost))")
        }
        return lines.joined(separator: "\n")
    }

    func debugDump() -> String {
        let t = snapshot.totals
        var lines = ["range=\(Formatters.dayLabel(rangeStart))..\(Formatters.dayLabel(rangeEnd)) records=\(records.count) scan=\(String(format: "%.2fs", scanDuration))",
                     "processed=\(t.processed) cached=\(t.cachedInput) uncached=\(t.uncachedInput) cacheWrite=\(t.cacheWrite) output=\(t.output) cost=\(String(format: "%.2f", t.cost)) savings=\(String(format: "%.2f", t.cacheSavings)) sessions=\(t.sessions) requests=\(t.requests) unpriced=\(t.unpricedTokens)"]
        for p in snapshot.providers {
            lines.append("  \(p.kind.displayName): tokens=\(p.tokens) cost=\(String(format: "%.2f", p.cost)) requests=\(p.requests) sessions=\(p.sessionCount) unpriced=\(p.unpricedTokens)")
        }
        lines.append("models:")
        for m in snapshot.byModel {
            // ≥ = 这个数只有下界（有设备档案是旧版本 App 写的，缺请求数）
            let mark = m.requestsPartial ? "≥" : ""
            lines.append("  \(m.label) [\(m.providers.map(\.displayName).sorted().joined(separator: ","))] tokens=\(m.tokens) requests=\(mark)\(m.requests) cost=\(m.cost.map { String(format: "%.2f", $0) } ?? "unpriced")")
        }
        lines.append("days: \(snapshot.byDay.count)")
        for d in snapshot.byDay.prefix(5) {
            lines.append("  \(d.label) tokens=\(d.tokens) requests=\(d.requestsPartial ? "≥" : "")\(d.requests) cost=\(String(format: "%.2f", d.cost ?? 0))")
        }
        lines.append("devices:")
        for d in snapshot.byDevice {
            let mark = d.unpriced ? "+" : ""
            lines.append("  \(d.label) tokens=\(d.tokens) requests=\(d.requestsPartial ? "≥" : "")\(d.requests) cost=\(d.cost.map { String(format: "%.2f", $0) } ?? "unpriced")\(mark) providers=\(d.providers.map(\.displayName).sorted().joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
    }
}
