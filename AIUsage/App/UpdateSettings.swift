import Foundation

/// 自动更新的配置项。逐行照 `AppBehaviorSettings` —— 那套写法（扁平版本化键、
/// `object(forKey:) as? Bool`、可注入 `defaults`）在那边已经把坑踩平了，没必要另发明一套。
@MainActor
final class UpdateSettings: ObservableObject {
    static let autoCheckKey = "update.autoCheck.v1"
    static let lastCheckKey = "update.lastCheck.v1"
    static let skippedVersionKey = "update.skippedVersion.v1"

    /// 启动时自动检查有没有新版本。默认开。
    ///
    /// **这里能用 `@Published`，前提与 `AppBehaviorSettings` 一样**：这个对象只给普通视图读，
    /// 不绑给任何 scene 修饰符。`MenuBarSettings` 那条死循环警告（`@Published` 的 setter
    /// 不做相等判断，写回同一个值也照发 `objectWillChange`）别当成耳旁风 —— 前提一旦破了就复现。
    @Published var autoCheckEnabled: Bool {
        didSet { defaults.set(autoCheckEnabled, forKey: Self.autoCheckKey) }
    }

    /// 用户点过「跳过这个版本」的版本号。存字符串而不是 `SemanticVersion`：
    /// 配置项要能被原样读回来，解析不出来时也只是「不跳过」，而不是丢配置。
    @Published var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Self.skippedVersionKey) }
    }

    private let defaults: UserDefaults

    /// 默认取 `DemoRuntime.defaults`：`--demo` 下出图会真的把设置窗口建起来、真的读这些开关，
    /// 写进真配置域一样是在改用户的设置。非演示模式下它就是 `.standard`。
    init(defaults: UserDefaults = DemoRuntime.defaults) {
        self.defaults = defaults
        // 用 `object(forKey:) as? Bool`，**不是** `bool(forKey:)` ——
        // 后者分不清「从没设过」和「明确关掉」，而这一项默认是开着的。
        autoCheckEnabled = defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true
        skippedVersion = defaults.string(forKey: Self.skippedVersionKey)
    }

    /// 上次检查的时刻。**不进 `@Published`**：它只喂新鲜度闸门，界面上那句「上次检查」
    /// 由 `UpdateService` 的状态自己带着；每写一次就发一次 `objectWillChange` 是白花的。
    var lastCheck: Date? {
        get { (defaults.object(forKey: Self.lastCheckKey) as? Double).map(Date.init(timeIntervalSince1970:)) }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Self.lastCheckKey)
            } else {
                defaults.removeObject(forKey: Self.lastCheckKey)
            }
        }
    }
}
