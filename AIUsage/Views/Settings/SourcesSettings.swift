import SwiftUI

/// 数据源。每个工具一张卡：能不能拿到 token 明细、扫哪里、扫到了没有。
///
/// 改造前这里是 `Form { Section { … } }`。**只换了容器**，卡里的
/// `TextEditor` / 按钮 / 文案一字未动 —— 换容器的风险是有界的，而且有快照兜底。
/// （后来那几样控件换成了 `SettingsControls` 里自绘的版本，因为 AppKit 默认外观在这一页最扎眼。）
struct SourcesSettings: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        SettingsDetailPage(SettingsPane.sources.title, subtitle: SettingsPane.sources.subtitle) {
            SettingsScroll {
                ForEach(SourceKind.allCases) { kind in
                    card(for: kind)
                }
                scanCard
            }
        }
    }

    private func card(for kind: SourceKind) -> some View {
        SettingsCard(kind.displayName) {
            HStack(spacing: 6) {
                capabilityTag(kind)
                if !kind.isDetected {
                    Text("未检测到")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.gray500)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.segmentBackground, in: Capsule())
                }
                Spacer(minLength: 8)
                Toggle("", isOn: binding(kind).enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                SettingsTextEditor(text: pathsBinding(kind))
                HStack(alignment: .firstTextBaseline) {
                    SettingsNote(kind.pathHint + "，每行一个")
                    Spacer(minLength: 8)
                    Button("恢复默认") { store.resetPaths(for: kind) }.settingsButton()
                }
            }
        }
    }

    private var scanCard: some View {
        SettingsCard("扫描",
                     footer: "解析结果按文件缓存在 ~/Library/Application Support/AIUsage，仅重新解析变化过的文件。") {
            HStack(spacing: 10) {
                if let last = store.lastScan {
                    SettingsNote("上次扫描 \(Formatters.stamp(last)) · \(store.records.count) 条记录 · 耗时 \(String(format: "%.1fs", store.scanDuration))")
                } else {
                    SettingsNote("尚未扫描。")
                }
                Spacer(minLength: 8)
                Button("清除缓存并重扫") {
                    ScanCache.shared.clear()
                    Task { await store.refresh() }
                }
                .settingsButton()
                .disabled(store.isScanning)
                Button("立即重扫") { Task { await store.refresh() } }
                    .settingsButton(.primary)
                    .disabled(store.isScanning)
            }
        }
    }

    private func capabilityTag(_ kind: SourceKind) -> some View {
        let color: Color
        switch kind.capability {
        case .tokens: color = Theme.statusGood
        case .sessionsOnly: color = Theme.statusWarning
        case .unavailable: color = Theme.statusCritical
        }
        return Text(kind.capability.label)
            .font(.system(size: 11)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func binding(_ kind: SourceKind) -> Binding<SourceConfig> {
        Binding(
            get: { store.sourceConfigs[kind] ?? SourceConfig(paths: kind.configuredDefaultPaths) },
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
