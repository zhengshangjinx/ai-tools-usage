import AppKit
import Foundation

/// `--selftest`：一套不需要窗口、不联网、不碰用户数据的断言。
///
/// 为什么要有它：这个 app 里最容易出的错是**静默错** —— 解析口径差一档、桶键拼错、
/// 跨设备 schema 少读一个字段，屏幕上给出的都是「看着挺合理」的数字。没有断言就只能靠肉眼，
/// 而肉眼在缩略图和深色模式下不可靠（本项目已经栽过一次：明细表列错位，看了一轮才发现）。
///
/// 跑法：`AI\ Usage.app/Contents/MacOS/AI\ Usage --selftest`，全过退出码 0。
///
/// **两条数据安全红线，改这个文件时不要越过：**
/// 1. **绝不碰 `ScanCache.shared`。** 它读写用户的
///    `~/Library/Application Support/AIUsage/scan_cache_v3.json`，而且
///    `removeSupersededCacheFiles()` 会删掉同目录下别的 `scan_cache_v*.json` ——
///    拿 fixture 跑一遍公开的 `scan(paths:)` 就会污染甚至误删用户的真实缓存。
///    所以解析器的断言一律直接调 `scanFile(_:)`（为此把两个 provider 的 `scanFile`
///    从 private 提到了 internal，**只动可见性、没动逻辑**），fixture 建在临时目录里、跑完自删。
/// 2. **绝不写 `UserDefaults.standard`，也绝不写用户配置所在的任何域。** 尤其
///    `PricingService.overrides` 带 `didSet { saveOverrides() }`：给它赋个测试价就等于覆盖用户手填的单价。
///    需要验读写的设置项（第 8 组的 `AppBehaviorSettings`）走**注入的一次性 suite**
///    —— `UserDefaults(suiteName: "aiusage.selftest.<UUID>")`，跑完 `removePersistentDomain` 拆掉，
///    它与 App 的配置域没有任何关系。**不许为了方便直接 `AppBehaviorSettings()`**：那会拿到
///    `.standard`，写一下就把用户设置改了，而且是**静默**改（这一组恰好就是在验写入）。
///    其余全程只读，需要确定价格的地方用 `ModelPrice` 这个纯值类型自己构造。
///
/// `@MainActor`：`PricingService` 上的纯函数（如 `candidates(for:)`）是主线程隔离的，
/// 而整个自测本来就在 `applicationDidFinishLaunching` 里同步跑，隔离在同一处，不需要跨线程。
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    // MARK: 断言工装

    private static var passes = 0
    private static var failures: [String] = []

    private static func group(_ title: String) {
        print("\n\(title)")
    }

    private static func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            passes += 1
            print("  ✓ \(name)")
        } else {
            let d = detail()
            failures.append(d.isEmpty ? name : "\(name) — \(d)")
            print("  ✗ \(name)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    private static func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        expect(name, got == want, "得到 \(got)，期望 \(want)")
    }

    // MARK: 入口

    /// 同步跑完并 exit。**同步**是有意的：这样 `applicationDidFinishLaunching` 还没返回，
    /// SwiftUI 也就还没建窗口 —— 跑测试不会在屏幕上闪一个窗口出来。
    static func runAndExit() -> Never {
        print("AI 用量统计 · 自测")
        testSchemaCompatibility()
        testClaudeCodeParser()
        testCodexParser()
        testAggregate()
        testPureFunctions()
        testExport()
        testRetention()
        testMenuBarLabel()
        testWindowLifecycle()
        testUpdateLogic()
        print("\n" + String(repeating: "─", count: 46))
        if failures.isEmpty {
            print("自测通过：\(passes) 项断言全部成立")
            exit(0)
        }
        print("自测失败：\(failures.count) 项不成立（通过 \(passes) 项）")
        for f in failures { print("  · \(f)") }
        exit(1)
    }

    // MARK: 1. 跨设备 schema 兼容（最高危的一组）

    /// 每台设备只写自己那份档案，所以本机读到的常常是**旧版本 App 写的文件**。
    /// `AggregateRow.requests` 是后加的字段，缺了必须当 0 而不是让整份档案解析失败 ——
    /// 一台还没升级的设备会让它全部历史从汇总里消失，而且界面上只表现为「数字变小了」。
    private static func testSchemaCompatibility() {
        group("1. 跨设备档案兼容")
        // 这个版本号是**单向闸门**（读到更高版本会跳过整份档案），改它必须是有意识的决定
        equal("DeviceFile.currentSchema 仍是 1", DeviceFile.currentSchema, 1)

        let withoutRequests = """
        {"schema":1,"deviceId":"old-device","deviceName":"老机器","appVersion":"0.0.9","updatedAt":790000000,
         "rows":[{"day":"2026-05-01","provider":"claudeCode","model":"m",
                  "inputUncached":10,"cacheRead":2,"cacheWrite":3,"output":5}],
         "sessions":[{"day":"2026-05-01","provider":"claudeCode","count":4}]}
        """
        guard let old = try? JSONDecoder().decode(DeviceFile.self, from: Data(withoutRequests.utf8)) else {
            expect("旧档案（无 requests 字段）能解码", false, "解码直接失败 —— 旧设备的历史会整份消失")
            return
        }
        expect("旧档案（无 requests 字段）能解码", true)
        equal("旧档案 rows 读得出来", old.rows.count, 1)
        equal("旧档案 token 桶不受影响", old.rows.first?.total, 20)
        equal("缺 requests 当 0", old.rows.first?.requests, 0)
        expect("缺 requests 标记为「只有下界」", old.rows.first?.requestsUnknown == true)
        equal("旧档案会话数读得出来", old.sessions.first?.count, 4)

        let withRequests = """
        {"schema":1,"deviceId":"new-device","deviceName":"新机器","appVersion":"0.1.0","updatedAt":790000000,
         "rows":[{"day":"2026-05-01","provider":"claudeCode","model":"m",
                  "inputUncached":10,"cacheRead":0,"cacheWrite":0,"output":5,"requests":7}],
         "sessions":[]}
        """
        guard let new = try? JSONDecoder().decode(DeviceFile.self, from: Data(withRequests.utf8)) else {
            expect("新档案能解码", false, "解码失败")
            return
        }
        equal("有 requests 就原样保留", new.rows.first?.requests, 7)
        expect("有 requests 时不标下界", new.rows.first?.requestsUnknown == false)

        // 「真的是 0 次」和「数不出来」必须分得开：只有 total > 0 且 requests == 0 才算未知
        let zeroTotal = AggregateRow(day: "2026-05-01", provider: .windsurf, model: "m",
                                     inputUncached: 0, cacheRead: 0, cacheWrite: 0, output: 0, requests: 0)
        expect("没有 token 的行不算「请求数未知」，它本来就数不出来", zeroTotal.requestsUnknown == false)
    }

    // MARK: 2a. Claude Code 解析

    private static func testClaudeCodeParser() {
        group("2a. Claude Code 解析器")
        let dir = tempDir("claude")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")

        write([
            // 同一次响应写了三行：前两行是流式占位（usage 全 0），只有最后一行带真实用量。
            // 这是实测踩过的坑 —— 按「先到先得」去重会让整个请求消失（占位行把 key 占了位）。
            ccLine(uuid: "u1", msgId: "m1", requestId: "r1", input: 0, cacheRead: 0, cacheWrite: 0, output: 0),
            ccLine(uuid: "u2", msgId: "m1", requestId: "r1", input: 0, cacheRead: 0, cacheWrite: 0, output: 0),
            ccLine(uuid: "u3", msgId: "m1", requestId: "r1", input: 100, cacheRead: 40, cacheWrite: 10, output: 7),
            // 同一次响应重复写了两遍，**后来那条更小**：不能被顶掉（要取用量大的那条）
            ccLine(uuid: "u4", msgId: "m2", requestId: "r2", input: 500, cacheRead: 0, cacheWrite: 0, output: 100),
            ccLine(uuid: "u5", msgId: "m2", requestId: "r2", input: 20, cacheRead: 0, cacheWrite: 0, output: 20),
            // 完全不带用量的记录（既不是 assistant 的 usage，也没有 token）不进表
            ccLine(uuid: "u6", msgId: "m3", requestId: "r3", input: 0, cacheRead: 0, cacheWrite: 0, output: 0),
        ], to: file)

        let recs = ClaudeCodeProvider().scanFile(file)
        equal("两次响应算两条记录（占位行与重复行都不算）", recs.count, 2)
        equal("用量取「最大的那条」而不是「最早的那条」", recs.map(\.total).sorted(), [157, 600])
        if let small = recs.first(where: { $0.total == 157 }) {
            equal("分量对得上：uncached", small.inputUncached, 100)
            equal("分量对得上：cache read", small.cacheRead, 40)
            equal("分量对得上：cache write", small.cacheWrite, 10)
            equal("分量对得上：output", small.output, 7)
            equal("处理量 = 四个分量之和", small.total,
                  small.inputUncached + small.cacheRead + small.cacheWrite + small.output)
        } else {
            expect("分量对得上", false, "没找到那条 157 token 的记录")
        }
        expect("用量为 0 的记录不进表（tokens > 0 ⟺ requests ≥ 1 的根）",
               recs.allSatisfy { $0.total > 0 })
        equal("环境归属正确", recs.first?.provider, .claudeCode)
        equal("会话 id 取文件内字段", recs.first?.sessionId, "sess-1")
    }

    private static func ccLine(uuid: String, msgId: String, requestId: String,
                              input: Int, cacheRead: Int, cacheWrite: Int, output: Int) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","requestId":"\(requestId)","sessionId":"sess-1",
         "timestamp":"2026-05-01T10:00:00.000Z",
         "message":{"id":"\(msgId)","model":"claude-sonnet-4-5",
                    "usage":{"input_tokens":\(input),"output_tokens":\(output),
                             "cache_read_input_tokens":\(cacheRead),"cache_creation_input_tokens":\(cacheWrite)}}}
        """
    }

    // MARK: 2b. Codex 解析

    private static func testCodexParser() {
        group("2b. Codex 解析器")
        let dir = tempDir("codex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("rollout-2026-05-01T10-00-00-abc.jsonl")

        func tokenCount(at ts: String, input: Int, cached: Int, cacheWrite: Int, output: Int) -> String {
            """
            {"type":"event_msg","timestamp":"\(ts)",
             "payload":{"type":"token_count","info":{"last_token_usage":
               {"input_tokens":\(input),"cached_input_tokens":\(cached),
                "cache_write_input_tokens":\(cacheWrite),"output_tokens":\(output)}}}}
            """
        }
        write([
            // 子代理 / fork 线程：文件开头把父线程历史整批复制过来，时间戳重打成同一秒
            """
            {"type":"session_meta","timestamp":"2026-05-01T10:00:00.000Z",
             "payload":{"id":"forked-1","forked_from_id":"parent-1","originator":"codex_cli_rs"}}
            """,
            // 模型来自最近一条 turn_context，且**它出现之前的 token_count 一律不计** ——
            // 所以这条必须在事件前面，否则整个文件一条记录都算不出来
            """
            {"type":"turn_context","timestamp":"2026-05-01T10:00:00.050Z","payload":{"model":"gpt-5-codex"}}
            """,
            tokenCount(at: "2026-05-01T10:00:00.100Z", input: 900, cached: 0, cacheWrite: 0, output: 100),
            tokenCount(at: "2026-05-01T10:00:00.300Z", input: 800, cached: 0, cacheWrite: 0, output: 200),
            // 真实的首次响应（数秒之后）—— 这条必须留下
            tokenCount(at: "2026-05-01T10:00:07.000Z", input: 1000, cached: 400, cacheWrite: 100, output: 50),
            // 连续重复投递（限额刷新时重发）只算一次
            tokenCount(at: "2026-05-01T10:00:08.000Z", input: 1000, cached: 400, cacheWrite: 100, output: 50),
            // 换一次真实用量：算新的一次
            tokenCount(at: "2026-05-01T10:00:09.000Z", input: 2000, cached: 500, cacheWrite: 0, output: 60),
            tokenCount(at: "2026-05-01T10:00:10.000Z", input: 300, cached: 100, cacheWrite: 0, output: 20),
        ], to: file)

        let recs = CodexProvider().scanFile(file)
        // fork 复制的那两条被丢掉；重复投递的那条被丢掉；剩下三条
        equal("fork 复制的父线程历史全部丢弃，重复投递只算一次", recs.count, 3)
        expect("fork 复制的那两条不在结果里", !recs.contains { $0.inputUncached == 900 || $0.inputUncached == 800 })
        // input_tokens 含 cached 与 cache_write，必须扣掉才是「未缓存输入」：
        // 1000-400-100=500，2000-500=1500，300-100=200
        equal("input_tokens 扣掉 cached 与 cache_write", recs.map(\.inputUncached), [500, 1500, 200])
        if let first = recs.first {
            equal("cached 进 cache read 桶", first.cacheRead, 400)
            equal("cache_write 单独成桶", first.cacheWrite, 100)
            equal("output 原样", first.output, 50)
        }
        equal("模型取自最近的 turn_context", recs.last?.model, "gpt-5-codex")
        equal("originator 含 cli 时归到 Codex CLI", recs.first?.provider, .codexCLI)
        equal("会话 id 取 session_meta 里的那个", recs.first?.sessionId, "forked-1")
    }

    // MARK: 3. 聚合

    private static func testAggregate() {
        group("3. 聚合口径")
        let d1 = ParseUtil.date(from: "2026-05-01T10:00:00Z")!
        let d2 = ParseUtil.date(from: "2026-05-02T10:00:00Z")!
        let day1 = DayKey.key(Calendar.current.startOfDay(for: d1))
        let day2 = DayKey.key(Calendar.current.startOfDay(for: d2))

        func rec(_ day: Date, _ model: String, _ session: String,
                 _ i: Int, _ cr: Int, _ cw: Int, _ o: Int) -> UsageRecord {
            UsageRecord(provider: .claudeCode, sessionId: session, model: model, timestamp: day,
                        inputUncached: i, cacheRead: cr, cacheWrite: cw, output: o)
        }
        let records = [
            rec(d1, "model-a", "s1", 10, 0, 0, 5),
            rec(d1, "model-a", "s2", 20, 0, 0, 5),
            // 仅会话记录（本地数据加密的环境就是这个形状）：只计会话，不进 token 桶
            rec(d1, "model-b", "s3", 0, 0, 0, 0),
            rec(d2, "model-a", "s4", 1, 0, 0, 1),
        ]
        let out = UsageStore.aggregate(records)

        equal("桶键 = 日 × 环境 × 模型，两天两模型 → 2 行", out.rows.count, 2)
        let a1 = out.rows.first { $0.day == day1 && $0.model == "model-a" }
        equal("同一桶里的 tokens 相加", a1?.total, 40)
        equal("同一桶里的请求数 = 记录条数（一条记录 ≈ 一次响应）", a1?.requests, 2)
        expect("仅会话记录不进 token 桶", !out.rows.contains { $0.model == "model-b" })

        let s1 = out.sessions.first { $0.day == day1 && $0.provider == .claudeCode }
        equal("会话数把「仅会话」那条也算上", s1?.count, 3)
        equal("每天的会话行独立", out.sessions.count, 2)

        // 桶的顺序必须稳定：它决定了档案文件的字节内容，顺序飘了每次同步都在改文件
        let again = UsageStore.aggregate(records.reversed())
        equal("输入顺序不影响输出行序", again.rows.map(\.model), out.rows.map(\.model))
        equal("输入顺序不影响输出行数", again.rows.count, out.rows.count)
    }

    // MARK: 4. 纯函数（便宜就一起钉住）

    private static func testPureFunctions() {
        group("4. 格式化 / 排序 / 计价")

        // 机器读的日期列必须钉住 POSIX 区域：跟机的 locale 下可能吐出非 ASCII 数字
        let day = DayKey.date("2026-05-01")!
        equal("DayKey 往返一致", DayKey.key(day), "2026-05-01")
        expect("DayKey 输出是纯 ASCII 数字", DayKey.key(Date()).allSatisfy { $0.isASCII })
        expect("DayKey 输出形状是 yyyy-MM-dd", DayKey.key(Date()).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)

        func row(_ label: String, tokens: Int, cost: Double?, requests: Int) -> BreakdownRow {
            BreakdownRow(id: label, label: label, providers: [.claudeCode], tokens: tokens,
                         cost: cost, day: nil, requests: requests)
        }
        let rows = [row("a", tokens: 100, cost: 1.0, requests: 5),
                    row("b", tokens: 300, cost: nil, requests: 0),
                    row("c", tokens: 200, cost: 2.0, requests: 9)]

        equal("默认按费用降序", BreakdownSort().apply(to: rows).map(\.label), ["c", "a", "b"])
        expect("未计价行（cost 为 nil）在降序里沉底", BreakdownSort().apply(to: rows).last?.label == "b")

        var byTokens = BreakdownSort(); byTokens.key = .tokens
        equal("按 tokens 降序", byTokens.apply(to: rows).map(\.label), ["b", "c", "a"])

        var byRequests = BreakdownSort(); byRequests.key = .requests
        equal("按请求数降序", byRequests.apply(to: rows).map(\.label), ["c", "a", "b"])

        // 每一档都得有兜底键，否则同值的两行位置会随重排漂移（sorted 在 Swift 里不稳定）
        let ties = [row("x", tokens: 5, cost: 1.0, requests: 1), row("y", tokens: 5, cost: 1.0, requests: 1)]
        equal("同值时按名称兜底，顺序确定", BreakdownSort().apply(to: ties).map(\.label), ["x", "y"])

        // 占比口径跟着排序口径走：排费用读费用占比，排 tokens 读 token 占比
        var snap = UsageSnapshot()
        snap.totals.processed = 400
        snap.totals.cost = 4.0
        snap.totals.requests = 14
        equal("费用口径占比 = 本行 / 总额", snap.share(of: rows[0], by: .cost), 1.0 / 4.0)
        equal("tokens 口径占比", snap.share(of: rows[0], by: .tokens), 100.0 / 400.0)
        equal("请求数口径占比", snap.share(of: rows[0], by: .requests), 5.0 / 14.0)
        expect("未计价行在费用口径下没有占比（下界不该当分子）", snap.share(of: rows[1], by: .cost) == nil)

        // 计价对四个桶是线性的 —— 跨设备只传桶、不传钱，全靠这条
        let p = ModelPrice.perMillion(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)
        expect("百万 tokens 输入 = $3", abs(p.cost(inputUncached: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 0) - 3) < 1e-9)
        expect("百万 tokens 输出 = $15", abs(p.cost(inputUncached: 0, cacheRead: 0, cacheWrite: 0, output: 1_000_000) - 15) < 1e-9)
        expect("未填 cache 价时沿用 input 价",
               ModelPrice.perMillion(input: 3, output: 15).cacheReadRate == ModelPrice.perMillion(input: 3, output: 15).inputRate)

        // 模型标识的模糊匹配：账单上写的是带日期/档位后缀的名字，价格表里是短名字
        let c = PricingService.candidates(for: "claude-sonnet-4-5-20250929-medium")
        expect("候选里含去掉档位后缀的名字", c.contains("claude-sonnet-4-5-20250929"))
        expect("候选里含去掉日期后缀的名字", c.contains("claude-sonnet-4-5"))
        expect("候选里含点号写法", c.contains("claude-sonnet-4.5"))

        // 逐行解析：只吐带标记的行，坏行跳过而不是整份失败
        let dir = tempDir("parse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("x.jsonl")
        write(["{\"keep\":1}", "{\"skip\":2}", "这不是 JSON", "{\"keep\":3}"], to: f)
        var kept: [Int] = []
        ParseUtil.forEachLine(in: f, containingAny: ["\"keep\"".data(using: .utf8)!]) { obj in
            kept.append(ParseUtil.int(obj["keep"]))
        }
        equal("只吐带标记的行，坏行跳过", kept, [1, 3])
        equal("ParseUtil.int 认得字符串数字", ParseUtil.int("42" as Any), 42)
        expect("ParseUtil.date 认得 ISO8601 毫秒", ParseUtil.date(from: "2026-05-01T10:00:00.000Z") != nil)
    }

    // MARK: 5. 导出（黄金输出）

    /// 导出是「所见即所得」的最后一环，也是最容易悄悄坏的一环：BOM 少一个字节、
    /// 行尾从 CRLF 变成 LF、含逗号的中文标签没加引号 —— 屏幕上一切正常，
    /// 拿到 Excel 里才炸。所以这一组断言全部按**字节**比，而不是「看着像对」。
    private static func testExport() {
        group("5. 导出")

        // 一个「按模型」的样本：一行有价、一行未计价、一行的标签同时含**半角逗号与全角括号**
        // （这是最容易验出转义写错的那种值），标签本身也是真实形状
        let day = DayKey.date("2026-05-01")!
        let commaLabel = "gpt-5（日常, 常用）"
        let unpricedLabel = "某未计价模型"
        let rows = [
            BreakdownRow(id: "with-comma", label: commaLabel, providers: [.claudeCode, .codex],
                         tokens: 300, cost: 1.5, day: nil, requests: 12,
                         deviceIds: ["d1"], providerTokens: [.claudeCode: 200, .codex: 100],
                         components: TokenComponents(inputUncached: 100, cacheRead: 150, cacheWrite: 20, output: 30)),
            BreakdownRow(id: "unpriced", label: unpricedLabel, providers: [.devin],
                         tokens: 100, cost: nil, day: nil, requests: 0,
                         components: TokenComponents(inputUncached: 40, cacheRead: 60, cacheWrite: 0, output: 0)),
        ]
        var totals = UsageTotals()
        totals.processed = 400
        totals.cost = 1.5
        totals.requests = 12
        totals.unpricedTokens = 100

        let ctx = ExportContext(
            mode: .model, sort: BreakdownSort(),
            rows: rows, totals: totals,
            share: { r in r.cost.map { $0 / 1.5 } },
            // 「按模型」维度下行的 label 就是模型标识，所以查询键是 label
            price: { $0 == commaLabel ? ModelPrice.perMillion(input: 3, output: 15) : nil },
            priceSource: { $0 == commaLabel ? .table : .none },
            priceTableUpdated: Date(timeIntervalSince1970: 1_790_000_000),
            rangeStart: day, rangeEnd: day,
            selectedProviders: [.claudeCode, .codex, .devin],
            deviceLabel: "全部设备 · 2 台", appVersion: "0.1.0")

        // ── 表格格式：BOM、CRLF、转义 ──
        for format in [ExportFormat.csv, .tsv] {
            let sep: Character = format == .tsv ? "\t" : ","
            let text = UsageExporter.table(ctx, format: format)
            let bytes = Array(text.utf8)
            expect("\(format.fileTag): 前三字节是 UTF-8 BOM（Excel 打开中文才不乱码）",
                   bytes.count > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF,
                   "实际 \(bytes.prefix(3).map { String(format: "%02X", $0) }.joined(separator: " "))")
            expect("\(format.fileTag): 行尾是 CRLF 不是 LF",
                   text.contains("\r\n") && !text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            expect("\(format.fileTag): 末尾有换行（最后一行的行尾也补全）", text.hasSuffix("\r\n"))
            expect("\(format.fileTag): 表头固定且是 ASCII",
                   text.contains("dimension\(sep)date\(sep)label\(sep)providers\(sep)tokens\(sep)requests\(sep)requests_partial\(sep)cost_usd\(sep)cost_partial\(sep)share"))
            // 「按需加引号」是 RFC 4180 的要求，两种格式的**触发条件不同**：
            // CSV 里这个标签含逗号所以要包引号，TSV 里逗号不是分隔符、原样写才对。
            if format == .csv {
                expect("csv: 含逗号与全角括号的标签被引号包住", text.contains("\"\(commaLabel)\""))
            } else {
                expect("tsv: 逗号不是分隔符，标签原样写（不加无谓的引号）", text.contains("\t\(commaLabel)\t"))
            }
            expect("\(format.fileTag): 多个环境用分号连接",
                   text.contains("Claude Code;Codex"))
            expect("\(format.fileTag): 未计价行的 cost_usd 留空而不是 0",
                   text.contains("\(unpricedLabel)\(sep)Devin\(sep)100\(sep)\(sep)true\(sep)\(sep)true\(sep)"))
            expect("\(format.fileTag): 量不到的请求数留空、requests_partial 为 true",
                   text.contains("\(sep)\(sep)true\(sep)"))
            expect("\(format.fileTag): 数得准的请求数原样写、partial 为 false",
                   text.contains("\(sep)12\(sep)false\(sep)"))
            expect("\(format.fileTag): 金额保留 6 位小数（不截成 1.5）", text.contains("1.500000"))
            expect("\(format.fileTag): 维度列写 ASCII 的 fileTag 而不是中文",
                   text.contains("model\(sep)") && !text.contains("按模型\(sep)"))
        }

        // 转义规则单独钉一遍：只在该加的时候加
        equal("转义：干净的值不加引号", UsageExporter.escape("abc", separator: ","), "abc")
        equal("转义：含分隔符要加引号", UsageExporter.escape("a,b", separator: ","), "\"a,b\"")
        equal("转义：含引号要翻倍", UsageExporter.escape("a\"b", separator: ","), "\"a\"\"b\"")
        equal("转义：换行要加引号", UsageExporter.escape("a\nb", separator: ","), "\"a\nb\"")
        equal("转义：TSV 里逗号不用引号", UsageExporter.escape("a,b", separator: "\t"), "a,b")
        equal("转义：TSV 里的制表符要引号", UsageExporter.escape("a\tb", separator: "\t"), "\"a\tb\"")

        // ── JSON ──
        let jsonText = UsageExporter.json(ctx)
        expect("JSON: 不带 BOM（读取方按 UTF-8 解，多一个 BOM 会噎住）",
               !jsonText.hasPrefix("\u{FEFF}"))
        guard let obj = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let jsonRows = obj["rows"] as? [[String: Any]], jsonRows.count == 2 else {
            expect("JSON: 能解析回来", false, "解析失败或行数不对")
            return
        }
        expect("JSON: 能解析回来", true)
        equal("JSON: 维度写 ASCII fileTag", meta["dimension"] as? String, "model")
        equal("JSON: 元信息带范围", meta["range_start"] as? String, "2026-05-01")
        equal("JSON: 币种写死 USD", meta["currency"] as? String, "USD")
        expect("JSON: 元信息带价格表版本（否则几个月后这份账没法复算）",
               meta["price_table_updated"] is String)
        // 两个键**先确认找得到、再比位置**。写成 `range(of:)!` 的话，哪天 JSON 的键改了名，
        // 这里不会打印一条失败项，而是直接 SIGTRAP —— 崩溃报告躺进 `~/Library/Logs/DiagnosticReports`，
        // 看着像产品崩了，其实是自测自己踩空了（2026-09-25 19:37 那份报告就是这么来的）。
        // 自测红了必须能一眼看到是哪一项，不能以「炸了」的形式表达。
        if let dimAt = jsonText.range(of: "\"dimension\"")?.lowerBound,
           let expAt = jsonText.range(of: "\"exported_at\"")?.lowerBound {
            expect("JSON: 排序键有序输出（每次导出 diff 不该是噪音）", dimAt < expAt)
        } else {
            expect("JSON: 排序键有序输出（每次导出 diff 不该是噪音）", false,
                   "JSON 里找不到 dimension / exported_at 键")
        }
        expect("JSON: 汇总数与明细行平级，不塞进元信息",
               obj["totals"] is [String: Any] && meta["totals"] == nil)

        let priced = jsonRows.first { ($0["label"] as? String) == commaLabel }
        expect("JSON: 找得到那一行含逗号的标签", priced != nil)
        guard let priced else { return }
        let comp = priced["tokens_components"] as? [String: Any]
        equal("JSON: 分量齐四个", comp?.count, 5)
        equal("JSON: 分量和的差额写进 unclassified", comp?["unclassified"] as? Int, 0)
        expect("JSON: 单价来自价格表时 source 写 table",
               (priced["prices"] as? [String: Any])?["source"] as? String == "table")
        equal("JSON: 请求数原样", priced["requests"] as? Int, 12)

        let unpriced = jsonRows.first { ($0["label"] as? String) == unpricedLabel }
        expect("JSON: 找得到那一行未计价的", unpriced != nil)
        guard let unpriced else { return }
        expect("JSON: 未计价行的 cost_usd 是 null 而不是 0", unpriced["cost_usd"] is NSNull)
        expect("JSON: 未计价行标 cost_partial（下游求和时要知道它偏小）", unpriced["cost_partial"] as? Bool == true)
        expect("JSON: 未计价行的单价是 null", unpriced["prices"] is NSNull)
        expect("JSON: 数不出来的请求数是 null，不是 0", unpriced["requests"] is NSNull)
        expect("JSON: 数不出来的请求数标 partial", unpriced["requests_partial"] as? Bool == true)
        expect("JSON: 未计价行没有占比", unpriced["share"] is NSNull)

        // 非「按模型」维度：单价那一列恒为 null，下游不用先判断维度
        var dayCtx = ctx
        dayCtx.mode = .day
        dayCtx.rows = [BreakdownRow(id: "d", label: "05-01", providers: [.codex], tokens: 10,
                                    cost: 0.5, day: day, requests: 3)]
        if let d = try? JSONSerialization.jsonObject(with: Data(UsageExporter.json(dayCtx).utf8)) as? [String: Any],
           let r = (d["rows"] as? [[String: Any]])?.first {
            expect("JSON: 按日期维度下单价列是 null", r["prices"] is NSNull)
            equal("JSON: 按日期维度下 date 是 ISO 那一天", r["date"] as? String, "2026-05-01")
        } else {
            expect("JSON: 按日期维度能解析", false, "解析失败")
        }

        // 分量对不上时必须如实报差额，不许摊进 input：
        // 造一行「总数 400、分量和只有 300」的，导出里的 unclassified 必须是 100
        let inconsistent = BreakdownRow(id: "x", label: "对不上的行", providers: [.codex],
                                        tokens: 400, cost: nil, day: nil, requests: 1,
                                        components: TokenComponents(inputUncached: 100, cacheRead: 150,
                                                                    cacheWrite: 20, output: 30))
        var inconsistentCtx = ctx
        inconsistentCtx.rows = [inconsistent]
        if let o = try? JSONSerialization.jsonObject(with: Data(UsageExporter.json(inconsistentCtx).utf8)) as? [String: Any],
           let comp = ((o["rows"] as? [[String: Any]])?.first)?["tokens_components"] as? [String: Any] {
            equal("分量和小于总数时如实报 unclassified", comp["unclassified"] as? Int, 100)
            equal("分量本身照原样报，不被摊平", comp["input_uncached"] as? Int, 100)
        } else {
            expect("分量和不一致的行能导出", false, "解析失败")
        }

        // ── 默认文件名 ──
        let name = UsageExporter.defaultFileName(ctx, format: .csv)
        expect("文件名带维度与范围，且后缀正确",
               name.hasSuffix(".csv") && name.contains("按模型") && name.contains("2026-05-01至2026-05-01"),
               name)

        // ── 空数据 ──
        var emptyCtx = ctx
        emptyCtx.rows = []
        let emptyCSV = UsageExporter.table(emptyCtx, format: .csv)
        expect("空结果只出表头，不出垃圾行",
               emptyCSV.replacingOccurrences(of: "\u{FEFF}", with: "").split(separator: "\r\n").count == 1)
        expect("空结果也是合法 JSON", (try? JSONSerialization.jsonObject(with: Data(UsageExporter.json(emptyCtx).utf8))) != nil)
    }

    // MARK: 6. 留存报告（纯计算）

    /// 「显示与留存」那一页的说服力全在两个**天的集合**的差上：
    /// 「档案里有、本机日志里已经没有的天数」要是算错，页面就会把「另一台设备的日子」
    /// 说成「本地被删了的日子」，或者反过来把真丢了的日子藏起来 —— 两种都是静默错。
    ///
    /// 这里**只用临时目录里的 fixture 跑**：`readCleanupPeriodDays(path:)` 显式传路径，
    /// `make(...)` 走那个不碰文件系统的重载，所以自测一次都不会读用户真实的那份设置文件。
    private static func testRetention() {
        group("6. 留存报告")

        // ── 读 cleanupPeriodDays：只取这一个键 ──
        // fixture 里那个 token 是**明显假的占位串**，用来证明我们不去看别的键 ——
        // 与任何真实凭据无关，也不会被打印出来（只有 cleanupPeriodDays 会进断言）
        let dir = tempDir("retention")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = dir.appendingPathComponent("settings.json")
        write(["{\"cleanupPeriodDays\": 370, \"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"sk-FIXTURE-NOT-A-REAL-KEY\"}}"], to: cfg)
        let r1 = RetentionReport.readCleanupPeriodDays(path: cfg.path)
        equal("只取 cleanupPeriodDays，别的键一律不看", r1.value, 370)
        expect("文件在就说在", r1.fileExists)

        write(["{\"env\": {}}"], to: cfg)
        let r2 = RetentionReport.readCleanupPeriodDays(path: cfg.path)
        equal("没设过这个键 → nil（不是 0）", r2.value, Int?.none)
        expect("没设过键但文件存在，两件事要分得开", r2.fileExists)

        write(["{\"cleanupPeriodDays\": \"90\"}"], to: cfg)
        equal("写成字符串也认", RetentionReport.readCleanupPeriodDays(path: cfg.path).value, 90)

        write(["这不是 JSON"], to: cfg)
        equal("文件坏了 → 当作没设置，不抛不崩", RetentionReport.readCleanupPeriodDays(path: cfg.path).value, Int?.none)

        let missing = RetentionReport.readCleanupPeriodDays(path: dir.appendingPathComponent("nope.json").path)
        equal("文件不存在 → nil", missing.value, Int?.none)
        expect("文件不存在要说清楚（跟「没设置」不是一回事）", missing.fileExists == false)
        expect("建议值 370 在片段里", RetentionReport.cleanupSnippet().contains("370"))

        // ── 天的集合：计数与首尾 ──
        let span = CoverageSpan(provider: .claudeCode, dayKeys: ["2026-09-25", "2026-09-13", "2026-09-20"])
        equal("「天」= 集合大小，不是首尾相隔的天数", span.days, 3)
        equal("首 = 最小键（ASCII 定长，字典序即时间序）", span.first, "2026-09-13")
        equal("尾 = 最大键", span.last, "2026-09-25")
        expect("空集合没有首尾", CoverageSpan(provider: .codex).first == nil)
        expect("空集合的日子文本是「无」", CoverageSpan(provider: .codex).rangeText == "无")

        // ── 集合差：这一页的判据 ──
        let local = CoverageSpan(provider: .claudeCode, dayKeys: ["2026-09-13", "2026-09-14", "2026-09-15"])
        let archive = CoverageSpan(provider: .claudeCode,
                                   dayKeys: ["2026-09-11", "2026-09-12", "2026-09-13", "2026-09-14"])
        let cmp = RetentionComparison(provider: .claudeCode, local: local, archive: archive)
        equal("只在档案里 = 差集大小", cmp.archiveOnlyDays, 2)
        equal("只在本机 = 反向差集", cmp.localOnlyDays, 1)

        // 只比首尾会漏掉这一种：首尾一模一样，中间少了一片
        let l2 = CoverageSpan(provider: .codex, dayKeys: ["2026-04-18", "2026-04-19", "2026-09-14"])
        let a2 = CoverageSpan(provider: .codex,
                              dayKeys: ["2026-04-18", "2026-04-19", "2026-04-20", "2026-09-14"])
        equal("首尾相同、中间缺天也要算得出来（只比首尾就漏了）",
              RetentionComparison(provider: .codex, local: l2, archive: a2).archiveOnlyDays, 1)

        // ── 拼一份现状 ──
        func rec(_ p: ProviderKind, _ day: String) -> UsageRecord? {
            guard let d = DayKey.date(day) else { return nil }
            return UsageRecord(provider: p, sessionId: "s", model: "m", timestamp: d,
                               inputUncached: 10, cacheRead: 0, cacheWrite: 0, output: 1)
        }
        func row(_ day: String, _ p: ProviderKind, requests: Int, model: String = "m") -> AggregateRow {
            AggregateRow(day: day, provider: p, model: model,
                         inputUncached: 1, cacheRead: 0, cacheWrite: 0, output: 1, requests: requests)
        }
        let recs = ["2026-09-13", "2026-09-14"].compactMap { rec(.claudeCode, $0) }
        let file = DeviceFile(deviceId: "A", deviceName: "本机", appVersion: "0.1.0", updatedAt: Date(),
                              rows: [row("2026-09-13", .claudeCode, requests: 1),
                                     row("2026-09-10", .claudeCode, requests: 1),
                                     row("2026-09-11", .claudeCode, requests: 0)],
                              sessions: [SessionCountRow(day: "2026-09-12", provider: .windsurf, count: 2)])

        let report = RetentionReport.make(records: recs, deviceFiles: [file],
                                          cleanupPeriodDays: nil, settingsFileExists: true)
        equal("生效值：没设置就是默认 30", report.effectiveCleanupDays, 30)
        equal("没设置 → 配置态是 false", report.isCleanupConfigured, false)
        equal("只出有数据的环境，顺序照 ProviderKind.allCases（全无数据的环境不占行）",
              report.comparison.map(\.provider.rawValue), ["claudeCode", "windsurf"])
        let cc = report.comparison.first { $0.provider == .claudeCode }
        equal("本机 Claude Code 2 天", cc?.local.days, 2)
        equal("档案 Claude Code 3 天", cc?.archive.days, 3)
        equal("只在档案里 2 天（09-10 / 09-11）", cc?.archiveOnlyDays, 2)
        equal("只在本机 1 天（09-14）", cc?.localOnlyDays, 1)
        equal("只有会话行的环境也算档案覆盖（Windsurf 唯一的日子来源）",
              report.comparison.first { $0.provider == .windsurf }?.archive.days, 1)
        equal("档案里有请求数缺失的行，要数出来", report.archiveRequestsMissing, 1)
        equal("档案份数", report.archiveDeviceCount, 1)
        // 2（Claude Code 的 09-10 / 09-11）+ 1（Windsurf 那条只有会话的 09-12）= 3
        equal("只在档案里的总天数（跨环境求和）", report.archiveOnlyDaysTotal, 3)
        equal("Claude Code 那一行能单独取到（30 天警示要用它说话）", report.claudeCodeLocal?.first, "2026-09-13")
    }

    // MARK: 7. 菜单栏那行字

    /// 菜单栏是**唯一一处把标签和数值拼成一串**的地方（面板里是两列，表格里是两格），
    /// 所以只有这里会出「贴两次」的毛病 —— 2026-09-25 用户在菜单栏上看到的就是
    /// `今日 $ $16.86`：`shortLabel` 写了个 `$`，而 `Formatters.cost` 自己带一个。
    /// 这一组把拼出来的整串按住，而不是只按住其中一半。
    private static func testMenuBarLabel() {
        group("7. 菜单栏文字")

        var s = MenuBarSummary()
        s.today.cost = 16.86
        s.today.tokens = 337_000_000
        s.today.requests = 3144
        s.today.sessions = 4
        s.month.cost = 5237.33
        s.month.tokens = 7_048_594_528
        s.month.requests = 30107
        s.month.unpriced = true
        s.month.requestsPartial = true

        // 根因那一半：标签里不许自带币种符号，符号只由 `Formatters.cost` 提供
        for m in MenuBarMetric.allCases {
            expect("\(m.rawValue): 标签不自带 $（币种由数值那侧给）", !m.shortLabel.contains("$"), m.shortLabel)
        }

        var cfg = MenuBarConfig()
        equal("默认只显示今日费用", cfg.labelText(s), "今日 $16.86")

        cfg.label = [.todayCost, .todayTokens]
        let two = cfg.labelText(s)
        equal("两项的形态", two, "今日 $16.86 · 今日 tokens 337M")
        equal("金额只出现一个 $（这就是用户抓到的那处）", two.filter { $0 == "$" }.count, 1)

        cfg.label = [.monthCost, .monthRequests]
        equal("下界要跟着走：金额与请求数各自带 ≥", cfg.labelText(s), "本月 ≥$5,237.33 · 本月请求 ≥30,107")

        // 菜单栏长度是所有 app 共享的，第三项会把别人的图标挤走
        cfg.label = [.todayCost, .todayTokens, .todayRequests]
        equal("最多只拼两项", cfg.labelText(s), "今日 $16.86 · 今日 tokens 337M")

        cfg.label = []
        equal("一项都不选 = 只留图标，不留一串空格", cfg.labelText(s), "")

        // 请求数数不出来时是「—」，不是 0 —— 跟表格里那一格同一个口径
        var zero = MenuBarSummary()
        zero.today.requests = 0
        cfg.label = [.todayRequests]
        equal("请求数数不出来写「—」", cfg.labelText(zero), "今日请求 —")

        var partial = MenuBarSummary()
        partial.today.requests = 0
        partial.today.requestsPartial = true
        cfg.label = [.todayRequests]
        equal("只有下界时仍写「—」（0 次和数不出来是两回事）", cfg.labelText(partial), "今日请求 —")
    }

    // MARK: 8. 生命周期与关窗行为

    /// 「关掉主窗口之后 Dock 图标该不该消失」这条线的判据。
    ///
    /// 为什么非要离屏钉住它：活的那条路径读的是 `NSApp.windows`，而**这个环境里启动路径建不出窗口**
    /// （从终端跑二进制或 `open -a` 都只得到 `active=0`），也就是说这条线在本机根本没法稳定复现。
    /// 判据是纯函数，正好把它按住 —— 挑错一个 `canBecomeMain`，症状是「点一下菜单栏图标 Dock 图标就冒出来」，
    /// 肉眼极难归因。
    private static func testWindowLifecycle() {
        group("8. 生命周期与关窗行为")

        typealias Snap = ActivationPolicyController.WindowSnapshot

        // 判据：屏幕上还有没有「真窗口」
        expect("一个窗口都没有 → 没有真窗口", !ActivationPolicyController.hasRealWindow([]))

        let panel = Snap(isVisible: true, isMiniaturized: false, canBecomeMain: false)
        expect("菜单栏面板那种窗口不算数（canBecomeMain=false）",
               !ActivationPolicyController.hasRealWindow([panel]),
               "漏掉这条：点一下菜单栏图标 Dock 图标就会被招回来")

        let main = Snap(isVisible: true, isMiniaturized: false, canBecomeMain: true)
        expect("主窗口算数", ActivationPolicyController.hasRealWindow([main]))

        // 本项目比日历多算的一条 —— 少了它，主窗口缩到 Dock 之后关掉设置窗口会让 Dock 图标消失，
        // 而主窗口还挂在 Dock 里点不开
        let mini = Snap(isVisible: false, isMiniaturized: true, canBecomeMain: true)
        expect("**最小化的主窗口算数**（缩到 Dock 之后 isVisible 会变 false）",
               ActivationPolicyController.hasRealWindow([mini]),
               "漏掉这条：Dock 图标会在窗口还在时消失，且那个窗口点不开")

        let hidden = Snap(isVisible: false, isMiniaturized: false, canBecomeMain: true)
        expect("藏起来的普通窗口不算数", !ActivationPolicyController.hasRealWindow([hidden]))
        expect("藏起来的窗口旁边有真窗口时仍算有", ActivationPolicyController.hasRealWindow([hidden, main]))

        // 关窗决策。四种参数组合都要断，尤其「关的不是主窗口」那一列
        equal("关主窗口 + 不保留 → 退出",
              ActivationPolicyController.closeOutcome(isMainWindow: true, keepRunning: false, hasMenuBarIcon: true), .terminate)
        equal("关主窗口 + 保留 + 有菜单栏图标 → 重新判形态",
              ActivationPolicyController.closeOutcome(isMainWindow: true, keepRunning: true, hasMenuBarIcon: true), .refresh)
        // 死路兜底：菜单栏图标也没了，再退成纯状态栏就三个入口全无
        equal("关主窗口 + 保留 + 没有菜单栏图标 → 留在 Dock",
              ActivationPolicyController.closeOutcome(isMainWindow: true, keepRunning: true, hasMenuBarIcon: false), .stayInDock)

        for keep in [true, false] {
            for icon in [true, false] {
                let outcome = ActivationPolicyController.closeOutcome(isMainWindow: false, keepRunning: keep, hasMenuBarIcon: icon)
                expect("关非主窗口（保留=\(keep), 图标=\(icon)）绝不退出", outcome != .terminate,
                       "得到 \(outcome)：「关个设置窗口把 App 带走」就是这类实现最常见的事故")
            }
        }

        // ⌘Q 的落点：关掉当前窗口，**不退出 App**（用户报上来的毛病：一下 ⌘Q 连状态栏一起没了）
        expect("⌘Q 关主窗口", ActivationPolicyController.closesOnQuitKey(main))
        let settings = Snap(isVisible: true, isMiniaturized: false, canBecomeMain: true)
        expect("⌘Q 关设置窗口（它也是真窗口）", ActivationPolicyController.closesOnQuitKey(settings))
        expect("⌘Q 不关藏起来的窗口", !ActivationPolicyController.closesOnQuitKey(hidden),
               "藏起来的窗口不可能是 key window，判据跟着 `canBecomeMain` 走就好，别再放宽")
        expect("**⌘Q 在菜单栏面板上什么都不做**", !ActivationPolicyController.closesOnQuitKey(panel),
               "漏掉这条：判据一旦放宽成「只要 isVisible」，点开面板按 ⌘Q 就会误关一次窗口")

        testBehaviorSettings()
        testQuitKeyShape()
    }

    /// ⌘Q 的按键形状。
    ///
    /// 用真的 `NSEvent` 构造，不把判据在这里重写一遍 —— 重写等于测了个同义反复。
    /// 形状判错有两头，两头都只在按键那一刻才看得见：
    /// 一头是**漏**（⌘Q 被放行回系统那套 → 状态栏又被一起收掉，本次修的就是这个），
    /// 另一头是**吞**（⌘⇧Q 也被吃掉 → 那个组合在别处的用途失灵）。
    private static func testQuitKeyShape() {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 12)
        }

        expect("⌘Q 被拦下", key("q", [.command]).map(QuitShortcut.isQuitKey) == true)
        // 大写锁定开着时 `charactersIgnoringModifiers` 给的是大写 Q，而 caps lock 也在修饰键集合里。
        // 这两件事都必须被吸收掉，否则「大写锁定一开，⌘Q 就时灵时不灵」。
        expect("大写锁定开着（字符是大写 Q）照样认",
               key("Q", [.command, .capsLock]).map(QuitShortcut.isQuitKey) == true)

        for (name, flags) in [("⌘⇧Q", NSEvent.ModifierFlags([.command, .shift])),
                              ("⌘⌥Q", NSEvent.ModifierFlags([.command, .option])),
                              ("⌘⌃Q", NSEvent.ModifierFlags([.command, .control])),
                              ("光按 Q", NSEvent.ModifierFlags([]))] {
            expect("\(name) 放行（不是「退出」的写法）", key("q", flags).map(QuitShortcut.isQuitKey) == false)
        }
        expect("⌘W 之类的别的键放行", key("w", [.command]).map(QuitShortcut.isQuitKey) == false)
    }

    /// 关窗行为这个设置项的读写。
    ///
    /// 用**注入的一次性 suite**，不是 `.standard` —— 这一组验的就是写入，拿 `.standard` 跑一遍
    /// 等于把用户自己选的关窗行为改掉，而且是静默改。跑完把整个域拆掉。
    ///
    /// 最有价值的是「`removeObject` 之后读回 `true`」那条：它直接钉住实现里那个
    /// `object(forKey:) as? Bool ?? true`。写成 `bool(forKey:)` 的话「从没设过」和「设成 false」
    /// 分不出来，症状是**开关永远打不开**（默认值恰好是 true，一改成 false 就再也回不去）。
    private static func testBehaviorSettings() {
        let suite = "aiusage.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect("能开出一次性 suite", false, suite)
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            // 光 `removePersistentDomain` 不够：它把里面清空成一份**空 plist**，
            // 文件本身留在 `~/Library/Preferences/` 里。每跑一次自测留一个空文件，
            // 用户那个目录会越积越多（一次开发里跑几十遍很正常）。这里把壳也扫掉。
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }

        func fresh() -> AppBehaviorSettings { AppBehaviorSettings(defaults: defaults) }

        expect("全新配置 → 默认保留在菜单栏", fresh().keepRunningAfterMainWindowClose)

        fresh().keepRunningAfterMainWindowClose = false
        expect("写 false 之后读回 false（同一个 suite）", !fresh().keepRunningAfterMainWindowClose)

        defaults.removeObject(forKey: AppBehaviorSettings.keepRunningKey)
        expect("**removeObject 之后读回 true**（这条钉的是 `object(forKey:) as? Bool`）",
               fresh().keepRunningAfterMainWindowClose,
               "写成 bool(forKey:) 的话这里会得到 false —— 开关一旦关掉就再也打不开")

        // 显式写 true 再读，跟「没设过」走的是同一条默认路径，但写盘确实发生了
        fresh().keepRunningAfterMainWindowClose = true
        equal("写 true 之后磁盘上确实是 true",
              defaults.object(forKey: AppBehaviorSettings.keepRunningKey) as? Bool, true)

        // 键盘名一旦改动，老用户的设置会被静默丢弃 —— 键名是有用户数据挂在上面的事实来源
        equal("键名不许随手改（改它等于清空所有用户的这个设置）",
              AppBehaviorSettings.keepRunningKey, "general.keepRunningAfterMainWindowClose.v1")
    }

    // MARK: 更新检查

    /// 更新器的纯逻辑。**不联网、不落盘** —— `UpdateSupport` 与 `UpdateSettings` 能被测起来，
    /// 靠的就是把版本比较和资产挑选从网络那条路上摘干净（见这两个文件开头）。
    ///
    /// 这里**不测**下载与换 bundle：那要真包、真盘、真重启，`SelfTest.swift` 开头的红线不允许
    /// （跑自测时用户可能正开着这个 App，换掉它自己的 bundle 是最糟的一种「测试副作用」）。
    private static func testUpdateLogic() {
        // ── 版本解析 ──
        equal("v 前缀去掉", SemanticVersion.parse("v0.1.0"), SemanticVersion(major: 0, minor: 1, patch: 0))
        equal("带不带 v 是同一个版本", SemanticVersion.parse("v0.1.0"), SemanticVersion.parse("0.1.0"))
        equal("prerelease 逐段切开", SemanticVersion.parse("1.2.3-beta.1")?.prerelease, ["beta", "1"])
        equal("build metadata 不参与", SemanticVersion.parse("1.2.3+build.9"),
              SemanticVersion(major: 1, minor: 2, patch: 3))
        expect("两段版本不猜成 x.y.0", SemanticVersion.parse("1.2") == nil, "猜了就等于替发布者做决定")
        expect("前导零是畸形", SemanticVersion.parse("v1.02.3") == nil)
        expect("非数字是畸形", SemanticVersion.parse("abc") == nil)
        expect("空串是畸形", SemanticVersion.parse("") == nil)
        expect("尾巴空的 prerelease 是畸形", SemanticVersion.parse("1.0.0-") == nil)

        // ── 排序：这一组是更新器最容易错的地方 ──
        expect("**0.1.0 < 0.1.10**（字符串比较会得出反的结论，这就是那个经典 bug）",
               SemanticVersion.parse("0.1.0")! < SemanticVersion.parse("0.1.10")!)
        expect("正式版高于同核心版本的 prerelease",
               SemanticVersion.parse("1.0.0-beta")! < SemanticVersion.parse("1.0.0")!)
        expect("主版本优先于次版本", SemanticVersion.parse("2.0.0")! > SemanticVersion.parse("1.99.99")!)
        expect("段数多的 prerelease 更大",
               SemanticVersion.parse("1.0.0-alpha")! < SemanticVersion.parse("1.0.0-alpha.1")!)
        expect("数字段小于字母段",
               SemanticVersion.parse("1.0.0-1")! < SemanticVersion.parse("1.0.0-alpha")!)
        expect("字母段按字典序",
               SemanticVersion.parse("1.0.0-alpha")! < SemanticVersion.parse("1.0.0-beta")!)

        // ── 要不要提示 ──
        expect("更高 → 提示", SemanticVersion.isNewer(tag: "v0.2.0", than: "0.1.0"))
        expect("**相等 → 不提示**（否则每次启动都重新提示同一个版本）",
               !SemanticVersion.isNewer(tag: "v0.1.0", than: "0.1.0"))
        expect("更低 → 不提示（绝不降级）", !SemanticVersion.isNewer(tag: "v0.0.9", than: "0.1.0"))
        expect("解析不出来 → 不提示", !SemanticVersion.isNewer(tag: "latest", than: "0.1.0"))

        // ── 挑资产 ──
        let v020 = SemanticVersion(major: 0, minor: 2, patch: 0)
        let canonical = UpdatePolicy.canonicalAssetName(v020)
        equal("规范名与 README、export.sh 三处必须一致", canonical, "AiToolsUsage-0.2.0-macos-universal.zip")
        equal("规范名优先",
              UpdatePolicy.selectAsset([relAsset("AiToolsUsage-0.2.0-other.zip"), relAsset(canonical)], version: v020)?.name,
              canonical)
        equal("zip 胜过 dmg",
              UpdatePolicy.selectAsset([relAsset("AiToolsUsage-0.2.0.dmg"), relAsset(canonical)], version: v020)?.name,
              canonical)
        expect("**版本对不上的 zip 要排除**（提示升 0.2.0、装上去还是 0.1.0 就是这么来的）",
               UpdatePolicy.selectAsset([relAsset("AiToolsUsage-0.1.0-macos-universal.zip")], version: v020) == nil)
        equal("只剩一个候选就是它",
              UpdatePolicy.selectAsset([relAsset("whatever-0.2.0.zip")], version: v020)?.name, "whatever-0.2.0.zip")
        expect("两个非规范名 → 有歧义，不猜",
               UpdatePolicy.selectAsset([relAsset("a-0.2.0.zip"), relAsset("b-0.2.0.zip")], version: v020) == nil)
        expect("一个 zip 都没有 → nil", UpdatePolicy.selectAsset([relAsset("x-0.2.0.dmg")], version: v020) == nil)

        // ── host 白名单 ──
        expect("api.github.com 放行", UpdatePolicy.isAllowedHost("api.github.com"))
        expect("github.com 放行", UpdatePolicy.isAllowedHost("github.com"))
        expect("**实测那个 302 目标必须放行**（写成 objects.githubusercontent.com 的话下载必失败）",
               UpdatePolicy.isAllowedHost("release-assets.githubusercontent.com"))
        expect("陌生域名拦下", !UpdatePolicy.isAllowedHost("evil.example.com"))
        expect("nil 拦下", !UpdatePolicy.isAllowedHost(nil))

        // ── 从 release 列表里挑 ──
        let withStable = [ghRelease("v0.1.0"), ghRelease("v0.2.0")]
        equal("同一批里取版本最高的", UpdatePolicy.pickRelease(from: withStable, current: "0.1.0")?.version,
              SemanticVersion(major: 0, minor: 2, patch: 0))
        expect("draft 不算数",
               UpdatePolicy.pickRelease(from: [ghRelease("v0.9.0", draft: true)], current: "0.1.0") == nil)
        equal("**一个正式版都没有时退回落 prerelease**（本仓库现在就是这样）",
              UpdatePolicy.pickRelease(from: [ghRelease("v0.1.0", prerelease: true)], current: "0.0.9")?.version,
              SemanticVersion(major: 0, minor: 1, patch: 0))
        expect("有正式版时就不看 prerelease 了",
               UpdatePolicy.pickRelease(from: [ghRelease("v0.2.0-rc1", prerelease: true), ghRelease("v0.1.0")],
                                        current: "0.1.0") == nil)
        expect("全都比当前旧 → 已是最新",
               UpdatePolicy.pickRelease(from: [ghRelease("v0.1.0")], current: "0.1.0") == nil)
        expect("用户跳过过的版本不再提示",
               UpdatePolicy.pickRelease(from: [ghRelease("v0.2.0")], current: "0.1.0", skipped: "v0.2.0") == nil)
        equal("没有 zip 资产时 asset 为 nil（界面据此退成「打开下载页」）",
              UpdatePolicy.pickRelease(from: [ghRelease("v0.2.0", assets: [ghAsset("x-0.2.0.dmg")])],
                                       current: "0.1.0")?.asset == nil, true)
        equal("正文里的 SHA-256 要捞出来",
              UpdatePolicy.pickRelease(from: [ghRelease("v0.2.0", body: "包：\n\n\(sampleDigest)  AiToolsUsage-0.2.0-macos-universal.zip\n")],
                                       current: "0.1.0")?.checksum,
              sampleDigest)
        expect("正文里没有 SHA-256 就是 nil，不因此失败",
               UpdatePolicy.pickRelease(from: [ghRelease("v0.2.0", body: "没有校验和")], current: "0.1.0")?.checksum == nil)

        // ── 键名与默认值 ──
        // **不能走 /releases/latest**：那个端点排除 prerelease，而本仓库唯一那个 release 就是 prerelease
        // （实测 404）。改成 latest 等于把功能改成永远不提示，而且不报任何错。
        equal("发布列表 URL 不许改成 /releases/latest",
              UpdatePolicy.releasesURL.absoluteString,
              "https://api.github.com/repos/zhengshangjinx/ai-tools-usage/releases?per_page=20")
        testUpdateSettingsKeys()
    }

    /// `UpdateSettings` 的读写。用**注入的一次性 suite**，理由与 `testBehaviorSettings` 完全一样：
    /// 这一组验的就是写入，拿 `.standard` 跑一遍等于把用户自己的开关改掉。
    private static func testUpdateSettingsKeys() {
        equal("自动检查键名不许随手改", UpdateSettings.autoCheckKey, "update.autoCheck.v1")
        equal("跳过版本键名不许随手改", UpdateSettings.skippedVersionKey, "update.skippedVersion.v1")
        equal("上次检查键名不许随手改", UpdateSettings.lastCheckKey, "update.lastCheck.v1")

        let suite = "aiusage.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect("能开出一次性 suite", false, suite)
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            // `removePersistentDomain` 只把内容清空成一份空 plist，文件壳还留在
            // `~/Library/Preferences/` 里 —— 每跑一次自测留一个，见 testBehaviorSettings 那段账
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suite).plist")
            try? FileManager.default.removeItem(at: plist)
        }

        func fresh() -> UpdateSettings { UpdateSettings(defaults: defaults) }

        expect("全新配置 → 默认自动检查", fresh().autoCheckEnabled)
        fresh().autoCheckEnabled = false
        expect("写 false 之后读回 false", !fresh().autoCheckEnabled)
        defaults.removeObject(forKey: UpdateSettings.autoCheckKey)
        expect("**removeObject 之后读回 true**（这条钉的是 `object(forKey:) as? Bool`）",
               fresh().autoCheckEnabled,
               "写成 bool(forKey:) 的话这里会得到 false —— 开关一旦关掉就再也打不开")

        expect("没跳过过任何版本时是 nil", fresh().skippedVersion == nil)
        fresh().skippedVersion = "v0.2.0"
        equal("跳过的版本写得进读得出", fresh().skippedVersion, "v0.2.0")

        expect("没检查过时 lastCheck 为 nil", fresh().lastCheck == nil)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        fresh().lastCheck = now
        equal("lastCheck 往返不掉精度", fresh().lastCheck, now)
    }

    // MARK: 工装

    private static func ghRelease(_ tag: String, prerelease: Bool = false, draft: Bool = false,
                                  assets: [GHAsset] = [], body: String? = nil) -> GHRelease {
        GHRelease(tagName: tag, body: body, draft: draft, prerelease: prerelease,
                  htmlURL: URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/releases/tag/\(tag)")!,
                  assets: assets)
    }

    private static func ghAsset(_ name: String, size: Int = 2_514_069) -> GHAsset {
        GHAsset(name: name,
                browserDownloadURL: URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/releases/download/v1/\(name)")!,
                size: size)
    }

    /// `selectAsset` 收的是已经映射好的 `ReleaseAsset`，所以挑资产那几条单用这个。
    private static func relAsset(_ name: String, size: Int = 2_514_069) -> ReleaseAsset {
        ReleaseAsset(name: name,
                     url: URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/releases/download/v1/\(name)")!,
                     size: size)
    }

    /// 64 位 hex，取值照线上 v0.1.0 那份 release 正文（真实存在，不是编的）。
    private static let sampleDigest = "713a34396f6725f22ad85db7beafc9175101b7820f109f4ec4f91a163818b3ab"

    private static func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-selftest-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ lines: [String], to url: URL) {
        let text = lines.map { $0.replacingOccurrences(of: "\n", with: "") }.joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: url)
    }
}
