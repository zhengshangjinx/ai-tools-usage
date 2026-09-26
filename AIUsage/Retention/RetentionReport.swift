import Foundation

/// 某个环境在**一侧**（本机原始日志 / iCloud 档案）覆盖到的日子。
///
/// 存的是**天的集合**而不是「天数 + 首尾」：面板真正要回答的是
/// 「哪几天本机日志已经没有、只剩档案里还有」，那是两个集合的差，光有计数算不出来。
/// （本机 codex 38 天、档案 85 天，而两边都从 2026-04-18 起 —— 只比首尾的话这个差会被完全漏掉。）
///
/// 天数与首尾都用 `DayKey` 那套 `yyyy-MM-dd` 字符串：ASCII、定长，字典序即时间序。
struct CoverageSpan: Identifiable, Equatable {
    var provider: ProviderKind
    private(set) var dayKeys: Set<String> = []
    /// 首尾在构造时算好存下来 —— `Set.min()` 是 O(n)，而这个值在一帧里会被读好几次
    private(set) var first: String?
    private(set) var last: String?

    init(provider: ProviderKind, dayKeys: Set<String> = []) {
        self.provider = provider
        self.dayKeys = dayKeys
        self.first = dayKeys.min()
        self.last = dayKeys.max()
    }

    var id: String { provider.rawValue }
    var label: String { provider.displayName }
    var days: Int { dayKeys.count }
    var hasData: Bool { !dayKeys.isEmpty }

    /// 「2026-09-13 .. 2026-09-25」；一天都没有就写「无」
    var rangeText: String {
        guard let first, let last else { return "无" }
        return first == last ? first : "\(first) .. \(last)"
    }

    var daysText: String { hasData ? "\(days) 天" : "—" }
}

/// 本机与档案并排的一行。
struct RetentionComparison: Identifiable, Equatable {
    var provider: ProviderKind
    var local: CoverageSpan
    var archive: CoverageSpan

    var id: String { provider.rawValue }

    /// 档案里有、本机日志里已经没有的天数。**这是这一页最该被看见的数。**
    /// 两种来源都算进来，面板上的措辞因此要说全：本地日志被清理过，或者那几天本来就来自另一台设备。
    var archiveOnlyDays: Int { archive.dayKeys.subtracting(local.dayKeys).count }

    /// 反过来：本机日志有、档案里还没有 —— 通常是这台机器还没同步上去，不是数据丢了
    var localOnlyDays: Int { local.dayKeys.subtracting(archive.dayKeys).count }
}

/// 「显示与留存」面板要的全部事实。**纯计算**：不写任何文件、不改任何设置、不联网。
///
/// 两侧口径刻意统一成「有数据的日子」（本机取扫描结果的记录日期，档案取聚合行的 day），
/// 而不是去 stat 一堆文件的修改时间。原因：
/// - Devin / Cursor 是单个 SQLite 文件，文件时间只有一个值，按它算覆盖毫无意义；
/// - 记录是 App 已经在内存里的（`store.records`），零成本、不会让设置窗口卡住；
/// - 两边同口径，对照表才是可比的 —— 一边数文件、一边数天，读出来的差值是假的。
struct RetentionReport {
    /// Claude Code 的「日志保留天数」设置；nil = 用户没设过（那就走它的默认值 30 天）
    var cleanupPeriodDays: Int?
    /// 那个文件在不在。不在 ≠ 没设置 —— 可能是从没跑过 Claude Code，得说得准
    var settingsFileExists: Bool
    var local: [CoverageSpan]
    var archive: [CoverageSpan]
    var archiveDeviceCount: Int
    /// 档案里「token 有、请求数没记」的行数（老版本 App 写的档案）——
    /// 它决定主界面那些 ≥ 是怎么来的，值得在留存面板里露一次
    var archiveRequestsMissing: Int

    static let suggestedCleanupDays = 370
    static let defaultCleanupDays = 30

    /// 当前**实际生效**的保留天数
    var effectiveCleanupDays: Int { cleanupPeriodDays ?? Self.defaultCleanupDays }
    var isCleanupConfigured: Bool { cleanupPeriodDays != nil }

    /// 两边并起来，只出有数据的环境；顺序照 `ProviderKind.allCases`
    var comparison: [RetentionComparison] {
        let localMap = Dictionary(uniqueKeysWithValues: local.map { ($0.provider, $0) })
        let archiveMap = Dictionary(uniqueKeysWithValues: archive.map { ($0.provider, $0) })
        return ProviderKind.allCases.compactMap { p in
            let l = localMap[p] ?? CoverageSpan(provider: p)
            let a = archiveMap[p] ?? CoverageSpan(provider: p)
            guard l.hasData || a.hasData else { return nil }
            return RetentionComparison(provider: p, local: l, archive: a)
        }
    }

    /// 档案里有、本机日志里已经没有了的天数合计 —— 面板顶部那句「档案已经越过砍刀」的判据
    var archiveOnlyDaysTotal: Int { comparison.reduce(0) { $0 + $1.archiveOnlyDays } }

    /// **Claude Code** 本机日志那一行。
    ///
    /// `cleanupPeriodDays` 管的是 Claude Code 一个环境，所以那条警示必须用它自己的覆盖说话：
    /// 要是图省事取「全部环境里最早的一天」，Codex 那种不归这把砍刀管的日志（本机回到 2026-04-18）
    /// 会顶上来，页面就会一边说「默认只留 30 天」、一边显示「最早到 04-18」—— 自相矛盾。
    var claudeCodeLocal: CoverageSpan? { local.first { $0.provider == .claudeCode } }
}

extension RetentionReport {
    static var claudeSettingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    /// 读 `~/.claude/settings.json` 里的 `cleanupPeriodDays`。
    ///
    /// **安全红线（改这段之前先读完）：这个文件里有用户的 live 凭据**
    /// （`ANTHROPIC_AUTH_TOKEN`）。所以：
    /// - 只取 `cleanupPeriodDays` 这**一个**键。整份字典绝不 `print` / `NSLog` / 编码进任何结构，
    ///   也绝不塞进 `RetentionReport`（它是 `Equatable`，会被到处传）；
    /// - **绝不写回这个文件**。设置页只给一段可复制的 JSON 片段，让用户自己去改 ——
    ///   我们替他写一遍，就得把没读过的键原样搬回去，那是拿别人的凭据冒险；
    /// - 出错一律当作「没设置」，不做任何补救动作（不备份、不重建）。
    /// `path` 可传：自测要用 fixture 跑，**绝不能让它去读用户真实的那份**
    /// （读它本身无害，但自测的红线是「不碰用户的真实文件」，留着这个口子比事后解释便宜）。
    static func readCleanupPeriodDays(path: String = claudeSettingsPath) -> (value: Int?, fileExists: Bool) {
        guard let data = FileManager.default.contents(atPath: path) else { return (nil, false) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, true)
        }
        // 只碰这一个键
        guard let raw = obj["cleanupPeriodDays"] else { return (nil, true) }
        if let n = raw as? Int { return (n, true) }
        if let d = raw as? Double { return (Int(d), true) }
        if let s = raw as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { return (n, true) }
        return (nil, true)
    }

    /// 本机原始日志覆盖：直接用刚扫出来的记录，不另扫一遍磁盘
    static func localCoverage(from records: [UsageRecord]) -> [CoverageSpan] {
        var byProvider: [ProviderKind: Set<String>] = [:]
        for r in records { byProvider[r.provider, default: []].insert(DayKey.key(r.timestamp)) }
        return spans(byProvider)
    }

    /// 档案覆盖：token 行与「每日会话数」行都算 —— 后者是 Windsurf / Antigravity 这类
    /// 拿不到 token 的环境唯一的日期来源，漏掉它们，那几个环境在对照表里会显示成「无」。
    static func archiveCoverage(from files: [DeviceFile]) -> (spans: [CoverageSpan], devices: Int, requestsMissing: Int) {
        var byProvider: [ProviderKind: Set<String>] = [:]
        var missing = 0
        for f in files {
            for r in f.rows {
                byProvider[r.provider, default: []].insert(r.day)
                if r.requestsUnknown { missing += 1 }
            }
            for s in f.sessions { byProvider[s.provider, default: []].insert(s.day) }
        }
        return (spans(byProvider), files.count, missing)
    }

    /// 拼一份完整的现状 = 读那个设置文件 + 纯计算。**在后台线程调**（要读文件、要解 JSON）。
    static func make(records: [UsageRecord], deviceFiles: [DeviceFile]) -> RetentionReport {
        let cleanup = readCleanupPeriodDays()
        return make(records: records, deviceFiles: deviceFiles,
                    cleanupPeriodDays: cleanup.value, settingsFileExists: cleanup.fileExists)
    }

    /// 纯计算的那一半：不碰文件系统，自测直接调这个（跟 `UsageStore.aggregate` 一个路数）
    static func make(records: [UsageRecord], deviceFiles: [DeviceFile],
                     cleanupPeriodDays: Int?, settingsFileExists: Bool) -> RetentionReport {
        let archive = archiveCoverage(from: deviceFiles)
        return RetentionReport(cleanupPeriodDays: cleanupPeriodDays,
                               settingsFileExists: settingsFileExists,
                               local: localCoverage(from: records),
                               archive: archive.spans,
                               archiveDeviceCount: archive.devices,
                               archiveRequestsMissing: archive.requestsMissing)
    }

    private static func spans(_ map: [ProviderKind: Set<String>]) -> [CoverageSpan] {
        ProviderKind.allCases.compactMap { p in
            guard let set = map[p], !set.isEmpty else { return nil }
            return CoverageSpan(provider: p, dayKeys: set)
        }
    }

    /// 给用户抄进 `~/.claude/settings.json` 的片段。**只给文本，不替他写**。
    static func cleanupSnippet(days: Int = suggestedCleanupDays) -> String {
        "{\n  \"cleanupPeriodDays\": \(days)\n}"
    }
}

// MARK: - 工装出口

extension RetentionReport {
    /// `--retention` 用。跟 `debugMenuDump()` 同一个道理：界面上的数得有个机器可读的出口，
    /// 否则「对照表里那行对不对」只能靠肉眼看截图。**只打印 cleanupPeriodDays 这一个值，
    /// 绝不打印那个文件的其它内容**（见上面那段安全红线）。
    func debugDump() -> String {
        var out: [String] = []
        out.append("claudeSettings exists=\(settingsFileExists) cleanupPeriodDays=\(cleanupPeriodDays.map(String.init) ?? "未设置") effective=\(effectiveCleanupDays) suggested=\(Self.suggestedCleanupDays)")
        out.append("archive devices=\(archiveDeviceCount) requestsMissing=\(archiveRequestsMissing) archiveOnlyDays=\(archiveOnlyDaysTotal)")
        out.append("provider     本机日志                      档案                        只在本机  只在档案")
        for c in comparison {
            out.append(String(format: "%-12@ %-3@天 %-24@ %-3@天 %-24@ %-8@ %@",
                              c.provider.rawValue as NSString,
                              "\(c.local.days)" as NSString,
                              ((c.local.first ?? "—") + ".." + (c.local.last ?? "—")) as NSString,
                              "\(c.archive.days)" as NSString,
                              ((c.archive.first ?? "—") + ".." + (c.archive.last ?? "—")) as NSString,
                              "\(c.localOnlyDays)" as NSString,
                              "\(c.archiveOnlyDays)" as NSString))
        }
        return out.joined(separator: "\n")
    }
}
