import SwiftUI

/// 设置窗口左侧那一列：分组导航 + 底部钉一行更新提示。
///
/// 手搭而不是用 `NavigationSplitView`，理由见 `SettingsView` 开头那段账。
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 12)
            ForEach(SettingsGroup.allCases) { group in
                sectionHeader(group.title)
                ForEach(group.panes) { pane in
                    SidebarRow(pane: pane, selected: selection == pane) { selection = pane }
                }
            }
            Spacer(minLength: 12)
            UpdateSidebarRow()
            Spacer().frame(height: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebarBackground)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.gray500)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }
}

/// 一行导航。做成真 `Button`（而不是 `onTapGesture`）是为了拿回键盘与辅助功能：
/// 手搭侧栏丢掉了 `List` 自带的方向键导航，至少要让 VoiceOver 读得出「已选中」。
private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 18)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Theme.gray700)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.primary : (hovering ? Theme.hover : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 底部更新行

/// 钉在侧栏底部的那一条。形态照参考图：图标 + 「更新到 x.y.z」+ 右侧当前版本号。
///
/// 它**不属于任何一个页**：更新是全局的，塞进「关于」页就等于藏起来了 ——
/// 而这一行的全部意义就是「不用去找」。
private struct UpdateSidebarRow: View {
    @EnvironmentObject var update: UpdateService
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch update.phase {
            case .checking:
                plain {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检查…")
                    }
                }
            case .available(let release):
                if release.asset != nil {
                    pill(icon: "arrow.down.circle.fill", title: "更新到 \(release.version)",
                         trailing: "v\(UpdateService.currentVersion)") {
                        Task { await update.downloadAndInstall() }
                    }
                } else {
                    // 没有可下载的包就别假装能一键装，把人送到发布页去
                    pill(icon: "arrow.up.right.square", title: "打开下载页", trailing: nil) {
                        update.openReleasePage(release)
                    }
                }
            case .downloading(let release, let progress):
                pill(icon: "arrow.down.circle", title: "正在下载 \(release.version)",
                     trailing: progress > 0 ? "\(Int(progress * 100))%" : nil,
                     disabled: true) {}
            // 包已经下回来、验完了，就差点头。**这一行是用户唯一能反悔的地方** ——
            // 下一秒 App 就要退掉、被替换、再起来，所以「稍后」必须跟它并排摆着。
            case .readyToInstall(let release, _):
                VStack(alignment: .leading, spacing: 4) {
                    pill(icon: "arrow.triangle.2.circlepath", title: "重启并更新到 \(release.version)",
                         trailing: nil) { update.installStaged() }
                    Button("稍后") { update.discardStaged() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.gray500)
                        .padding(.horizontal, 10)
                }
            case .installing(let release):
                pill(icon: "arrow.triangle.2.circlepath", title: "正在替换 \(release.version)…",
                     trailing: nil, disabled: true) {}
            case .failed(let message):
                plain {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") { Task { await update.checkNow() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.primary)
                    }
                }
            case .idle(let lastCheck):
                if lastCheck == nil {
                    Button("检查更新") { Task { await update.checkNow() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.gray500)
                        .padding(.horizontal, 10)
                } else {
                    plain { Text("已是最新版本") }
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// 安静的纯文字态：没有底色，不抢注意力。
    private func plain<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 11))
            .foregroundStyle(Theme.gray500)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(icon: String, title: String, trailing: String?,
                      disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.gray500)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.primarySoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.primary.opacity(hovering && !disabled ? 0.35 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
