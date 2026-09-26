import SwiftUI
import AppKit

/// 顶部环境选择：和设备行同一套长相 —— 左边一个图标按钮开概览弹层，右边把环境 chips 平铺开。
/// 两行挨在一起，因为它们本来就是同一件事：都是「看哪些数据」的维度筛选。
struct EnvironmentSelector: View {
    @EnvironmentObject var store: UsageStore
    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 8) {
            trigger
            chips
        }
    }

    private var trigger: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(showPopover ? Theme.primary : Theme.gray600)
                .frame(width: 32, height: 32)
                .background(showPopover ? Theme.hover : Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(showPopover ? Theme.primary : Theme.cardBorder, lineWidth: showPopover ? 1.5 : 1))
                .shadow(color: .black.opacity(0.03), radius: 1.5, y: 1)
                .animation(.easeOut(duration: 0.15), value: showPopover)
        }
        .buttonStyle(.plain)
        .help("环境概览：各环境的用量、会话数与数据源")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            EnvironmentPopover(store: store, dismiss: { showPopover = false })
        }
    }

    private var chips: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            FilterChip(title: "全部环境", color: Theme.gray900, count: store.visibleProviders.count,
                       selected: store.isAllProvidersSelected) { store.selectAllProviders() }
            ForEach(store.visibleProviders) { p in
                FilterChip(title: p.displayName, color: p.accent, count: sessionCount(p),
                           selected: !store.isAllProvidersSelected && store.selectedProviders.contains(p)) {
                    store.toggleProvider(p)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionCount(_ p: ProviderKind) -> Int? {
        // 计数来自不受环境筛选影响的统计：选中一个环境不该让别的 chip 变窄
        store.snapshot.chipSessionCounts[p]
    }
}

/// 环境概览：每个环境的 tokens / 费用 / 会话数，以及数据源有没有被检测到。
/// 只读 —— 开关数据源和改路径都留在「设置 › 数据源」里做，那里才挨着路径编辑器。
private struct EnvironmentPopover: View {
    @ObservedObject var store: UsageStore
    let dismiss: () -> Void
    @Environment(\.openSettings) private var openSettings

    private var total: Double { Double(max(store.snapshot.totals.processed, 1)) }

    private var ordered: [ProviderKind] {
        ProviderKind.allCases.sorted {
            let a = stat($0)?.tokens ?? -1, b = stat($1)?.tokens ?? -1
            return a == b ? $0.rawValue < $1.rawValue : a > b
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("环境概览").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.gray500)
                Text("当前范围内 \(activeCount) 个环境有用量 · 按 Tokens 排序")
                    .font(.system(size: 11)).foregroundStyle(Theme.gray500)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            HStack(spacing: 0) {
                Text("环境").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 66, alignment: .trailing)
                Text("费用").frame(width: 80, alignment: .trailing)
                Text("会话").frame(width: 52, alignment: .trailing)
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.gray500)
            .padding(.horizontal, 14).padding(.bottom, 4)

            ForEach(ordered, id: \.self) { p in
                row(p)
            }

            Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10).padding(.top, 6)
            HStack(spacing: 10) {
                Text("数据源与路径在设置里配置").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                Spacer(minLength: 0)
                Button {
                    dismiss()
                    openSettings()
                } label: {
                    Text("打开设置").font(.system(size: 11.5))
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        }
        .frame(width: 356)
        .background(Theme.cardBackground)
    }

    private func row(_ p: ProviderKind) -> some View {
        let s = stat(p)
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(p.accent).frame(width: 7, height: 7)
                Text(p.displayName).font(.system(size: 12)).foregroundStyle(Theme.gray900).lineLimit(1)
                if !p.source.isDetected {
                    Text("未检测到").font(.system(size: 9.5)).foregroundStyle(Theme.gray500)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.divider, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // token 为 0 但会话数不为 0 的环境是「仅会话」类型，这里如实显示 0，不写成 —
            Text(s.map { Formatters.tokens($0.tokens) } ?? "—")
                .font(.system(size: 11.5)).foregroundStyle(Theme.gray700).monospacedDigit()
                .frame(width: 66, alignment: .trailing)
            Text(s.map { Formatters.cost($0.cost) } ?? "—")
                .font(.system(size: 11.5)).foregroundStyle(Theme.gray700).monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Text(s.map { "\($0.sessionCount)" } ?? "—")
                .font(.system(size: 11.5)).foregroundStyle(Theme.gray700).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 26)
        .help(pathHint(p))
    }

    private func stat(_ p: ProviderKind) -> ProviderSummary? {
        store.snapshot.providers.first { $0.kind == p }
    }

    private var activeCount: Int { store.snapshot.providers.count }

    private func pathHint(_ p: ProviderKind) -> String {
        let paths = store.sourceConfigs[p.source]?.paths ?? p.source.defaultPaths
        let head = paths.prefix(2).joined(separator: "\n")
        return paths.isEmpty ? "\(p.displayName)：没有配置数据源路径" : "\(p.displayName) 数据源：\n\(head)"
    }
}
