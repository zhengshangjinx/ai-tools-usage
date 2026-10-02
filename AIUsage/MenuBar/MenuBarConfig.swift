import Foundation

/// 菜单栏可以显示的一项指标 = 三个指标 × 「今天 / 本月」。
///
/// 为什么只有这两档而不是「近 7 天」之类：菜单栏回答的是「现在花了多少」，
/// 再多的窗口就变成把主界面塞进 300pt 了 —— 那是点开主窗口该干的事。
enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case todayCost, todayTokens, todayRequests
    case monthCost, monthTokens, monthRequests

    var id: String { rawValue }

    /// 面板里那一行的标题
    var label: String {
        switch self {
        case .todayCost: return "今日费用"
        case .todayTokens: return "今日 Tokens"
        case .todayRequests: return "今日请求数"
        case .monthCost: return "本月费用"
        case .monthTokens: return "本月 Tokens"
        case .monthRequests: return "本月请求数"
        }
    }

    /// 菜单栏文字用的更短的名字 —— 菜单栏是别人的地盘，括号与重复的前缀能省则省。
    ///
    /// 金额这两项**不能再写 `$`**：取值走的是 `Formatters.cost`，它自己带币种符号，
    /// 两边都写就拼成「今日 $ $16.86」（2026-09-25 用户在菜单栏上抓到的就是这个）。
    /// 币种由数值那一侧表达，标签这侧只留时间范围 —— 面板里那两行的标题是 `label`
    /// （「今日费用」），本来就没有符号，所以这件事只在菜单栏这一处发生。
    var shortLabel: String {
        switch self {
        case .todayCost: return "今日"
        case .todayTokens: return "今日 tokens"
        case .todayRequests: return "今日请求"
        case .monthCost: return "本月"
        case .monthTokens: return "本月 tokens"
        case .monthRequests: return "本月请求"
        }
    }

    var isMonth: Bool {
        switch self {
        case .monthCost, .monthTokens, .monthRequests: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .todayCost, .monthCost: return "dollarsign"
        case .todayTokens, .monthTokens: return "sum"
        case .todayRequests, .monthRequests: return "arrow.left.arrow.right"
        }
    }

    /// 取值并格式化。金额与请求数在**只有下界**时前面加 `≥` ——
    /// 菜单栏是常驻的，一个看着精确、其实偏小的数比没有数更糟。
    /// 请求数一次都没有时写「—」：那和「0 次」是两回事（会话数计不出来的环境就是这个形状）。
    func text(_ s: MenuBarSummary) -> String {
        let t = isMonth ? s.month : s.today
        switch self {
        case .todayCost, .monthCost:
            return (t.unpriced ? "≥" : "") + Formatters.cost(t.cost)
        case .todayTokens, .monthTokens:
            return Formatters.tokens(t.tokens)
        case .todayRequests, .monthRequests:
            guard t.requests > 0 else { return "—" }
            return (t.requestsPartial ? "≥" : "") + Formatters.count(t.requests)
        }
    }

    /// 这一项在面板里作第二行的小字说明
    func sub(_ s: MenuBarSummary) -> String {
        let t = isMonth ? s.month : s.today
        switch self {
        case .todayCost, .monthCost:
            return t.unpriced ? "含未计价模型，金额是下界" : "\(t.sessions) 个会话"
        case .todayTokens, .monthTokens:
            // 中文量级在菜单面板这种宽度下比 B/M 更好读，读不出来的（不足一万）就不写
            return Formatters.tokensCN(t.tokens).map { "约 \($0)" } ?? "\(t.sessions) 个会话"
        case .todayRequests, .monthRequests:
            if t.requests == 0 { return "本地量不到调用次数" }
            return t.requestsPartial ? "有设备档案没记请求数，真实值更高" : "\(t.sessions) 个会话"
        }
    }
}

/// 菜单栏配置。存 `UserDefaults` 的 `menubar.config.v1`（JSON Data），
/// 照 `sources.config.v1` / `pricing.overrides.v1` 那套带版本号的键来，不另起一套。
struct MenuBarConfig: Codable, Equatable {
    /// 关掉只是不显示菜单栏图标。Dock 图标由 `ActivationPolicyController` 按
    /// 「屏幕上还有没有真窗口」在运行期决定，**仍然不加 `LSUIElement`**（理由见那个类型开头）。
    ///
    /// 它与 `AppBehaviorSettings.keepRunningAfterMainWindowClose` **耦合**，改这个字段时要一起想：
    /// 菜单栏图标是关掉主窗口之后唯一的入口，所以图标关掉时那条「退成纯状态栏」的路必须让开，
    /// 否则 App 会落到「没有 Dock 图标、没有菜单栏、没有窗口」的死路上。
    var showInMenuBar = true
    /// 菜单栏图标旁边那段文字显示哪几项。最多两项：菜单栏长度是所有 app 共享的，
    /// 排到第三项就会把别人的图标挤走。
    var label: [MenuBarMetric] = [.todayCost]
    /// 点开面板里显示哪几项（顺序即显示顺序）
    var panel: [MenuBarMetric] = [.todayCost, .todayTokens, .todayRequests]

    static let maxLabelItems = 2

    /// 菜单栏上那段文字。空数组 = 只显示图标（菜单栏只留一个图标是完全正当的用法）
    func labelText(_ s: MenuBarSummary) -> String {
        label.prefix(Self.maxLabelItems)
            .map { "\($0.shortLabel) \($0.text(s))" }
            .joined(separator: " · ")
    }
}

/// 菜单栏配置的持有者。`MenuBarExtra` 是独立 scene，拿不到 `WindowGroup` 的环境，
/// 所以它由 `AIUsageApp` 持有、显式传进面板与标签。
@MainActor
final class MenuBarSettings: ObservableObject {
    static let key = "menubar.config.v1"

    /// **这里不能用 `@Published`，会死循环。**
    /// `MenuBarExtra(isInserted:)` 会在它自己的更新过程里把当前插入状态**写回**这个绑定，
    /// 实测调用链：
    /// `AppMenuBarExtrasController.updateMenuBarExtras` → `MenuBarExtraController.updateConfiguration`
    /// → KVO → `Binding.wrappedValue.setter` → 这里 → `Published` → `objectWillChange` →
    /// SwiftUI 重新求值 scene → 回到第一步。`sample` 抓到的 1455 个样本**全部**卡在这条链上。
    ///
    /// 根因是 `@Published` 的 setter **不做相等判断**：写回同一个 `true` 也照发 `objectWillChange`。
    /// 代价不只是界面卡：主线程被这个循环占满，启动后要在主线程排队的那些挂点
    /// （`--dump` / `--menu` 的 Task）永远轮不上，整个 app 一起假死。
    /// 所以自己实现 setter，**值没变就什么都不做** —— 循环在这一步断掉。
    ///
    /// `objectWillChange` 手动发在赋值**之前**，跟 `@Published` 的语义保持一致。
    private var stored: MenuBarConfig

    var config: MenuBarConfig {
        get { stored }
        set {
            guard newValue != stored else { return }
            objectWillChange.send()
            stored = newValue
            save()
        }
    }

    init() {
        // 直接写 stored：init 里走 config 的 setter 会读到还没初始化的 stored
        if let data = DemoRuntime.defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(MenuBarConfig.self, from: data) {
            stored = decoded
        } else {
            stored = MenuBarConfig()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        DemoRuntime.defaults.set(data, forKey: Self.key)
    }
}
