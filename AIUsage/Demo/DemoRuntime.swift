import Foundation

/// `--demo`：出图与手工核对的演示环境。
///
/// 存在的理由：`--render` 原先读的是本机真实日志，截出来的每一张都带着本机设备名、
/// 真实消费额和 `/Users/<名字>/...` 路径 —— 而这些图是要提交进开源仓库的。
///
/// **为什么闸门下在这里，而不是让出图工装自己注意**：`--render` 会把主窗口与设置窗口
/// 真的建起来，窗口上的 `.task` 照跑（联网、扫盘、写 iCloud），`WindowFrameKeeper`
/// 照常写盘。只要漏掉其中一个落盘点，出图就会**静默**改到用户真实的配置 ——
/// 而截图本身看不出任何异常。所以「现在是不是演示模式」由这个开关统一回答，
/// 会碰盘 / 会联网的那几个类型各自在入口处短路，不指望调用方自觉。
///
/// 三条约定：
/// 1. 配置域换成一次性 suite，进程退出时整个删掉 —— 我们自己写的每一个字节都不落到
///    `UserDefaults.standard` 上；AppKit 自己写的那几个键拦不住，退出时按原值还回去
///    （见 `restoreAppKitKeys`，这是本文件里唯一一处碰真实域的地方，且只碰窗口尺寸那类键）；
/// 2. `PricingService` / `UsageStore` / `DeviceSync` 的联网与磁盘入口在这里短路；
/// 3. 会渲染成「刚刚 / x 分钟前」的时刻用固定偏移，同一份代码每次出图的说法一致。
enum DemoRuntime {
    /// 判据放在命令行上，不另开环境变量：出图、自测、手工核对走的是同一条 `--args`。
    static let isActive = CommandLine.arguments.contains("--demo")

    /// 演示模式专属的配置域。名字固定（不是每次随机）是刻意的：
    /// `CFPreferences` 在进程退出时会把它记过的域**再写一遍**，我们那个 `atexit` 清理
    /// 跑在它前面，删得掉内容、删不掉文件（实测残留一个 42 字节的空 plist）。
    /// 名字固定，残留就只会有这一个 —— 随机名会在 `~/Library/Preferences` 里一次攒一个。
    /// 内容由 `install()` 在开头清一次保证干净，不指望退出时那一手。
    private static let suiteName: String? = isActive ? "aiusage.demo" : nil

    /// **所有**读写用户配置的地方都从这里取。非演示模式下它就是 `.standard`，
    /// 行为与从前一字不差 —— 这是整套改动「运行时行为不变」的落点。
    static let defaults: UserDefaults = {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        // 设备身份钉死。不钉的话每次出图现生成一个 UUID，同一份数据两次截出来在设备 id 上就漂了；
        // 名字更要钉 —— 它的兜底值是系统电脑名，那就是作者本人的机器名。
        DeviceIdentity.write(id: demoDeviceId, name: demoLocalDeviceName, to: suite)
        return suite
    }()

    static let demoDeviceId = "demo-macbook"
    static let demoLocalDeviceName = "演示用 MacBook"
    static let demoRemoteDeviceName = "演示用 Mac Studio"

    /// 演示用的共享目录。设置页会把它原样画出来，所以得长得像 iCloud 而一个字都不真。
    static let sharedFolder = URL(fileURLWithPath: "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/AIUsage/devices",
                                  isDirectory: true)

    /// 设置页「留存」那一节是**直接渲染这个静态属性**的（不是渲染报告里的字段），
    /// 所以光注入一份演示报告遮不住它，这里也得换掉。
    static let claudeSettingsPath = "/Users/you/.claude/settings.json"

    // MARK: 时刻

    /// 出图时那几个「现在」。相对当前时刻算，图看着总是活的；
    /// 偏移量固定，所以 `RelativeDateTimeFormatter` 每次的说法一样。
    static var lastScan: Date { Date().addingTimeInterval(-95) }
    static var scanDuration: TimeInterval { 2.6 }
    static var localDeviceUpdatedAt: Date { Date().addingTimeInterval(-60) }
    static var priceUpdatedAt: Date { Date().addingTimeInterval(-5_400) }

    /// 共享目录里那几份档案。**完全在内存里** —— 演示模式绝不读写真实的 iCloud 目录。
    static let archiveDeviceFiles: [DeviceFile] = DemoData.deviceFiles()

    // MARK: 生命周期

    /// 入口清一次 + 注册退出时清一次。
    ///
    /// 清在**开头**才是保证干净的那一手：上一次运行（甚至上一次被 Ctrl-C 掉的运行）
    /// 可能在这块域里留下东西，而每次演示的起点必须一样。
    /// 退出时那次是尽力而为 —— 出口有六七个（--dump / --menu / --retention / --render / --bench），
    /// 用 `atexit` 是为了不必在每个 `exit(0)` 前各写一句、漏掉一个就在用户机器上留一份配置。
    static func install() {
        guard let suiteName else { return }
        // 快照必须在**任何窗口建出来之前**取 —— 这一刻还是 `App.init()` 的开头。
        // 访问一下这个静态量，让它的惰性初始化发生在这里。
        _ = appKitKeys
        // 用一个裸句柄清，**不碰下面那个 `defaults` 静态量**：碰了它，它的初始化就把设备身份
        // 写进去了，紧接着再清一次等于白清。清完之后的第一次访问才会钉身份。
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        atexit {
            DemoRuntime.restoreAppKitKeys()
            DemoRuntime.teardown()
        }
    }

    /// 把这块演示域从磁盘上删干净。删得掉内容、删不掉文件（见 `suiteName`），
    /// 所以这个函数的职责是「一个字节的用户数据都不留」，不是「一个文件都不留」。
    static func teardown() {
        guard let suiteName else { return }
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: 真实配置域里那几个**不由我们写**的键

    /// 出图会真的把主窗口建出来（SwiftUI 的 scene 不能条件声明：`SceneBuilder` 的 `if`
    /// 只认 `#available` 子句，写别的条件会以「failed to produce diagnostic」这种看不懂的
    /// 编译错误收场 —— 试过了）。窗口一落到演示尺寸，**AppKit 自己**就按 SwiftUI 的自存名
    /// （`NSWindow Frame main-AppWindow-1`）把位置尺寸写进 `UserDefaults.standard`。
    /// 这一段在 AppKit 内部，`defaults` 换成演示 suite 拦不住它：实测出图前给那个键打 canary，
    /// 出图后被改写成演示尺寸；反倒是我们自己写的 `NSWindow Frame AIUsage.MainWindow`
    /// 原封不动（它走的是演示 suite）。
    ///
    /// 所以这里的承诺换一个说法：**不碰真实域做不到，改完还回去做得到。**
    /// 只管状态栏位置与窗口尺寸这两类键 —— 用户真正在意的设置（数据源、价格表、菜单栏配置）
    /// 一个都不碰，万一他在这几十秒里改了真实 App 的设置，也不会被这一手覆盖掉。
    private static let guardedPrefixes = ["NSWindow Frame ", "NSStatusItem "]

    /// 演示开始前这些键的原值。惰性初始化，`install()` 会主动碰一下它把时机钉在开窗口之前。
    private static let appKitKeys: [String: Any] = {
        guard isActive else { return [:] }
        return (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:])
            .filter { key, _ in guardedPrefixes.contains { key.hasPrefix($0) } }
    }()

    /// 把 AppKit 写过的那几个键还原成演示开始前的样子：改过的写回原值，
    /// 演示期间新长出来的（演示尺寸那几条）删掉。
    ///
    /// 走 `UserDefaults.standard` 而不是 `defaults` —— 要还原的正是**这个域**。
    /// 写在 `atexit` 里就够了：`CFPreferences` 退出时那次落盘写的是内存里的缓存，
    /// 而这一步刚好改的就是那份缓存（实测：演示域的清理也是靠这个顺序才生效的）。
    static func restoreAppKitKeys() {
        guard isActive, let appID = Bundle.main.bundleIdentifier else { return }
        let defaults = UserDefaults.standard
        let current = (defaults.persistentDomain(forName: appID) ?? [:]).keys
        for key in current where guardedPrefixes.contains(where: { key.hasPrefix($0) }) {
            if let original = appKitKeys[key] {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        // 写下去只是进了 cfprefsd 的缓存，进程这时候马上就要没了。
        // **必须等这一次同步落盘**：实测不加这一句，紧随其后跑的 `defaults export` 有概率读到
        // 还没还回去的中间态 —— 而 `scripts/shoot.sh` 后面紧跟的那次比对正是这么读的，
        // 于是「配置域零改动」这条断言会偶发地报红，红得还不是真事。
        defaults.synchronize()
    }
}
