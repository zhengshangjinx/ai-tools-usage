import Foundation

/// 关窗行为。目前只有一项：关掉主窗口之后是留在菜单栏，还是干脆退出。
///
/// **不并进 `MenuBarConfig`**，两个理由：
/// ① 技术上（决定性）：那个结构是 `Codable`，加一个**非可选**字段会让老 JSON 整份解码失败 ——
///    `MenuBarSettings.init` 里那句 `else { stored = MenuBarConfig() }` 会把用户已经配好的
///    菜单栏文字与面板指标**静默重置**。为一个开关去动那个已经踩过坑的结构不划算。
/// ② 语义上：「关窗行为」是 App 生命周期，不是菜单栏的显示配置。
///
/// 键名照本项目对单值的约定（`sync.enabled.v1` / `device.id.v1` 那一类）用平键，不套 JSON。
@MainActor
final class AppBehaviorSettings: ObservableObject {
    static let keepRunningKey = "general.keepRunningAfterMainWindowClose.v1"

    /// 关掉主窗口后是否继续活着（默认 true，只有状态栏图标）。
    ///
    /// **这里可以用 `@Published`，而 `MenuBarSettings` 不能** —— 那句警告别当成耳旁风：
    /// 那边的死循环是 `MenuBarExtra(isInserted:)` 在**它自己的更新过程里**把状态写回绑定造成的
    /// （`sample` 抓到的 1455 个样本全卡在那条链上，`@Published` 的 setter 不做相等判断，
    /// 写回同一个 `true` 也照发 `objectWillChange`，于是无限循环、主线程占满）。
    /// 这个对象**不绑给任何 scene 修饰符**，只给普通视图读，没有回写方，所以安全。
    /// **前提就是这一条：别把它绑进任何 scene 修饰符。**
    @Published var keepRunningAfterMainWindowClose: Bool {
        didSet { defaults.set(keepRunningAfterMainWindowClose, forKey: Self.keepRunningKey) }
    }

    private let defaults: UserDefaults

    /// `defaults` 可注入是为了 `--selftest`：自测必须能用一次性 suite 验读写，
    /// 直接 `AppBehaviorSettings()` 会拿到 `.standard`，写一下就把用户自己的设置改了。
    /// 默认值取 `DemoRuntime.defaults` 出于同一个理由：`--demo` 下出图会真的建窗口、
    /// 真的走一遍关窗逻辑，写进真配置域同样是在改用户的设置。非演示模式下它就是 `.standard`。
    init(defaults: UserDefaults = DemoRuntime.defaults) {
        self.defaults = defaults
        // 用 `object(forKey:) as? Bool`，**不是** `bool(forKey:)` ——
        // 后者分不清「从没设过」和「明确设成 false」，而这一项的默认值恰好是 true。
        // 写成 `?? true` 才是对的：没设过 = 默认开启。
        keepRunningAfterMainWindowClose = defaults.object(forKey: Self.keepRunningKey) as? Bool ?? true
    }
}
