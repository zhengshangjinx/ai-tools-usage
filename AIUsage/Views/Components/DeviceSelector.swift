import SwiftUI
import AppKit

/// 顶部设备选择器：多选。全选=汇总，只勾一台=只看那台。
/// 数据来自 iCloud 共享目录里各设备自己写的档案（见 Sync/DeviceSync.swift）。
///
/// 布局：左边一个图标按钮（样式跟右侧刷新/设置同款，点开同步弹层），右边把勾选中的设备
/// 平铺成 chips。设备名不再挤在按钮里 —— 汇总了哪几台一眼就能看到，跟下面的环境行一个读法。
struct DeviceSelector: View {
    @EnvironmentObject var store: UsageStore
    @State private var showPopover = false

    private var isFiltering: Bool { !store.isAllDevicesSelected }

    var body: some View {
        HStack(spacing: 8) {
            trigger
            DeviceChips(openPopover: { showPopover = true })
        }
    }

    private var trigger: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: isFiltering ? "laptopcomputer" : "square.stack.3d.up")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isFiltering || showPopover ? Theme.primary : Theme.gray600)
                .frame(width: 32, height: 32)
                .background(showPopover ? Theme.hover : Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(showPopover ? Theme.primary : Theme.cardBorder, lineWidth: showPopover ? 1.5 : 1))
                .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
                .animation(.easeOut(duration: 0.15), value: showPopover)
                .overlay(alignment: .topTrailing) {
                    // 同步告警原先挂在按钮的文字后面，现在文字没了 —— 改角标，别让它只藏在弹层里
                    if !store.syncWarnings.isEmpty {
                        Circle().fill(Theme.statusWarning)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Theme.cardBackground, lineWidth: 1.5))
                            .offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("设备范围：\(store.deviceSelectionLabel)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DevicePopover(store: store, dismiss: { showPopover = false })
        }
    }
}

/// 勾选中的设备平铺展示，跟下面环境行同一套 chips，交互也一致。
struct DeviceChips: View {
    @EnvironmentObject var store: UsageStore
    var openPopover: () -> Void = {}

    /// 设备名比环境名长得多（系统电脑名一个就顶两个环境 chip），
    /// 平铺超过 3 台就会挤到右边那组模式切换上，多出来的折成「+N」点开弹层看全。
    private static let maxChips = 3

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            if store.devices.count <= 1 {
                // 只有一台时「全部设备」没有信息量，直接顶设备名
                FilterChip(title: store.devices.first?.name ?? DeviceIdentity.name,
                           color: Theme.primary, selected: true) {}
            } else {
                // 计数跟下面「全部环境 N」对齐；设备名长，chips 只铺前 3 台，
                // 这个数字是唯一能看出「一共连了几台」的地方
                FilterChip(title: "全部设备", color: Theme.gray900, count: store.devices.count,
                           selected: store.isAllDevicesSelected) {
                    store.selectAllDevices()
                }
                ForEach(Array(store.devices.prefix(Self.maxChips))) { d in
                    FilterChip(title: d.name, color: Theme.primary,
                               selected: !store.isAllDevicesSelected && store.selectedDevices.contains(d.id)) {
                        store.toggleDevice(d.id)
                    }
                }
                if store.devices.count > Self.maxChips {
                    FilterChip(title: "+\(store.devices.count - Self.maxChips)", color: Theme.gray500,
                               selected: false, action: openPopover)
                }
            }
        }
        // 筛选区里没有需要保护的右侧控件，chips 可以铺满整行，放不下就折行
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DevicePopover: View {
    @ObservedObject var store: UsageStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("展示范围")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray500)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)

            row(title: "全部设备（汇总）",
                detail: "\(store.devices.count) 台",
                checked: store.isAllDevicesSelected,
                emphasized: true) { store.selectAllDevices() }

            if store.devices.count > 1 {
                Rectangle().fill(Theme.divider).frame(height: 1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                ForEach(store.devices) { d in
                    row(title: d.name,
                        detail: d.isLocal ? "本机" : relative(d.updatedAt),
                        checked: !store.isAllDevicesSelected && store.selectedDevices.contains(d.id)) {
                        store.toggleDevice(d.id)
                    }
                }
            }

            footer
        }
        .frame(width: 288)
        .background(Theme.cardBackground)
    }

    private func row(title: String, detail: String, checked: Bool, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(checked ? Theme.primary : Theme.gray500.opacity(0.5))
            Text(title)
                .font(.system(size: 12.5, weight: emphasized ? .medium : .regular))
                .foregroundStyle(Theme.gray900)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.gray500)
        }
        .padding(.horizontal, 14).frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private var footer: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10).padding(.top, 4)
        VStack(alignment: .leading, spacing: 6) {
            if let err = store.syncWarnings.first {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(Theme.statusWarning)
                    Text(err).font(.system(size: 11)).foregroundStyle(Theme.gray700)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !store.syncEnabled {
                Text("跨设备同步已关闭，仅统计本机。")
                    .font(.system(size: 11)).foregroundStyle(Theme.gray500)
            } else if let last = store.lastSync {
                Text("上次同步 \(relative(last)) · 每台设备各写各的档案，互不覆盖")
                    .font(.system(size: 11)).foregroundStyle(Theme.gray500)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Text("立即同步").font(.system(size: 11.5))
                }
                .buttonStyle(.link)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.deviceSync.folderURL])
                } label: {
                    Text("在 Finder 中显示").font(.system(size: 11.5))
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
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
