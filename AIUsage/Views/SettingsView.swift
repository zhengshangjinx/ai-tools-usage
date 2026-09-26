import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            SourcesSettings().tabItem { Label("数据源", systemImage: "folder") }
            DeviceSyncSettings().tabItem { Label("设备与同步", systemImage: "laptopcomputer.and.iphone") }
            PricingSettings().tabItem { Label("模型单价", systemImage: "dollarsign.circle") }
            DisplaySettings().tabItem { Label("显示与留存", systemImage: "menubar.rectangle") }
        }
        // 高度 580 → 620：新加的「显示与留存」里那张对照表行数随环境数走（本机 6 行）。
        // 这个高度是**所有页签共用**的，不是这一页要这么高 —— 但另外三页本来就要滚动
        // （「数据源」九组路径框），抬高只是让底部少切一点，不会有谁被撑坏。
        .frame(width: 680, height: 620)
    }
}

// MARK: - 数据源

struct SourcesSettings: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        Form {
            ForEach(SourceKind.allCases) { kind in
                Section {
                    Toggle(isOn: binding(kind).enabled) {
                        HStack(spacing: 8) {
                            Text(kind.displayName).fontWeight(.medium)
                            capabilityTag(kind)
                            if !kind.isDetected {
                                Text("未检测到").font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: pathsBinding(kind))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 52)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cardBorder))
                        HStack {
                            Text(kind.pathHint + "，每行一个").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复默认") { store.resetPaths(for: kind) }.controlSize(.small)
                        }
                    }
                }
            }
            Section {
                HStack {
                    if let last = store.lastScan {
                        Text("上次扫描 \(last.formatted(date: .abbreviated, time: .shortened)) · \(store.records.count) 条记录 · 耗时 \(String(format: "%.1fs", store.scanDuration))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清除缓存并重扫") {
                        ScanCache.shared.clear()
                        Task { await store.refresh() }
                    }.disabled(store.isScanning)
                    Button("立即重扫") { Task { await store.refresh() } }.disabled(store.isScanning)
                }
            } footer: {
                Text("解析结果按文件缓存在 ~/Library/Application Support/AIUsage，仅重新解析变化过的文件。")
            }
        }
        .formStyle(.grouped)
    }

    private func capabilityTag(_ kind: SourceKind) -> some View {
        let color: Color
        switch kind.capability {
        case .tokens: color = Theme.statusGood
        case .sessionsOnly: color = Theme.statusWarning
        case .unavailable: color = Theme.statusCritical
        }
        return Text(kind.capability.label)
            .font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func binding(_ kind: SourceKind) -> Binding<SourceConfig> {
        Binding(
            get: { store.sourceConfigs[kind] ?? SourceConfig(paths: kind.defaultPaths) },
            set: { store.sourceConfigs[kind] = $0 }
        )
    }

    private func pathsBinding(_ kind: SourceKind) -> Binding<String> {
        Binding(
            get: { (store.sourceConfigs[kind]?.paths ?? []).joined(separator: "\n") },
            set: { text in
                store.sourceConfigs[kind]?.paths = text.split(whereSeparator: \.isNewline)
                    .map { ($0 as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

// MARK: - 设备与同步

struct DeviceSyncSettings: View {
    @EnvironmentObject var store: UsageStore
    @State private var draftName: String = DeviceIdentity.name
    @State private var nameDirty = false

    var body: some View {
        Form {
            Section {
                Toggle("跨设备同步", isOn: $store.syncEnabled)
                HStack(spacing: 8) {
                    Text("设备名称").font(.system(size: 12))
                    TextField("", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onChange(of: draftName) { _, new in nameDirty = new != DeviceIdentity.name }
                    if nameDirty {
                        Button("应用") {
                            DeviceIdentity.name = draftName
                            nameDirty = false
                            store.resync()
                        }.controlSize(.small)
                        Button("取消") { draftName = DeviceIdentity.name; nameDirty = false }
                            .controlSize(.small)
                    }
                    Spacer()
                }
            } header: {
                Text("本机身份")
            } footer: {
                Text("设备 ID 是首次启动生成的稳定 UUID，改名不会造成重复设备；档案文件名用的是 ID。")
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: DeviceSync.defaultFolderAvailable ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(DeviceSync.defaultFolderAvailable ? Theme.statusGood : Theme.statusWarning)
                    Text(store.deviceSync.folderURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                }
                HStack {
                    Button("更改…") { chooseFolder() }.controlSize(.small)
                    Button("恢复默认") {
                        store.deviceSync.folderURL = DeviceSync.defaultFolder
                        store.resync()
                    }.controlSize(.small)
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.deviceSync.folderURL])
                    }.controlSize(.small)
                    Spacer()
                    Button("立即同步") { store.resync() }.controlSize(.small).disabled(store.isScanning)
                }
                if !DeviceSync.defaultFolderAvailable {
                    Text("未检测到 iCloud Drive。请先在系统设置里登录 iCloud 并启用 iCloud 云盘，或把上面的目录改成其他同步盘。")
                        .font(.caption).foregroundStyle(Theme.statusWarning)
                }
            } header: {
                Text("共享目录")
            } footer: {
                Text("每台设备只写自己的 device-<ID>.json，互不覆盖，因此不需要加锁也不会产生写冲突。换目录即可换用 Dropbox 等其他同步盘。")
            }

            Section {
                ForEach(store.devices) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.isLocal ? "laptopcomputer" : "desktopcomputer")
                            .foregroundStyle(d.isLocal ? Theme.primary : Theme.gray500)
                        Text(d.name).fontWeight(d.isLocal ? .medium : .regular)
                        if d.isLocal {
                            Text("本机").font(.caption2).foregroundStyle(Theme.primary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.primarySoft, in: Capsule())
                        }
                        Spacer()
                        Text("\(d.rowCount) 行聚合").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(relative(d.updatedAt)).font(.caption).foregroundStyle(.secondary)
                        if !d.isLocal {
                            Button(role: .destructive) {
                                store.deviceSync.remove(deviceId: d.id)
                                store.resync()
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("从共享目录删除这台设备的档案；该设备下次同步会重新写入")
                        }
                    }
                }
                if !store.syncWarnings.isEmpty {
                    ForEach(store.syncWarnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(Theme.statusWarning)
                            Text(w).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("已发现的设备（\(store.devices.count)）")
            } footer: {
                Text("同步的是「日 × 环境 × 模型」的 token 聚合行与每日会话数，不含会话内容；费用在展示端用本机价格表重算，所以历史会随价格表更新自动重估。")
            }
        }
        .formStyle(.grouped)
        .onAppear { draftName = DeviceIdentity.name }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = store.deviceSync.folderURL.deletingLastPathComponent()
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            store.deviceSync.folderURL = url
            store.resync()
        }
    }

    private func relative(_ d: Date?) -> String {
        guard let d else { return "从未同步" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - 模型单价

struct PricingSettings: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService

    @State private var newModel = ""
    @State private var newInput = ""
    @State private var newCacheRead = ""
    @State private var newCacheWrite = ""
    @State private var newOutput = ""

    var body: some View {
        Form {
            Section("LiteLLM 价格表") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("已加载 \(pricing.remote.count) 个模型")
                        Text(pricing.lastUpdated.map { "更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未拉取")
                            .font(.caption).foregroundStyle(.secondary)
                        if let err = pricing.lastError {
                            Text(err).font(.caption).foregroundStyle(Theme.statusCritical)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await pricing.refresh() }
                    } label: {
                        if pricing.isRefreshing { ProgressView().controlSize(.small) } else { Text("刷新") }
                    }
                    .disabled(pricing.isRefreshing)
                }
            }

            Section {
                if pricing.overrides.isEmpty {
                    Text("暂无手动单价。").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(pricing.overrides.keys.sorted(), id: \.self) { model in
                    if let p = pricing.overrides[model] {
                        HStack {
                            Text(model).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                            priceTag("输入", p.input); priceTag("缓存读", p.cacheRead); priceTag("缓存写", p.cacheWrite); priceTag("输出", p.output)
                            Button(role: .destructive) { pricing.overrides.removeValue(forKey: model) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                addRow
            } header: {
                Text("手动单价（美元 / 百万 tokens）")
            } footer: {
                Text("手动单价优先于 LiteLLM；缓存字段留空则按输入单价计费。")
            }

            if !store.snapshot.unpricedModels.isEmpty {
                Section("当前范围内未计价的模型") {
                    ForEach(store.snapshot.unpricedModels, id: \.self) { m in
                        HStack {
                            Text(m).font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button("设置单价") { newModel = m }.controlSize(.small)
                        }
                    }
                }
            }

            Section {
                PricingBrowser { model, price in
                    newModel = model
                    newInput = ModelPrice.perMillionText(price.input)
                    newOutput = ModelPrice.perMillionText(price.output)
                    newCacheRead = price.cacheRead.map(ModelPrice.perMillionText) ?? ""
                    newCacheWrite = price.cacheWrite.map(ModelPrice.perMillionText) ?? ""
                }
            } header: {
                Text("全部单价")
            } footer: {
                Text("拉下来的价格表有三千多条，翻是翻不完的 —— 用搜索定位。行尾「覆盖」会把这条价格填进上面的手动单价表单，改完点「添加」生效。")
            }
        }
        .formStyle(.grouped)
    }

    private func priceTag(_ label: String, _ v: Double?) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(PricingService.formatPerMillion(v)).font(.system(size: 11, design: .rounded)).monospacedDigit()
        }
        .frame(width: 58)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("模型标识（精确匹配，如 gpt-5.6-sol）", text: $newModel)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            HStack(spacing: 6) {
                numField("输入", $newInput); numField("缓存读", $newCacheRead)
                numField("缓存写", $newCacheWrite); numField("输出", $newOutput)
                Button("添加") { add() }
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty || Double(newInput) == nil || Double(newOutput) == nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func numField(_ label: String, _ text: Binding<String>) -> some View {
        TextField(label, text: text).textFieldStyle(.roundedBorder).frame(width: 90)
    }

    private func add() {
        guard let i = Double(newInput), let o = Double(newOutput) else { return }
        pricing.overrides[newModel.trimmingCharacters(in: .whitespaces)] = ModelPrice.perMillion(
            input: i, output: o,
            cacheRead: Double(newCacheRead), cacheWrite: Double(newCacheWrite)
        )
        newModel = ""; newInput = ""; newCacheRead = ""; newCacheWrite = ""; newOutput = ""
    }
}

// MARK: - 显示与留存

/// 「显示与留存」页签。
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

    /// 工装注入用。`ImageRenderer` **不会跑 `.task`**，不注入的话离屏快照只能拍到
    /// 「正在统计…」那个占位，这一页的排版就没法核对了。
    var injectedReport: RetentionReport?

    @State private var loaded: RetentionReport?
    @State private var copied = false

    private var report: RetentionReport? { injectedReport ?? loaded }

    var body: some View {
        Form {
            retentionSection
            coverageSection
            menuBarSection
        }
        .formStyle(.grouped)
        // 跟着 `lastScan` 重算：用户可能在别的页签点了「立即重扫」，或者主窗口刚扫完
        .task(id: store.lastScan) { await reload() }
    }

    // MARK: 留存

    private var retentionSection: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.system(size: 12))
                    if let detail = statusDetail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // 状态不只靠颜色：图标 + 文字 + 颜色三条都在（照「对比度警告不能只靠颜色」那条来）
            HStack(spacing: 8) {
                Text("建议").font(.system(size: 12))
                Text("\(RetentionReport.suggestedCleanupDays) 天")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                Button(copied ? "已复制" : "复制片段") { copySnippet() }.controlSize(.small)
                Spacer()
                Button("重新检测") { Task { await reload() } }.controlSize(.small)
            }
            Text(RetentionReport.cleanupSnippet())
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.cardBorder))
            Text("路径 \(RetentionReport.claudeSettingsPath)（只读，本 App 不会替你改这个文件）")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Claude Code 本地日志保留")
        } footer: {
            Text("370 天约等于一年。注意这句诚实的话：**档案只覆盖本 App 已经开始统计之后的日子** —— 在那之前被 Claude Code 删掉的日志找不回来，调大这个值只是让以后不再丢。")
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

    private var coverageSection: some View {
        Section {
            if let r = report {
                if r.comparison.isEmpty {
                    Text("两边都还没有数据。先在主窗口扫一次，或者等待首次同步。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("环境").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("本机日志").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("档案").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("档案独有").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        ForEach(r.comparison) { c in comparisonRow(c) }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("覆盖对照")
                Spacer()
                if let r = report, r.archiveOnlyDaysTotal > 0 {
                    Text("只在档案里：\(r.archiveOnlyDaysTotal) 天")
                        .font(.caption).foregroundStyle(Theme.statusGood)
                }
            }
        } footer: {
            Text("「天」指**有数据的天数**，不是首尾相隔的天数 —— 中间没用量的日子不计，所以 38 天可能横跨五个月。本机日志 = 上次扫描实际读到的日期；档案 = 共享目录里各设备的聚合行与每日会话数。绿色数字是**档案里有、本机日志里已经没有**的天数：可能来自本地日志被清理，也可能那几天本来就是另一台设备的记录。")
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

    private var menuBarSection: some View {
        Section {
            Toggle("在菜单栏显示", isOn: $menuBar.config.showInMenuBar)
            MetricPicker(title: "菜单栏文字",
                         note: "最多 \(MenuBarConfig.maxLabelItems) 项 —— 菜单栏是所有 App 共享的一条，排太多会把别人的图标挤走。一项都不选就只留图标。",
                         limit: MenuBarConfig.maxLabelItems,
                         selection: $menuBar.config.label)
            MetricPicker(title: "面板指标",
                         note: "点开菜单栏图标后显示哪几项，顺序就是显示顺序；「本月」那一组前面会自动加一条分隔线。",
                         limit: nil,
                         selection: $menuBar.config.panel)
        } header: {
            Text("菜单栏")
        } footer: {
            Text("关掉只是不显示菜单栏图标，主窗口与 Dock 图标照常（没有开 LSUIElement）。菜单栏与面板里的数都是固定窗口（今日 / 本月 / 近 7 天），**不跟随主窗口选的日期范围** —— 点一下菜单栏就把主窗口的日期范围改掉，那是劫持。")
        }
    }

    // MARK: 动作

    private func reload() async {
        let records = store.records
        let files = store.deviceSync.readAll().files
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
                    Text("最多 \(limit ?? 0) 项").font(.caption).foregroundStyle(Theme.statusWarning)
                }
            }
            HStack(spacing: 6) {
                ForEach(MenuBarMetric.allCases) { m in
                    FilterChip(title: m.label, color: Theme.primary, selected: selection.contains(m)) { toggle(m) }
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
