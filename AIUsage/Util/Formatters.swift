import Foundation

enum Formatters {
    /// 本机设备名称（系统偏好设置里的电脑名），取不到时回退为“本机”
    static let deviceName: String = {
        if let n = Host.current().localizedName, !n.isEmpty { return n }
        let n = ProcessInfo.processInfo.hostName
        return n.isEmpty ? "本机" : n.replacingOccurrences(of: ".local", with: "")
    }()

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...: return trim(v / 1_000_000) + "M"
        case 1_000...: return trim(v / 1_000) + "K"
        default: return "\(n)"
        }
    }

    /// 计数值（请求数）。这个数是要跟中转站账单逐位对账的，所以**不做量级缩写** ——
    /// 「2.2K」对不上「2,168」，只加千位分隔符让它一眼读得出位数。
    /// 用固定 locale：分组符不跟着系统语言变，截图和报告里才是一致的。
    static func count(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 计数用的格式化器。**locale 必须是 `en_US`，不能照抄上面两个日期格式化器的 `en_US_POSIX`** ——
    /// POSIX 那一档在 ICU 里是给机器读的，分组符默认是关的：`36,428` 会输出成 `36428`
    /// （实测第一版就是这么写错的）。而这一列的全部意义就是一眼读出位数。
    /// 分隔符再显式钉一遍，免得跟着系统区域跑掉。
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 0
        return f
    }()

    /// 中文数量级读法（亿 / 万）。B、M 这些英文量级对中文读者不直观，
    /// 在主数值下面补一行等值的中文量级。不足 1 万时返回 nil —— 数字本身已经够短。
    static func tokensCN(_ n: Int) -> String? {
        let v = Double(n)
        if v >= 100_000_000 { return trimCN(v / 100_000_000) + " 亿" }
        if v >= 10_000 { return trimCN(v / 10_000) + " 万" }
        return nil
    }

    /// 中文量级的小数位：数值越大留得越少，"128.0 亿" 而不是 "128.03 亿"
    private static func trimCN(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    private static func trim(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.currencySymbol = "$"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    static func cost(_ v: Double) -> String {
        currency.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    static func percent(_ v: Double) -> String {
        String(format: "%.1f%%", v * 100)
    }

    /// 界面通篇是中文，日期也必须说中文。不能靠 `Locale.current` ——
    /// 这个 bundle 一个本地化都没声明，`Locale.current` 会落到开发语言（en）上，
    /// 于是系统语言明明是中文、界面上却出现 "Jul 5" 和 "1 min. ago" 这种半截英文。
    /// 固定成 zh_CN，跟写死的中文界面保持一致。
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        // 用模板而不是写死 "MMM d"：后者在中文下出来是「7月 5」——月份和日子中间夹一个空格，
        // 中文里不这么写。交给模板排，中文得到的是「7月5日」。
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static let fullDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 「10月7日 00:22」：设置页里那几个时刻（价格表更新于 / 上次扫描 / 上次检查更新）。
    ///
    /// 那几处原来写的是 `date.formatted(date: .abbreviated, time: .shortened)`，
    /// 它走 `Locale.current` —— 而本 bundle 一个本地化都没声明、`Locale.current` 会落到 en，
    /// 于是通篇中文的界面里印出的是 "Oct 7, 2026 at 0:22"。同一个坑 `dayFormatter` 上面已经记过一笔，
    /// 这里是把设置页那三处也收进来。
    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return f
    }()

    static func dayLabel(_ d: Date) -> String { fullDayFormatter.string(from: d) }
    static func shortDay(_ d: Date) -> String { dayFormatter.string(from: d) }
    /// 时刻（含分钟）。见 `stampFormatter`。
    static func stamp(_ d: Date) -> String { stampFormatter.string(from: d) }
}
