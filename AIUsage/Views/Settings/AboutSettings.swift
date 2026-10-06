import SwiftUI
import AppKit

/// 关于。版本、检查更新、仓库链接、许可。
///
/// 侧栏底部那一行是「不用去找」的入口，这一页是「想看清楚」的入口 ——
/// 两者读的是同一个 `UpdateService`，所以状态不会各说各话。
struct AboutSettings: View {
    @EnvironmentObject var update: UpdateService
    /// 与 `UpdateService` **共用同一个实例**（由 `AIUsageApp` 建好后分别注入）。
    /// 自己 new 一个的话键是同一批，但两份内存副本会各走各的。
    @EnvironmentObject var updateSettings: UpdateSettings

    var body: some View {
        SettingsDetailPage(SettingsPane.about.title, subtitle: SettingsPane.about.subtitle) {
            SettingsHeaderAction(title: "检查更新", busy: update.busy) {
                Task { await update.checkNow() }
            }
        } content: {
            SettingsScroll {
                identityCard
                updateCard
                linksCard
                licenseCard
            }
        }
    }

    // MARK: 身份

    private var identityCard: some View {
        SettingsCard("AI Usage") {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("版本 \(UpdateService.currentVersion)（\(UpdateService.currentBuild)）")
                        .font(.system(size: 13, weight: .medium))
                    SettingsNote("原生 macOS 菜单栏工具：把本机各个 AI 编程助手留下的会话日志收拢起来，统计 token 用量与估算费用。")
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 更新

    private var updateCard: some View {
        SettingsCard("自动更新",
                     footer: "检查更新只是一次 GET：它把公开的发布列表拉下来比对版本，不上传你机器上的任何东西。"
                           + "安装包下载后会按发布页公布的 SHA-256 校验，然后替换 App 并重启 —— "
                           + "App 是 ad-hoc 签名、没有开发者证书，所以这道校验防的是**损坏与下载截断**，不是伪造。") {
            SettingsRow("自动检查") {
                Toggle("自动检查更新", isOn: $updateSettings.autoCheckEnabled)
                    .toggleStyle(.switch).controlSize(.small)
            }
            SettingsRule()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.system(size: 12))
                    if let detail = statusDetail { SettingsNote(detail) }
                }
                Spacer(minLength: 0)
                // 两个动作分开摆：`available` 时是「先别提示我」，`readyToInstall` 时是
                // 「现在就换」—— 后者会退进程并重启，所以旁边必须有「稍后」。
                switch update.phase {
                case .available(let release):
                    Button("跳过这个版本") { update.skip(release) }.settingsButton()
                case .readyToInstall:
                    Button("稍后") { update.discardStaged() }.settingsButton()
                    Button("立即更新并重启") { update.installStaged() }.settingsButton(.primary)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var statusIcon: String {
        switch update.phase {
        case .available: return "arrow.down.circle.fill"
        case .readyToInstall: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .checking, .downloading, .installing: return "clock"
        case .idle: return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch update.phase {
        case .available, .readyToInstall: return Theme.primary
        case .failed: return Theme.statusWarning
        case .idle: return Theme.statusGood
        default: return Theme.gray500
        }
    }

    private var statusTitle: String {
        switch update.phase {
        case .idle(let lastCheck):
            guard let lastCheck else { return "还没有检查过" }
            return "已是最新版本（\(Formatters.stamp(lastCheck)) 检查过）"
        case .checking: return "正在检查…"
        case .available(let r): return "有新版本 \(r.version)"
        case .downloading(let r, let p):
            return p > 0 ? "正在下载 \(r.version)… \(Int(p * 100))%" : "正在下载 \(r.version)…"
        case .readyToInstall(let r, _): return "\(r.version) 已下载并校验通过，等你确认"
        case .installing(let r): return "正在安装 \(r.version)，马上会重启…"
        case .failed(let message): return message
        }
    }

    private var statusDetail: String? {
        switch update.phase {
        case .available(let r):
            if r.asset == nil {
                return "这个版本没有可下载的安装包，去发布页手动下载。"
            }
            var s = "安装包 \(r.asset!.name)（\(byteText(r.asset!.size))）"
            s += r.checksum != nil ? "，发布页公布了 SHA-256。" : "。"
            return s
        case .readyToInstall(_, let staged):
            // 说清楚「点下去会发生什么」，以及包现在躺在哪（失败时用户还能自己去拿）。
            // 路径在演示模式下换成 `/Users/you/...`：这一行会把**装 App 的那个目录**原样画出来，
            // 出图时那就是作者的家目录（照 `SourceKind.configuredDefaultPaths` 那处的做法）。
            return "点「立即更新并重启」会替换正在运行的那一份 App（\(shownBundlePath)）并重新启动它。"
                 + "安装包暂存在 \(staged.deletingLastPathComponent().path)。"
        case .idle:
            return "每 6 小时最多自动检查一次；点上面的「检查更新」可以立刻查。"
        default:
            return nil
        }
    }

    /// 正在跑的这一份 App 在哪。正常就是 `/Applications/AI Usage.app`；
    /// 开发时会落在 `build/Build/Products/Release/…` 下面 —— 那串路径里有作者的用户名，
    /// 演示模式（出图）下同样要换掉。
    private var shownBundlePath: String {
        let path = Bundle.main.bundleURL.path
        guard DemoRuntime.isActive else { return path }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "/Users/you")
    }

    private func byteText(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: 链接与许可

    private var linksCard: some View {
        SettingsCard("链接") {
            linkRow("GitHub 仓库", "github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)",
                    "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)")
            SettingsRule()
            linkRow("更新日志", "releases", "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/releases")
            SettingsRule()
            linkRow("问题反馈", "issues", "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/issues")
        }
    }

    private func linkRow(_ title: String, _ detail: String, _ url: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            SettingsNote(detail)
            SettingsIconButton(systemName: "arrow.up.right.square", help: url, size: 22) {
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
        }
    }

    private var licenseCard: some View {
        SettingsCard("许可",
                     footer: "价格数据来自 LiteLLM（MIT）。本项目与 Anthropic、OpenAI、Cursor、Devin 等任何 AI 厂商均无关联，也未获其授权或背书。") {
            HStack(spacing: 8) {
                Text("MIT").font(.system(size: 12))
                Spacer(minLength: 8)
                SettingsNote("© 2026 zhengshangjinx")
            }
        }
    }
}
