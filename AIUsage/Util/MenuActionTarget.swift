import AppKit

/// `NSMenu` 的动作转发：一个对象收下一串闭包，菜单项只带一个下标。
/// 用下标而不是把闭包塞进 `representedObject` —— 后者要包一层 `NSObject`，还不如直接查表。
///
/// 调用方要**活到菜单收起来**：`popUp(positioning:at:in:)` 是同步的（菜单关掉才返回），
/// 所以调用方那边的局部强引用就够了（`ExportMenu` / `RefreshIntervalControl` 都这么用）。
///
/// 独立成一个文件是因为现在有两个调用方：导出按钮和定时刷新下拉。
/// 它们都**不用 SwiftUI 的 `Menu`** —— 那个由 AppKit 承载，离屏出图会画成一个黄底红圈的
/// 禁止符号（账记在 `ExportMenu` 开头）。
@MainActor
final class MenuActionTarget: NSObject {
    private var actions: [() -> Void] = []

    /// `checked` 只影响打不打勾；菜单项的其它属性（如 `keyEquivalent`）由调用方拿返回值自己设
    func add(_ title: String, checked: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.state = checked ? .on : .off
        actions.append(action)
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
