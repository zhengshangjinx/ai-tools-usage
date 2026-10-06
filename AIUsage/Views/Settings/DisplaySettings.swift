import SwiftUI
import AppKit

/// 「显示与留存」页。
///
/// 两件事：菜单栏怎么显示自己，以及**本地日志正在被删这件事**。
/// 后者是 App 里唯一一处「数据在流失」的说明 —— 不说，用户不会知道 Claude Code
/// 默认只留 30 天，更不知道该去改哪个值；而档案早就越过了那把砍刀，界面却一个字不提。
///
/// **这一页绝不写 `~/.claude/settings.json`**（那文件里有用户的 live 凭据，
/// 见 `RetentionReport.readCleanupPeriodDays()` 上面那段红线），只给一段可复制的片段；
/// 也绝不自动往 iCloud 同步目录写任何东西。
struct DisplaySettings: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var menuBar: MenuBarSettings
    /// 关窗行为。它归在「菜单栏」这一节里，因为两者是耦合的：菜单栏图标是关掉主窗口之后
    /// **唯一的入口**，所以图标关掉时那条「退成纯状态栏」的路必须让开（见下面那行橙色提示）。
    @EnvironmentObject var behavior: AppBehaviorSettings

    /// 工装注入用。离屏快照工装**不跑 `.task`**，不注入的话这一页只能拍到
    /// 「正在统计…」那个占位，排版就没法核对了。
    var injectedReport: RetentionReport?

    @State private var loaded: RetentionReport?
    @State private var copied = false

    private var report: RetentionReport? { injectedReport ?? loaded }

    var body: some View {
        SettingsDetailPage(SettingsPane.display.title, subtitle: SettingsPane.display.subtitle) {
            SettingsScroll {
                retentionCard
                coverageCard
                menuBarCard
            }
        }
        // 跟着 `lastScan` 重算：用户可能在别的页签点了「立即重扫」，或者主窗口刚扫完
        .task(id: store.lastScan) { await reload() }
    }

    // MARK: 留存

    private var retentionCard: some View {
        SettingsCard("Claude Code 本地日志保留",
                     footer: "370 天约等于一年。注意这句诚实的话：**档案只覆盖本 App 已经开始统计之后的日子** —— 在那之前被 Claude Code 删掉的日志找不回来，调大这个值只是让以后不再丢。") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 12))
                    if let detail = statusDetail {
                        SettingsNote(detail)
                    }
                }
                Spacer(minLength: 0)
            }
            // 状态不只靠颜色：图标 + 文字 + 颜色三条都在（照「对比度警告不能只靠颜色」那条来）
            HStack(spacing: 8) {
                Text("建议").font(.system(size: 12)).foregroundStyle(Theme.gray700)
                Text("\(RetentionReport.suggestedCleanupDays) 天")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.gray900)
                Button(copied ? "已复制" : "复制片段") { copySnippet() }.settingsButton()
                Spacer(minLength: 8)
                Button("重新检测") { Task { await reload() } }.settingsButton()
            }
            // 同一段 JSON 要能被复制出去，所以是可选文本；壳子用输入框那一套
            // （浅底 + 细边）—— 它跟「手动单价」页里那几个输入框是同一类东西：一段可以拿走的内容。
            Text(RetentionReport.cleanupSnippet())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.gray800)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.fieldBorder))
            SettingsNote("路径 \(RetentionReport.claudeSettingsPath)（只读，本 App 不会替你改这个文件）")
        }
    }

    private var statusIcon: String {
        guard let r = report else { return "clock" }
        if !r.settingsFileExists || !r.isCleanupConfigured || r.effectiveCleanupDays < 90 {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        guard let r = report else { return Theme.gray500 }
        if !r.settingsFileExists { return Theme.statusWarning }
        if !r.isCleanupConfigured || r.effectiveCleanupDays < 90 { return Theme.statusWarning }
        return Theme.statusGood
    }

    private var statusTitle: String {
        guard let r = report else { return "正在检测…" }
        if !r.settingsFileExists { return "没有找到 ~/.claude/settings.json" }
        if let v = r.cleanupPeriodDays { return "cleanupPeriodDays = \(v) 天" }
        return "cleanupPeriodDays 未设置，走 Claude Code 默认的 \(RetentionReport.defaultCleanupDays) 天"
    }

    /// 具体到「本机 Claude Code 的日志只到哪一天」—— 一个孤零零的 30 没什么说服力，
    /// 配上实际覆盖才有。**只看 Claude Code**：Codex 那些日志不归这个设置管，
    /// 混进来会变成「说保留 30 天、却显示最早到 4 月」。
    private var statusDetail: String? {
        guard let r = report else { return nil }
        if let cc = r.claudeCodeLocal {
            var s = "本机 Claude Code 日志最早只到 \(cc.first ?? "—")，有数据的一共 \(cc.days) 天"
            if r.isCleanupConfigured && r.effectiveCleanupDays < 90 {
                s += "，已经短于设置里的 \(r.effectiveCleanupDays) 天"
            }
            return s + "。"
        }
        if !r.settingsFileExists { return "这台机器上可能还没用过 Claude Code，或者配置文件在别处。" }
        return "本机还没有扫到 Claude Code 的记录。"
    }

    // MARK: 覆盖对照

    private var coverageCard: some View {
        SettingsCard("覆盖对照",
                     footer: "「天」指**有数据的天数**，不是首尾相隔的天数 —— 中间没用量的日子不计，所以 38 天可能横跨五个月。本机日志 = 上次扫描实际读到的日期；档案 = 共享目录里各设备的聚合行与每日会话数。绿色数字是**档案里有、本机日志里已经没有**的天数：可能来自本地日志被清理，也可能那几天本来就是另一台设备的记录。") {
            if let r = report {
                if let total = Optional(r.archiveOnlyDaysTotal), total > 0 {
                    HStack {
                        Spacer(minLength: 0)
                        Text("只在档案里：\(total) 天")
                            .font(.system(size: 11)).foregroundStyle(Theme.statusGood).monospacedDigit()
                    }
                }
                if r.comparison.isEmpty {
                    SettingsNote("两边都还没有数据。先在主窗口扫一次，或者等待首次同步。")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("环境").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                            Text("本机日志").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                            Text("档案").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                            Text("档案独有").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                        }
                        ForEach(r.comparison) { c in comparisonRow(c) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    SettingsNote("正在统计…")
                }
            }
        }
    }

    private func comparisonRow(_ c: RetentionComparison) -> some View {
        GridRow {
            HStack(spacing: 5) {
                Image(systemName: c.provider.symbol)
                    .font(.system(size: 10)).foregroundStyle(Theme.gray500).frame(width: 14)
                Text(c.provider.displayName).font(.system(size: 12))
            }
            spanCell(c.local)
            spanCell(c.archive)
            VStack(alignment: .leading, spacing: 1) {
                if c.archiveOnlyDays > 0 {
                    Text("+\(c.archiveOnlyDays) 天").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.statusGood).monospacedDigit()
                        .help("这几天本机日志里已经没有了，只剩档案里还有")
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                }
                if c.localOnlyDays > 0 {
                    Text("本机多 \(c.localOnlyDays) 天").font(.system(size: 10))
                        .foregroundStyle(Theme.gray500).monospacedDigit()
                        .help("这几天还没同步到档案里")
                }
            }
        }
    }

    /// 一格里两行：上面是**有数据的天数**，下面是首尾日期。第二行只是给个时间感，
    /// 别让它喧宾夺主 —— 但也要有，否则「38 天」看不出是哪一段。
    private func spanCell(_ s: CoverageSpan) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.daysText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(s.hasData ? Theme.gray800 : Theme.gray500)
                .monospacedDigit()
            Text(shortRange(s)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.gray500)
        }
    }

    /// 「09-13 .. 09-25」：去掉年份 —— 这一页看的都是「从现在往前」，月日足够分辨，
    /// 而带上年份每列要多占 5 个字符，三列就排不下了。
    private func shortRange(_ s: CoverageSpan) -> String {
        guard let f = s.first, let l = s.last else { return "—" }
        func md(_ k: String) -> String { k.count > 5 ? String(k.dropFirst(5)) : k }
        return f == l ? md(f) : "\(md(f)) .. \(md(l))"
    }

    // MARK: 菜单栏

    private var menuBarCard: some View {
        SettingsCard("菜单栏",
                     footer: "关掉「在菜单栏显示」只是不显示图标。Dock 图标是另一套逻辑：**屏幕上没有真窗口时 App 会退成纯状态栏**（Dock 图标与菜单栏一起收掉），再打开窗口时临时出现。仍然**没有**开 LSUIElement —— 本 App 启动就有窗口，静态声明只会让启动多一次翻转，理由见 ActivationPolicyController。\n\n菜单栏与面板里的数都是固定窗口（今日 / 本月 / 近 7 天），**不跟随主窗口选的日期范围** —— 点一下菜单栏就把主窗口的日期范围改掉，那是劫持。") {
            SettingsRow("显示") {
                Toggle("在菜单栏显示", isOn: $menuBar.config.showInMenuBar)
                    .toggleStyle(.switch).controlSize(.small)
            }
            SettingsRow("关窗行为") {
                Toggle("关闭主窗口后保留在菜单栏", isOn: $behavior.keepRunningAfterMainWindowClose)
                    .toggleStyle(.switch).controlSize(.small)
            }
            // 两个开关本身是对的，凑在一起却会撞出一条死路：图标关掉、关窗又不退出，
            // App 就变成「没有 Dock 图标、没有菜单栏、没有窗口」，只能去活动监视器杀。
            // 这里如实说出来（行为取「不让 App 变成点不到的状态」那一侧，见 ActivationPolicyController.closeOutcome），
            // 而不是默默替他决定。
            if !menuBar.config.showInMenuBar && behavior.keepRunningAfterMainWindowClose {
                Label("菜单栏图标已关掉：这时关掉主窗口不会退出，Dock 图标会保留 —— 否则这个 App 就没有任何入口了。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsRule()
            MetricPicker(title: "菜单栏文字",
                         note: "最多 \(MenuBarConfig.maxLabelItems) 项 —— 菜单栏是所有 App 共享的一条，排太多会把别人的图标挤走。一项都不选就只留图标。",
                         limit: MenuBarConfig.maxLabelItems,
                         selection: $menuBar.config.label)
            SettingsRule()
            MetricPicker(title: "面板指标",
                         note: "点开菜单栏图标后显示哪几项，顺序就是显示顺序；「本月」那一组前面会自动加一条分隔线。",
                         limit: nil,
                         selection: $menuBar.config.panel)
        }
    }

    // MARK: 动作

    private func reload() async {
        let records = store.records
        // 走 `archiveDeviceFiles`：演示模式下它给的是内存里那几份，
        // 直接读 deviceSync 会去翻作者真实的 iCloud 目录（见 DemoRuntime）
        let files = store.archiveDeviceFiles
        loaded = await Task.detached(priority: .userInitiated) {
            RetentionReport.make(records: records, deviceFiles: files)
        }.value
    }

    private func copySnippet() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(RetentionReport.cleanupSnippet(), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

/// 六个指标的多选。用 `FilterChip` 而不是 `Toggle`：六个开关竖着排要占掉半页，
/// 横着排成一串 chip 跟主界面筛选区的那排是同一个东西，用户已经认得。
///
/// 排布走 `FlowLayout` 而**不是 `HStack`**：六个 chip 定宽不可压，横着排最小宽度约 690pt，
/// 比内容列还宽 —— 原来那一版正是把设置窗口挤变形的元凶（切页签时侧栏会窄 3pt，
/// 见 `SettingsView.body` 里那段账）。折行之后这一行最多两行，宽度再也不会超出卡片。
/// 主界面的环境/设备 chips 早就是这个布局，两处现在一致了。
private struct MetricPicker: View {
    let title: String
    let note: String
    var limit: Int?
    @Binding var selection: [MenuBarMetric]
    @State private var limitHit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12))
                if limitHit {
                    Text("最多 \(limit ?? 0) 项").font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                }
            }
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(MenuBarMetric.allCases) { m in
                    FilterChip(title: m.label, color: Theme.primary, selected: selection.contains(m)) { toggle(m) }
                }
            }
            SettingsNote(note)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ m: MenuBarMetric) {
        if selection.contains(m) {
            selection.removeAll { $0 == m }
            limitHit = false
            return
        }
        if let limit, selection.count >= limit {
            limitHit = true
            return
        }
        selection.append(m)
        limitHit = false
    }
}
