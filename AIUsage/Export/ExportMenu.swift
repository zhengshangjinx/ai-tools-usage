import SwiftUI
import AppKit

// MARK: - 从界面状态构造一份导出输入

/// 把当前界面状态原样翻成 `ExportContext`。
///
/// 「所见即所得」这条承诺就落在这里：行取 `store.visibleRows`（表格画的就是它）、
/// 占比取 `snapshot.share(of:by:sort.shareBasis)`（表头副标题写的就是它）、
/// 价格取 `PricingService`（界面上显示金额用的就是它）。
/// 三处都**不复算**，所以导出的数不可能与屏幕上的数不一致。
@MainActor
extension ExportContext {
    static func from(store: UsageStore, pricing: PricingService) -> ExportContext {
        let mode = store.breakdown
        let sort = store.sort
        return ExportContext(
            mode: mode,
            sort: sort,
            rows: store.visibleRows,
            totals: store.snapshot.totals,
            share: { store.snapshot.share(of: $0, by: sort.shareBasis) },
            price: { pricing.price(for: $0) },
            priceSource: { pricing.source(for: $0) },
            priceTableUpdated: pricing.lastUpdated,
            rangeStart: store.rangeStart,
            rangeEnd: store.rangeEnd,
            selectedProviders: Array(store.selectedProviders),
            deviceLabel: store.deviceSelectionLabel,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        )
    }
}

// MARK: - 导出按钮

/// 「导出」按钮：图标 + 三格式菜单 → 存盘面板。
///
/// 放在 `FilterBar.viewOptions` 里，**不能放 `TitleStrip`** —— 那是一条
/// `Color.clear` + `.allowsHitTesting(false)` 的 28pt 占位条，存在的全部意义是给
/// `.hiddenTitleBar` 下的交通灯让位、把拖拽透传给真正的标题栏。往里塞控件就得重新打开命中测试，
/// 代价是窗口拖不动了。
///
/// **按钮本身用 `IconButton`、菜单用 `NSMenu`，不用 SwiftUI 的 `Menu`。**
/// `Menu` 由 AppKit 承载，离屏渲染画不出来 —— 实测在 `--render` 的快照里它会画成一个
/// 黄底红圈的禁止符号，于是每次出图工具栏上都留着一个看着像坏掉的方块，
/// 回归检查时没法一眼扫过去（`Form` 是同一个毛病，见 `RenderHarness.captureWindow`）。
/// 自己画按钮 + 原生 `NSMenu`，两边都正常。
struct ExportMenu: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService

    var body: some View {
        IconButton(systemName: "square.and.arrow.up",
                   help: "把当前筛选结果导出为文件（导出的就是屏幕上这份表：同样的行、同样的顺序、同样的口径）",
                   size: 34) {
            popUp()
        }
    }

    private func popUp() {
        let menu = NSMenu()
        // 行数写进第一行，点之前就知道会导出多少条；它是说明不是命令，所以禁用
        let header = NSMenuItem(title: "导出当前 \(store.visibleRows.count) 行", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        // target 要活到菜单收起来：`popUp` 是同步的（菜单关掉才返回），所以局部强引用就够
        let target = MenuActionTarget()
        for format in ExportFormat.allCases {
            menu.addItem(target.add("\(format.label)（.\(format.fileExtension)）") { save(format) })
        }
        // `in: nil` 表示用屏幕坐标，而当前鼠标位置就是用户刚点的那个按钮
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    private func save(_ format: ExportFormat) {
        let ctx = ExportContext.from(store: store, pricing: pricing)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = UsageExporter.defaultFileName(ctx, format: format)
        panel.canCreateDirectories = true
        panel.message = "导出当前筛选结果（\(store.visibleRows.count) 行）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .json ? UsageExporter.json(ctx) : UsageExporter.table(ctx, format: format)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// `NSMenu` 的动作转发：一个对象收下一串闭包，菜单项只带一个下标。
/// 用下标而不是把闭包塞进 `representedObject` —— 后者要包一层 `NSObject`，还不如直接查表。
@MainActor
private final class MenuActionTarget: NSObject {
    private var actions: [() -> Void] = []

    func add(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions.append(action)
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}

// MARK: - `--export` 工装

/// `--export <目录> [csv|tsv|json] [device|model|day]`：不点界面就产出真实文件，
/// 好让「BOM / CRLF / 转义 / 空值 / 精度」这些只能逐字节核的东西有个可复核的产物。
/// 参数省略时三种格式 × 三个维度全出（九个文件），一次跑完一张矩阵。
///
/// 与 `--render` / `--bench` 同一挂点、同一份 store/pricing，**不额外联网**。
enum ExportHarness {
    static var request: (dir: String, formats: [ExportFormat], modes: [BreakdownMode])? {
        guard let i = CommandLine.arguments.firstIndex(of: "--export"),
              i + 1 < CommandLine.arguments.count else { return nil }
        let rest = Array(CommandLine.arguments[(i + 2)...])
        let formats = ExportFormat.allCases.filter { f in rest.contains { $0.lowercased() == f.fileTag } }
        let modes = BreakdownMode.allCases.filter { m in rest.contains { $0.lowercased() == m.fileTag } }
        return (CommandLine.arguments[i + 1],
                formats.isEmpty ? ExportFormat.allCases : formats,
                modes.isEmpty ? BreakdownMode.allCases : modes)
    }

    @MainActor
    static func run(store: UsageStore, pricing: PricingService, request: (dir: String, formats: [ExportFormat], modes: [BreakdownMode])) {
        let dir = URL(fileURLWithPath: request.dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for mode in request.modes {
            // 跟离屏渲染同一个手法：直接改 store.breakdown 取那一维的行。
            // 这里没有别的观察者会受害（工装跑完就 exit），菜单栏那类常驻界面不能这么干。
            store.breakdown = mode
            let ctx = ExportContext.from(store: store, pricing: pricing)
            for format in request.formats {
                let text = format == .json ? UsageExporter.json(ctx) : UsageExporter.table(ctx, format: format)
                let url = dir.appendingPathComponent(UsageExporter.defaultFileName(ctx, format: format))
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    print("exported \(url.path) (\(text.utf8.count) bytes, \(ctx.rows.count) rows)")
                } catch {
                    print("export failed \(url.path): \(error.localizedDescription)")
                }
            }
        }
        // 跟 `RenderHarness.run` 一样跑完就退：工装没有窗口挂载，不退的话进程会一直挂着
        exit(0)
    }
}
