import SwiftUI
import AppKit

/// 「定时刷新」下拉。**两处共用**：主窗口筛选行的工具组、菜单栏面板的标题行。
///
/// 状态只有一份（`store.refreshMinutes`），所以两处永远显示同一个档位 ——
/// 在面板里改成 10 分钟，主窗口那颗按钮上的字跟着变，反之亦然。
///
/// **按钮自绘 + `NSMenu`，不用 SwiftUI 的 `Menu`**：与 `ExportMenu` 同一条账 ——
/// `Menu` 由 AppKit 承载，离屏出图会画成一个黄底红圈的禁止符号，而这两处**都在
/// `--render` 的出图范围里**（主界面与面板各有一张快照），出图一旦出方块就没法当回归基线了。
struct RefreshIntervalControl: View {
    @ObservedObject var store: UsageStore
    /// 菜单栏面板那一档：更矮、无边框（面板标题行只有 30pt 高，且底色就是面板底色）
    var compact = false

    /// 「自定义…」选完之后按钮**原地**变成输入框，不弹窗：面板是 `MenuBarExtra` 那种
    /// 一点外面就收起来的窗口，模态框在里面既别扭又要抢激活。
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 6 : 9, style: .continuous)
    }

    var body: some View {
        if editing { field } else { button }
    }

    // MARK: 按钮

    private var button: some View {
        Button { popUp() } label: {
            // 不带图标：这一行是**贴着最小窗口宽度**过的账（见 `FilterBar.viewOptions`），
            // 一个 12pt 的 timer 加它那 6pt 间距要 24pt，而「每 30 分钟 ⌄」自己已经把话
            // 说全了 —— 省下这 24pt，日期胶囊才不至于被挤到换行（`main-*-narrow` 那几张出图
            // 盯着这件事）。字面比图标也更好认：档位是要读出来的，不是认出来的。
            HStack(spacing: 4) {
                Text(RefreshInterval.label(store.refreshMinutes))
                    .font(.system(size: compact ? 11 : 12))
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 7.5 : 9, weight: .semibold))
                    .foregroundStyle(Theme.gray500)
            }
            .foregroundStyle(Theme.gray600)
            .padding(.horizontal, compact ? 6 : 10)
            .frame(height: compact ? 20 : 34)
            // 面板里不铺底也不描边：它的底色就是面板底色，再套一层卡片边会把标题行切碎
            .background(hovering ? Theme.hover : (compact ? Color.clear : Theme.cardBackground), in: shape)
            .overlay { if !compact { shape.stroke(Theme.cardBorder) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("定时刷新：\(RefreshInterval.label(store.refreshMinutes))。点开可改档位，或填一个自定义的分钟数")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // MARK: 自定义分钟

    /// 输入框。回车提交、Esc 放弃、点到别处也提交（三处都走 `commit` / `cancel`，
    /// 它们靠 `editing` 这个闸门保证不会提交两次）。
    private var field: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 11 : 12))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: compact ? 26 : 32)
                .focused($focused)
                .onSubmit { commit() }
                // Esc = 放弃。**必须先落 `editing`**：撤下输入框会让焦点旁落，
                // 那一次 blur 会被下面那条 onChange 当成「点到别处了」而提交。
                .onExitCommand { cancel() }
                .onChange(of: focused) { _, now in if !now { commit() } }
                // 只留数字、最多四位（上限 1440）。用 onChange 过滤而不是校验后报错：
                // 这个框里除了分钟数没有别的合法输入，让非法字符根本打不进去最省事。
                .onChange(of: draft) { _, now in
                    let digits = String(now.filter(\.isNumber).prefix(4))
                    if digits != now { draft = digits }
                }
                .onAppear {
                    // 延一拍再抢焦点：这一刻输入框刚被插进视图树，还没有可聚焦的 NSView
                    DispatchQueue.main.async { focused = true }
                }
            Text("分钟").font(.system(size: compact ? 10 : 11)).foregroundStyle(Theme.gray500)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: compact ? 20 : 34)
        .background(Theme.fieldBackground, in: shape)
        .overlay { shape.stroke(Theme.fieldBorder) }
    }

    // MARK: 动作

    private func popUp() {
        let menu = NSMenu()
        let target = MenuActionTarget()
        let current = store.refreshMinutes
        // 「关闭」在列表开头：它和四个预设是同一层选择，不是藏在末尾的开关
        for minutes in [RefreshInterval.off] + RefreshInterval.presets {
            menu.addItem(target.add(RefreshInterval.label(minutes),
                                    checked: minutes == current) { store.setRefreshInterval(minutes) })
        }
        menu.addItem(.separator())
        let isCustom = RefreshInterval.isCustom(current)
        menu.addItem(target.add(isCustom ? "自定义…（\(current) 分钟）" : "自定义…",
                                checked: isCustom) { beginCustomEdit() })
        // `in: nil` 表示用屏幕坐标，而当前鼠标位置就是用户刚点的那个按钮
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
    }

    private func beginCustomEdit() {
        draft = String(store.customRefreshMinutes)
        editing = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        // 空着、或者填了 0 就当作没改（`setRefreshInterval` 那边也会规整一次）：
        // 手里没数的时候，保持原样比猜一个值好
        guard let minutes = Int(draft), minutes > 0 else { return }
        store.setRefreshInterval(minutes, custom: minutes)
    }

    private func cancel() {
        editing = false
    }
}
