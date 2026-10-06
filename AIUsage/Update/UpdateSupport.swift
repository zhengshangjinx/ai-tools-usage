import Foundation

// MARK: - 版本号

/// 语义化版本。更新器的全部判断都压在这一个类型上，所以它是纯的、可自测的。
///
/// **为什么不用字符串比较**：`"0.1.0" < "0.1.10"` 在字典序下是 **false**（逐字符比到第三位，
/// `'0' < '1'` 就定了），而版本上 0.1.10 明明更新。这是更新器最经典的一个 bug，
/// 而且它只在跨到两位数的版本上才发作 —— 从 0.1.9 升到 0.1.10 的那一天才会被发现。
/// 自测里那条 `0.1.0 < 0.1.10` 就是钉这个的。
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 空数组 = 正式版。按 semver §11，带 prerelease 的**低于**同核心版本的正式版。
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// 收 `v0.1.0` / `0.1.0` / `1.2.3-beta.1`。解析不出来返回 nil —— 调用方一律把 nil 当成
    /// 「不认识，别动」，而不是「当成 0.0.0」：后者会让一个畸形的 tag 变成「有更新」。
    static func parse(_ raw: String) -> SemanticVersion? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // GitHub 的 tag 惯例带一个 v 前缀，去掉
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // build metadata（`+` 之后）不参与比较，直接丢掉
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }

        var core = s
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            core = String(s[s.startIndex..<dash])
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            // `1.0.0-` 这种尾巴是空的，判为畸形
            if pre.isEmpty { return nil }
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // 必须是三段。`1.2` 不猜成 `1.2.0` —— 猜了就等于替发布者做了决定
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard let n = strictInt(p) else { return nil }
            nums.append(n)
        }
        return SemanticVersion(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    /// 严格非负十进制整数：拒绝空串、前导零、非 ASCII 数字、正负号。
    /// 用 `isASCII` 那一半不能省：`Character.isNumber` 对全角数字和阿拉伯-印度数字也是 true，
    /// 而 `Int("١")` 是 nil —— 两处判断不一致会让解析结果取决于哪一边先短路。
    /// `fileprivate` 而非 `private`：`UpdatePolicy.coreVersion` 也要用同一套判定。
    fileprivate static func strictInt(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if s.count > 1 && s.hasPrefix("0") { return nil }
        return Int(s)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 核心版本相同：没有 prerelease 的那一个更大（1.0.0 > 1.0.0-rc1）
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty }
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            switch (strictInt(l), strictInt(r)) {
            case let (a?, b?): return a < b          // 两段都是数字：数值比
            case (_?, nil): return true              // 数字段 < 字母段
            case (nil, _?): return false
            case (nil, nil): return l < r            // 都是字母：ASCII 字典序
            }
        }
        // 前面全相等，段数多的更大（1.0.0-alpha < 1.0.0-alpha.1）
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// tag 比当前版本新才算更新。**相等返回 false** —— 否则每次启动都会重新提示一遍同一个版本。
    static func isNewer(tag: String, than current: String) -> Bool {
        guard let t = parse(tag), let c = parse(current) else { return false }
        return t > c
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }
}

// MARK: - 发布数据

/// GitHub API 的原始结构。只解我们真正用到的字段 —— 多解一个字段就多一个解码失败的机会，
/// 而这个接口的其它字段（`author`、`assets_url`、`node_id`…）我们一个都不看。
struct GHRelease: Decodable, Equatable {
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let assets: [GHAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, draft, prerelease, assets
        case htmlURL = "html_url"
    }
}

struct GHAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
    }
}

/// 一个可以直接拿来用的发布：版本已经解析好，资产已经挑好。
struct ReleaseAsset: Equatable {
    let name: String
    let url: URL
    /// GitHub 报的字节数。下载完拿它和 `Content-Length` 对一遍，能在解压之前拦下截断的下载。
    let size: Int
}

struct ReleaseInfo: Equatable {
    let version: SemanticVersion
    let tag: String
    let pageURL: URL
    let notes: String
    /// release 正文里公布的 SHA-256。捞不到就是 nil，**不因此失败** —— 那是加分项，不是前提。
    let checksum: String?
    /// nil = 这个版本没有可下载的包，界面退成「打开下载页」
    let asset: ReleaseAsset?
}

// MARK: - 策略

/// 更新器的全部纯逻辑。**不碰网络、不碰磁盘** —— 自测正是靠这一点才敢把更新检查测起来。
enum UpdatePolicy {
    static let owner = "zhengshangjinx"
    static let repo = "ai-tools-usage"

    /// 更新包的 bundle id 必须正好是这个，否则拒收。取自 `project.yml` 的
    /// `PRODUCT_BUNDLE_IDENTIFIER`；自测里钉着它，改动会当场报红而不是等到装错包那天。
    static let expectedBundleId = "com.local.aiusage"

    static let assetBaseName = "AiToolsUsage"
    /// 发布资产的规范名，与 README、`scripts/export.sh` 三处必须一致。
    static func canonicalAssetName(_ v: SemanticVersion) -> String {
        "\(assetBaseName)-\(v)-macos-universal.zip"
    }

    /// **不能用 `GET /releases/latest`。**
    ///
    /// 那个端点会**排除 prerelease 与 draft**，而本仓库唯一发过的 `v0.1.0` 恰好挂着
    /// `prerelease: true` —— 实测打过去直接 **404**。用 latest 的话，这个功能写完了也永远是
    /// 「已是最新」，而且不报任何错，是最难查的一类故障。
    ///
    /// 所以列出来自己筛。**后来的人很容易把这里「顺手简化」回 latest**，别这么干。
    static var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
    }

    /// 下载地址的 host 白名单。资产 URL 会 **302 到 `release-assets.githubusercontent.com`**
    /// （实测抓到的 `location`，不是常被写进去的 `objects.githubusercontent.com`），
    /// 少了它下载必失败。跳转白名单与最终响应都要过这一关。
    static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "release-assets.githubusercontent.com",
        // 历史上 GitHub 用过这个域名，留着不吃亏
        "objects.githubusercontent.com",
    ]

    static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    /// 从 release 列表里挑出「值得提示给用户的那一个」。挑不出返回 nil（= 已是最新）。
    static func pickRelease(from releases: [GHRelease], current: String, skipped: String? = nil) -> ReleaseInfo? {
        guard let currentVersion = SemanticVersion.parse(current) else { return nil }
        let published = releases.filter { !$0.draft }
        // 优先正式版；一个正式版都没有才退回落 prerelease。
        // 本仓库现在就是这个状态（唯一那个 release 挂着 prerelease），所以这条退路不是摆设。
        let stable = published.filter { !$0.prerelease }
        let pool = stable.isEmpty ? published : stable

        let parsed: [(release: GHRelease, version: SemanticVersion)] = pool.compactMap { r in
            SemanticVersion.parse(r.tagName).map { (r, $0) }
        }
        // 必须**严格大于**当前版本：相等不提示，更低更不提示（绝不降级）
        guard let best = parsed.filter({ $0.version > currentVersion }).max(by: { $0.version < $1.version })
        else { return nil }

        if let skipped, let s = SemanticVersion.parse(skipped), s == best.version { return nil }

        let assets = best.release.assets.map {
            ReleaseAsset(name: $0.name, url: $0.browserDownloadURL, size: $0.size)
        }
        let body = best.release.body ?? ""
        return ReleaseInfo(version: best.version,
                           tag: best.release.tagName,
                           pageURL: best.release.htmlURL,
                           notes: body,
                           checksum: sha256(inReleaseBody: body),
                           asset: selectAsset(assets, version: best.version))
    }

    /// 挑安装包。挑不出来**不猜** —— 返回 nil 让界面退成「打开下载页」，
    /// 比赌一个名字最像的资产去解压要好。
    static func selectAsset(_ assets: [ReleaseAsset], version: SemanticVersion) -> ReleaseAsset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        // 名字里带版本号的，核心版本必须和 tag 对得上。发布页上同时挂着几个版本的包是常事，
        // 挑错了就是「提示你升 0.3.0、装上去还是 0.2.0」。
        let candidates = zips.filter { asset in
            guard let core = coreVersion(in: asset.name) else { return true }  // 名字里没有版本号，先留着
            return core == (version.major, version.minor, version.patch)
        }
        if let exact = candidates.first(where: { $0.name == canonicalAssetName(version) }) { return exact }
        // 规范名没命中、又只剩一个候选，就是它；剩多个则判为有歧义，不猜
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 从文件名里抠出第一个 `x.y.z` 的**数字核心**。
    ///
    /// **只取核心，不带 prerelease 后缀。** 资产名是
    /// `AiToolsUsage-0.2.0-macos-universal.zip` 这个形状，版本号后面还接着平台名 ——
    /// 正则要是一路吃下去，会把 `-macos-universal.zip` 当成 prerelease，
    /// 于是 `0.2.0-macos-universal.zip` 解析出来 ≠ `0.2.0`，**每一个正常资产都会被当成
    /// 「版本不符」排除掉，`selectAsset` 永远返回 nil**。这个坑真踩过，自测里那两条
    /// 「规范名优先 / zip 胜过 dmg」就是钉它的。
    ///
    /// 拿核心比就够了：资产名带的是营销版本号；`-rc1` 那种后缀由规范名的精确匹配兜底。
    static func coreVersion(in name: String) -> (major: Int, minor: Int, patch: Int)? {
        // 前后都挡住相邻数字，免得从一串更长的数字里截出一个假的 x.y.z
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9])([0-9]+)\\.([0-9]+)\\.([0-9]+)(?![0-9])"),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              m.numberOfRanges == 4 else { return nil }
        func part(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return SemanticVersion.strictInt(String(name[r]))
        }
        guard let a = part(1), let b = part(2), let c = part(3) else { return nil }
        return (a, b, c)
    }

    /// 从 release 正文里捞 SHA-256。发布说明是自由文本，格式全凭发布者，
    /// 所以这是一次**尽力而为**的解析：捞不到就返回 nil，调用方跳过校验而不是报错。
    static func sha256(inReleaseBody body: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b") else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let m = re.firstMatch(in: body, range: range), let r = Range(m.range, in: body) else { return nil }
        return String(body[r]).lowercased()
    }
}
