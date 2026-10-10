import Foundation

/// 定时刷新的档位。
///
/// 落盘只存**一个分钟数**（`0` = 关闭），不存「用户点的是第几档」：自定义那一档是任意值，
/// 用枚举就得在 case 里再包一个 Int，读起来比一个数绕。反过来由数推「现在算不算自定义」
/// 是纯函数（`isCustom`），界面上要的分档判断都在这里。
///
/// **读盘 / 落盘也放在这里**（`stored(in:)` / `store(_:in:)`）而不是留在 `UsageStore` 里：
/// store 拿的是真实配置域，自测碰不得，而这一对函数是这项设置唯一会出错的地方
/// （`integer(forKey:)` 那个坑，见 `stored(in:)`）。抽出来就能拿一次性 suite 验读写。
///
/// 两个入口共用这一个值：主窗口工具组与菜单栏面板标题行（见 `RefreshIntervalControl`）。
enum RefreshInterval {
    /// 下拉里的固定档位。「关闭」与「自定义…」是列表的两端，不在这里。
    static let presets = [5, 10, 30, 60]

    /// 0 = 不自定扫描
    static let off = 0

    /// 全新配置的默认值。
    ///
    /// **取 30 而不是列表第一项的 5**：定时刷新是真的在后台扫本地会话文件，
    /// 默认档位等于替用户决定了这台机器每隔多久被扫一遍。30 分钟是「数字不至于太陈」
    /// 与「不白烧 IO」之间的那一档。
    static let defaultMinutes = 30

    /// 「自定义」第一次打开时预填的值。**特意不落在任何预设上** —— 预填 5 或 10 的话，
    /// 用户点开自定义看到的还是预设里那个数，那一档就没有存在感。
    static let customDefault = 15

    /// 自定义的合法区间。上限一天：比这更长的间隔与「关闭」没有区别了，
    /// 而这个上限至少让人一眼看懂自己填的数意味着什么。
    static let validRange = 1...1440

    /// 键名是**有用户数据挂在上面的事实来源**，不许随手改（改它等于清空所有人这个设置）
    static let key = "refresh.minutes.v1"
    /// 「自定义」那一档上次填的数，只为下次打开时预填
    static let customKey = "refresh.customMinutes.v1"

    /// 把落盘的值或用户输入规整成合法值。
    ///
    /// 读盘那一路尤其需要它：plist 是可以手改的，而界面上出现「每 0 分钟」「每 -3 分钟」
    /// 这种读不通的字，比读不出来更糟 —— 用户会以为定时刷新坏了。
    static func sanitize(_ raw: Int) -> Int {
        guard raw > off else { return off }
        return min(raw, validRange.upperBound)
    }

    /// 下拉按钮与菜单项共用的那行文字
    static func label(_ minutes: Int) -> String {
        minutes == off ? "关闭" : "每 \(minutes) 分钟"
    }

    /// 当前值来自「自定义」那一档（既不是关闭，也不落在预设上）
    static func isCustom(_ minutes: Int) -> Bool {
        minutes != off && !presets.contains(minutes)
    }

    // MARK: 落盘

    /// 从配置域读档位，读不到就是默认档。
    ///
    /// 用 `object(forKey:) as? Int` 而**不是** `integer(forKey:)`：后者分不清「从没设过」
    /// 和「明确设成 0」，而 0 在这里恰好是一个有意义的档位（关闭）—— 写成 `integer(forKey:)`
    /// 的话，默认值永远轮不到，新装的用户一上来就是「关闭」。
    /// （`AppBehaviorSettings.keepRunningAfterMainWindowClose` 为同一个坑记过一次账。）
    static func stored(in defaults: UserDefaults) -> Int {
        sanitize(defaults.object(forKey: key) as? Int ?? defaultMinutes)
    }

    /// 「自定义」那一档上次填的数。同样用 `object(forKey:)`，理由同上。
    static func storedCustom(in defaults: UserDefaults) -> Int {
        sanitize(defaults.object(forKey: customKey) as? Int ?? customDefault)
    }

    static func store(_ minutes: Int, in defaults: UserDefaults) {
        defaults.set(sanitize(minutes), forKey: key)
    }

    static func storeCustom(_ minutes: Int, in defaults: UserDefaults) {
        defaults.set(sanitize(minutes), forKey: customKey)
    }
}
