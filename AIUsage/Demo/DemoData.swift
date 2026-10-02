import Foundation

/// `--demo` 用的合成数据。**截图里出现的每一个数、每个名字、每条路径都是这里编出来的。**
///
/// 两条硬约束：
///
/// - **确定性**：同一个种子每次跑出同一套数据。截图是提交进仓库的产物，
///   今天和下周跑出两套数，「这张图变了没有」就不能用来判断改动的影响了。
///   所以不用 `Int.random` / `Double.random`（系统 RNG 每次种子不同），用下面那个 xorshift。
/// - **走真管线**：记录照常过 `UsageStore.aggregate`，档案照常过 `syncNow` 那套合并。
///   数据是编的，算账的代码一行没换 —— 图上每个数都是真算出来的，
///   界面里那些口径（未计价、请求数下界、会话去重）该露的都露得出来。
enum DemoData {

    // MARK: 规模

    /// 本机铺 200 天。默认视图是近 90 天，环比还要再往前取一个等长窗口 —— 200 天两样都够。
    private static let localDays = 200
    /// 远端那台铺 245 天。多出来的这 45 天就是留存页「档案里有、本机日志已经没有」
    /// 那一列绿色数字的来源；不留出这个差，那一页最该被看见的数永远是 0。
    private static let remoteDays = 245

    private static let localSeed: UInt64 = 0x5EED_10CA_1D0C
    private static let remoteSeed: UInt64 = 0x5EED_5EED_2A45

    /// 演示档案里那个 App 版本，**不写死**：写死就会跟 `project.yml` 的 `MARKETING_VERSION`
    /// 各说各话（这个仓库里真发生过一次 —— 档案声称 1.0.0，App 其实是 0.1.0）。
    /// 跟 `UsageStore` / `ExportMenu` 一样从 bundle 读，版本号就只剩工程配置那一处。
    private static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    // MARK: 出口

    /// 本机（演示用 MacBook）的原始记录。`UsageStore.refresh()` 在演示模式下直接装这一份。
    static let localRecords: [UsageRecord] = makeRecords(seed: localSeed, days: localDays, scale: 1.0)

    /// 共享目录里会躺着的那几份档案。本机那份由本机记录聚合而来（与真同步写出去的形状一致），
    /// 另一份是远端设备的 —— 出图要展示「跨设备合并」这件事。
    static func deviceFiles() -> [DeviceFile] {
        let local = UsageStore.aggregate(localRecords)
        let remote = UsageStore.aggregate(makeRecords(seed: remoteSeed, days: remoteDays, scale: 0.62))
        return [
            DeviceFile(deviceId: DemoRuntime.demoDeviceId,
                       deviceName: DemoRuntime.demoLocalDeviceName,
                       appVersion: appVersion,
                       updatedAt: DemoRuntime.localDeviceUpdatedAt,
                       rows: local.rows, sessions: local.sessions),
            DeviceFile(deviceId: "demo-mac-studio",
                       deviceName: DemoRuntime.demoRemoteDeviceName,
                       appVersion: appVersion,
                       updatedAt: DemoRuntime.localDeviceUpdatedAt.addingTimeInterval(-7_200),
                       rows: remote.rows, sessions: remote.sessions),
        ]
    }

    // MARK: 价格表

    /// 演示用的价格表。**不走网络、不读缓存文件**：出图不能联网（慢，而且不可复现），
    /// 更不能把作者本机那份 LiteLLM 缓存读进来。
    ///
    /// 键照 LiteLLM 的写法，`PricingService` 的模糊匹配照常生效：
    /// `claude-sonnet-4-5-20250929` 会去掉日期后缀命中 `claude-sonnet-4-5`，
    /// `claude-sonnet-4-5-medium`（Devin 那档）同理。
    ///
    /// Qoder 的 `auto` 档**故意不放进来** —— 截图里要留一处「未计价」。
    /// 「价格表里查不到」和「价格是 0」是两回事，这是这个 App 最该说清楚的一条。
    static let priceTable: [String: ModelPrice] = [
        "claude-sonnet-4-5": .perMillion(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-opus-4-6": .perMillion(input: 15, output: 75, cacheRead: 1.50, cacheWrite: 18.75),
        "claude-haiku-4-5": .perMillion(input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25),
        "gpt-5-codex": .perMillion(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5.1": .perMillion(input: 1.25, output: 10, cacheRead: 0.125),
        "gpt-5": .perMillion(input: 1.25, output: 10, cacheRead: 0.125),
        "qwen3-coder-plus": .perMillion(input: 1, output: 5),
    ]

    // MARK: 生成

    /// 一个工具在一台设备上的用量形状。
    private struct Profile {
        let provider: ProviderKind
        let models: [String]
        /// 有活动的日子里当天的响应次数区间；周末与整体趋势另外再乘
        let requests: ClosedRange<Int>
        /// 平均几次响应并进一个会话 —— 会话数是去重后的，靠这个参数控制它与响应数的比例
        let requestsPerSession: Int
        /// 这一天会不会用这个工具。没人每天都把九个工具开满
        let dayChance: Double
        /// 单次响应的四个桶。缓存读比输入大一到两个数量级，这是真实 agent 的形状
        let input: ClosedRange<Int>
        let cacheRead: ClosedRange<Int>
        let cacheWrite: ClosedRange<Int>
        let output: ClosedRange<Int>
        /// 本地数据加密、只能数会话的工具（Windsurf / Antigravity）
        var sessionsOnly = false

        init(provider: ProviderKind, models: [String], requests: ClosedRange<Int>,
             requestsPerSession: Int, dayChance: Double, input: ClosedRange<Int>,
             cacheRead: ClosedRange<Int>, cacheWrite: ClosedRange<Int>, output: ClosedRange<Int>,
             sessionsOnly: Bool = false) {
            self.provider = provider
            self.models = models
            self.requests = requests
            self.requestsPerSession = requestsPerSession
            self.dayChance = dayChance
            self.input = input
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.output = output
            self.sessionsOnly = sessionsOnly
        }
    }

    private static let heavy = 900...4_500
    private static let heavyCacheRead = 30_000...180_000
    private static let heavyCacheWrite = 1_500...12_000
    private static let heavyOutput = 400...2_600

    private static let profiles: [Profile] = [
        // 主力。缓存写与缓存读都大 —— 这正是「缓存读的单价只有输入十分之一」那条账的来源
        Profile(provider: .claudeCode,
                models: ["claude-sonnet-4-5", "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-opus-4-6"],
                requests: 30...95, requestsPerSession: 45, dayChance: 0.88,
                input: heavy, cacheRead: heavyCacheRead, cacheWrite: heavyCacheWrite, output: heavyOutput),
        Profile(provider: .codex,
                models: ["gpt-5-codex", "gpt-5.1"],
                requests: 10...48, requestsPerSession: 30, dayChance: 0.62,
                input: 700...3_600, cacheRead: 16_000...90_000, cacheWrite: 900...6_000, output: 300...1_800),
        Profile(provider: .codexCLI,
                models: ["gpt-5-codex"],
                requests: 6...30, requestsPerSession: 22, dayChance: 0.45,
                input: 500...2_800, cacheRead: 9_000...54_000, cacheWrite: 600...4_000, output: 200...1_400),
        Profile(provider: .cursor,
                models: ["gpt-5", "claude-sonnet-4-5"],
                requests: 8...40, requestsPerSession: 35, dayChance: 0.5,
                input: 800...4_000, cacheRead: 12_000...70_000, cacheWrite: 1_000...7_000, output: 300...2_000),
        Profile(provider: .devin,
                models: ["claude-sonnet-4-5-medium"],
                requests: 3...18, requestsPerSession: 9, dayChance: 0.28,
                input: 2_000...9_000, cacheRead: 20_000...120_000, cacheWrite: 2_000...14_000, output: 800...4_000),
        Profile(provider: .qoder,
                // `auto` 不在价格表里 —— 那一行会以「未计价」出现，金额写成 ≥
                models: ["auto", "qwen3-coder-plus"],
                requests: 2...14, requestsPerSession: 10, dayChance: 0.24,
                input: 600...3_200, cacheRead: 5_000...30_000, cacheWrite: 400...3_000, output: 250...1_600),
        Profile(provider: .codebuddy,
                models: ["claude-sonnet-4-5", "claude-haiku-4-5"],
                requests: 4...22, requestsPerSession: 12, dayChance: 0.3,
                input: 500...3_000, cacheRead: 7_000...40_000, cacheWrite: 500...4_000, output: 200...1_500),
        // 这两个本地数据加密，只数会话 —— 主界面上它们 token 为 0、请求数写「—」，
        // 少了它们就看不出这套「拿不到 token 的环境怎么处理」
        Profile(provider: .windsurf,
                models: [], requests: 3...20, requestsPerSession: 1, dayChance: 0.35,
                input: 0...0, cacheRead: 0...0, cacheWrite: 0...0, output: 0...0, sessionsOnly: true),
        Profile(provider: .antigravity,
                models: [], requests: 2...14, requestsPerSession: 1, dayChance: 0.28,
                input: 0...0, cacheRead: 0...0, cacheWrite: 0...0, output: 0...0, sessionsOnly: true),
    ]

    private static func makeRecords(seed: UInt64, days: Int, scale: Double) -> [UsageRecord] {
        var rng = RNG(seed: seed)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [UsageRecord] = []

        for profile in profiles {
            for offset in 0..<days {
                guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
                let weekday = cal.component(.weekday, from: date)
                let weekend = weekday == 1 || weekday == 7
                // 今天必须有数据：截图里「今日」那几栏空着的话，菜单面板整块都看不出在干什么
                if offset > 0, rng.double() > profile.dayChance * (weekend ? 0.75 : 1) { continue }
                // 越近越忙（0.45 → 1.0），再叠一个周末折扣 —— 折线图要有形状，不能是一条平线
                let trend = 0.45 + 0.55 * (1 - Double(offset) / Double(days))
                let n = max(1, Int(Double(rng.int(profile.requests)) * trend * (weekend ? 0.4 : 1) * scale))

                if profile.sessionsOnly {
                    // 一个会话一条记录，四个桶全 0：`aggregate` 只把它计进每日会话数
                    for i in 0..<max(1, n / 6) {
                        out.append(UsageRecord(provider: profile.provider,
                                               sessionId: "\(profile.provider.rawValue)-\(DayKey.key(date))-\(i)",
                                               model: "",
                                               timestamp: stamp(date, cal: cal, rng: &rng),
                                               inputUncached: 0, cacheRead: 0, cacheWrite: 0, output: 0))
                    }
                    continue
                }

                let sessionCount = max(1, Int((Double(n) / Double(profile.requestsPerSession)).rounded()))
                for s in 0..<sessionCount {
                    let sessionId = "\(profile.provider.rawValue)-\(DayKey.key(date))-\(s)"
                    for _ in 0..<share(n, session: s, of: sessionCount) {
                        out.append(UsageRecord(provider: profile.provider,
                                               sessionId: sessionId,
                                               model: rng.pick(profile.models),
                                               timestamp: stamp(date, cal: cal, rng: &rng),
                                               inputUncached: rng.int(profile.input),
                                               cacheRead: rng.int(profile.cacheRead),
                                               cacheWrite: rng.int(profile.cacheWrite),
                                               output: rng.int(profile.output)))
                    }
                }
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    /// 把当天的响应数摊到几个会话上，余数从前面的会话开始补
    private static func share(_ total: Int, session: Int, of count: Int) -> Int {
        total / count + (session < total % count ? 1 : 0)
    }

    private static func stamp(_ day: Date, cal: Calendar, rng: inout RNG) -> Date {
        cal.date(bySettingHour: rng.int(8...23), minute: rng.int(0...59), second: rng.int(0...59), of: day) ?? day
    }
}

/// 出图要可复现，所以不能用系统 RNG（每次种子不同）。xorshift64：
/// 状态是几个整数、跨机器跨版本结果一致，`--demo` 的「同一份数据」才有保证。
private struct RNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }   // 0 是 xorshift 的不动点，会一直吐 0

    private mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// [0, 1)
    mutating func double() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }

    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
}
