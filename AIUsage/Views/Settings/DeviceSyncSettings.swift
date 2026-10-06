import SwiftUI
import AppKit

/// 设备与同步。本机身份、共享目录、已经发现的设备。
struct DeviceSyncSettings: View {
    @EnvironmentObject var store: UsageStore
    @State private var draftName: String = DeviceIdentity.name
    @State private var nameDirty = false

    var body: some View {
        SettingsDetailPage(SettingsPane.devices.title,
                           subtitle: SettingsPane.devices.subtitle) {
            // 「立即同步」原本在共享目录那一节里，现在提到页头右侧 ——
            // 它是这一页的主动作，跟它属于哪一节没关系。
            SettingsHeaderAction(title: "立即同步", busy: store.isScanning) { store.resync() }
        } content: {
            SettingsScroll {
                identityCard
                folderCard
                devicesCard
            }
        }
        .onAppear { draftName = DeviceIdentity.name }
    }

    private var identityCard: some View {
        SettingsCard("本机身份",
                     footer: "设备 ID 是首次启动生成的稳定 UUID，改名不会造成重复设备；档案文件名用的是 ID。") {
            SettingsRow("跨设备同步") {
                Toggle("", isOn: $store.syncEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            SettingsRule()
            SettingsRow("设备名称") {
                HStack(spacing: 8) {
                    SettingsTextField("这台设备叫什么", text: $draftName, width: 240)
                        .onChange(of: draftName) { _, new in nameDirty = new != DeviceIdentity.name }
                    if nameDirty {
                        Button("应用") {
                            DeviceIdentity.name = draftName
                            nameDirty = false
                            store.resync()
                        }.settingsButton(.primary)
                        Button("取消") { draftName = DeviceIdentity.name; nameDirty = false }
                            .settingsButton()
                    }
                }
            }
        }
    }

    private var folderCard: some View {
        SettingsCard("共享目录",
                     footer: "每台设备只写自己的 device-<ID>.json，互不覆盖，因此不需要加锁也不会产生写冲突。换目录即可换用 Dropbox 等其他同步盘。") {
            HStack(spacing: 6) {
                Image(systemName: DeviceSync.defaultFolderAvailable ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(DeviceSync.defaultFolderAvailable ? Theme.statusGood : Theme.statusWarning)
                Text(store.deviceSync.folderURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.gray700)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("更改…") { chooseFolder() }.settingsButton()
                Button("恢复默认") {
                    store.deviceSync.folderURL = DeviceSync.defaultFolder
                    store.resync()
                }.settingsButton()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.deviceSync.folderURL])
                }.settingsButton()
                Spacer(minLength: 0)
            }
            if !DeviceSync.defaultFolderAvailable {
                SettingsNote("未检测到 iCloud Drive。请先在系统设置里登录 iCloud 并启用 iCloud 云盘，或把上面的目录改成其他同步盘。")
            }
        }
    }

    private var devicesCard: some View {
        SettingsCard("已发现的设备（\(store.devices.count)）",
                     footer: "同步的是「日 × 环境 × 模型」的 token 聚合行与每日会话数，不含会话内容；费用在展示端用本机价格表重算，所以历史会随价格表更新自动重估。") {
            ForEach(store.devices) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.isLocal ? "laptopcomputer" : "desktopcomputer")
                        .foregroundStyle(d.isLocal ? Theme.primary : Theme.gray500)
                    Text(d.name).font(.system(size: 12, weight: d.isLocal ? .medium : .regular))
                    if d.isLocal {
                        Text("本机").font(.system(size: 10)).foregroundStyle(Theme.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.primarySoft, in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text("\(d.rowCount) 行聚合").font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                    Text(relative(d.updatedAt)).font(.system(size: 11)).foregroundStyle(Theme.gray500)
                    if !d.isLocal {
                        SettingsIconButton(systemName: "trash",
                                           help: "从共享目录删除这台设备的档案；该设备下次同步会重新写入",
                                           destructive: true) {
                            store.deviceSync.remove(deviceId: d.id)
                            store.resync()
                        }
                    }
                }
            }
            if !store.syncWarnings.isEmpty {
                SettingsRule()
                ForEach(store.syncWarnings, id: \.self) { w in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.statusWarning)
                        SettingsNote(w)
                    }
                }
            }
        }
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
        // 与界面语言一致：bundle 没声明本地化，Locale.current 会落回 en（见 Formatters.dayFormatter）
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
