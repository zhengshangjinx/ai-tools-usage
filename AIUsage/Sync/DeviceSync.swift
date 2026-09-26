import Foundation

/// 自然日 key。每台设备按自己的本地日历日聚合，跨设备按同一字符串相加即正确。
enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }

    static func date(_ key: String) -> Date? { formatter.date(from: key) }
}

/// 一台设备在一个自然日、一个环境、一个模型上的 token 聚合。
///
/// 刻意只同步 4 个 token 桶而**不同步费用**：`ModelPrice.cost(for:)` 与 `cacheSavings(for:)`
/// 对这 4 个桶都是线性的，所以在展示端用本机价格表重新计价，结果与逐条记录计算完全等价
/// （见 Pricing/PricingService.swift）。这样远端历史也能随价格表更新自动重算。
struct AggregateRow: Codable, Hashable {
    var day: String
    var provider: ProviderKind
    var model: String
    var inputUncached: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    /// 这一桶里带用量的记录条数 = 模型响应次数（一条记录 ≈ 一次响应，见 `UsageStore.aggregate`）
    var requests: Int = 0

    var total: Int { inputUncached + cacheRead + cacheWrite + output }

    /// 这条聚合的请求数是不是**只有下界**：旧版本 App 写的档案没有 `requests` 字段，
    /// token 桶照常参与汇总，但那次响应数不出来（见 `init(from:)`）。
    /// 展示端要靠它把数字前面标上 ≥，不能把缺的数当成 0 —— 那是在对账的列里说谎。
    var requestsUnknown: Bool { total > 0 && requests == 0 }
}

extension AggregateRow {
    /// 手写解码只为一件事：`requests` 是后加的字段，**缺了必须当 0 而不是解析失败**。
    ///
    /// 每台设备只写自己那份档案，所以本机读到的往往是旧版本 App 写的文件。
    /// Swift 合成的解码器遇到缺字段直接抛错，而 `DeviceSync.readAll` 里那是整份档案的成败 ——
    /// 一台还没升级的设备，会让它的全部历史从汇总里消失。缺字段当 0 只是少一列请求数，
    /// 另外 4 个 token 桶照常参与汇总，历史金额不受影响。
    ///
    /// 也**不动 `currentSchema`**：那个版本号是单向闸门（本机读到更高版本会把整份档案跳过并提示升级），
    /// 为一次向后兼容的加字段去抬它，等于逼所有旧设备升级。
    /// 反过来旧版本 App 读新文件是安全的 —— 合成解码器会忽略不认识的键。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        provider = try c.decode(ProviderKind.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        inputUncached = try c.decode(Int.self, forKey: .inputUncached)
        cacheRead = try c.decode(Int.self, forKey: .cacheRead)
        cacheWrite = try c.decode(Int.self, forKey: .cacheWrite)
        output = try c.decode(Int.self, forKey: .output)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
    }
}

/// 一台设备在一个自然日、一个环境上去重后的会话数。
/// 会话 id 不外传（体量与隐私），跨设备求和即可 —— 设备之间会话天然不相交。
struct SessionCountRow: Codable, Hashable {
    var day: String
    var provider: ProviderKind
    var count: Int
}

/// 落在 iCloud 共享目录里的一份设备档案。文件名 `device-<deviceId>.json`，每台设备只写自己那份。
struct DeviceFile: Codable {
    static let currentSchema = 1

    var schema: Int = DeviceFile.currentSchema
    var deviceId: String
    var deviceName: String
    var appVersion: String
    var updatedAt: Date
    var rows: [AggregateRow]
    var sessions: [SessionCountRow]
}

/// UI 上的一台设备
struct DeviceInfo: Identifiable, Hashable {
    let id: String
    var name: String
    var isLocal: Bool
    var updatedAt: Date?
    var rowCount: Int
    var sessionTotal: Int
}

/// 本机设备身份。id 是首次启动生成的稳定 UUID（设备改名不影响），name 仅用于展示。
enum DeviceIdentity {
    private static let idKey = "device.id.v1"
    private static let nameKey = "device.name.v1"

    static var id: String {
        if let v = UserDefaults.standard.string(forKey: idKey), !v.isEmpty { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: idKey)
        return v
    }

    /// 展示名：用户覆盖优先，否则系统电脑名
    static var name: String {
        get {
            if let v = UserDefaults.standard.string(forKey: nameKey), !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return v
            }
            return Formatters.deviceName
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { UserDefaults.standard.removeObject(forKey: nameKey) }
            else { UserDefaults.standard.set(t, forKey: nameKey) }
        }
    }
}

/// iCloud 共享目录的读写层。
///
/// 为什么不用 CloudKit / iCloud 容器：那需要付费开发者账号、真实 Team ID 与描述文件，
/// 会破坏本工程现有的 ad-hoc 签名（project.yml 的 CODE_SIGN_IDENTITY: "-"）。App 未开沙盒，
/// 因此可以直接读写 iCloud Drive 目录，零额外配置。代价是文件对用户可见，且需要处理
/// iCloud 的「按需下载」占位符（见 materialize）。
final class DeviceSync {
    static let shared = DeviceSync()

    private let folderKey = "sync.folder.v1"

    /// 共享目录，可在设置里改（例如换成本机其他同步盘）
    var folderURL: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
                return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            }
            return Self.defaultFolder
        }
        set { UserDefaults.standard.set(newValue.path, forKey: folderKey) }
    }

    var isUsingDefaultFolder: Bool {
        UserDefaults.standard.string(forKey: folderKey)?.isEmpty ?? true
    }

    static var defaultFolder: URL {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return cloud.appendingPathComponent("AIUsage/devices", isDirectory: true)
    }

    /// 默认目录所在盘符是否存在（iCloud Drive 未登录时为 false）
    static var defaultFolderAvailable: Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }

    var folderExists: Bool { FileManager.default.fileExists(atPath: folderURL.path) }

    // MARK: 写

    /// 原子写入本机档案。只碰自己的文件，所以设备之间不会互相覆盖。
    @discardableResult
    func write(_ file: DeviceFile) -> String? {
        let dir = folderURL
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return "创建同步目录失败：\(error.localizedDescription)"
        }
        let url = dir.appendingPathComponent(Self.fileName(for: file.deviceId))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return "编码设备档案失败" }
        do {
            try coordinatedWrite(data, to: url)
            return nil
        } catch {
            return "写入 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
        }
    }

    // MARK: 读

    /// 读取目录下所有设备档案。返回 (成功解析的档案, 非致命错误提示)。
    func readAll() -> (files: [DeviceFile], warnings: [String]) {
        let dir = folderURL
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return ([], [])
        }
        var files: [DeviceFile] = []
        var warnings: [String] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for entry in entries.sorted() {
            // iCloud 未下载的占位符形如 `.device-xxx.json.icloud`
            if entry.hasPrefix(".") && entry.hasSuffix(".icloud") {
                let real = String(entry.dropFirst().dropLast(".icloud".count))
                guard real.hasPrefix(Self.prefix) else { continue }
                materialize(dir.appendingPathComponent(entry), warnings: &warnings)
                continue
            }
            guard entry.hasPrefix(Self.prefix), entry.hasSuffix(".json") else { continue }
            let url = dir.appendingPathComponent(entry)
            guard let data = readData(url, warnings: &warnings) else { continue }
            if let file = try? decoder.decode(DeviceFile.self, from: data) {
                guard file.schema <= DeviceFile.currentSchema else {
                    warnings.append("\(entry) 版本较新（schema \(file.schema)），请升级本机 App")
                    continue
                }
                files.append(file)
            } else {
                warnings.append("\(entry) 解析失败，已跳过")
            }
        }
        return (files, warnings)
    }

    func remove(deviceId: String) {
        let url = folderURL.appendingPathComponent(Self.fileName(for: deviceId))
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 底层 IO

    static let prefix = "device-"
    static func fileName(for deviceId: String) -> String { "\(prefix)\(deviceId).json" }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    private func readData(_ url: URL, warnings: inout [String]) -> Data? {
        var coordError: NSError?
        var result: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { target in
            result = try? Data(contentsOf: target)
        }
        if let result { return result }
        if let coordError {
            warnings.append("\(url.lastPathComponent) 读取失败：\(coordError.localizedDescription)")
        }
        return nil
    }

    /// 触发 iCloud 按需下载。占位符必须先用 brctl 拉取，普通 POSIX 读拿不到内容。
    private func materialize(_ placeholder: URL, warnings: inout [String]) {
        let real = placeholder.deletingLastPathComponent()
            .appendingPathComponent(String(placeholder.lastPathComponent.dropFirst().dropLast(".icloud".count)))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        p.arguments = ["download", real.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            warnings.append("\(real.lastPathComponent) 尚未下载到本机，无法读取")
            return
        }
        if !FileManager.default.fileExists(atPath: real.path) {
            warnings.append("\(real.lastPathComponent) 尚未下载到本机，无法读取")
        }
    }
}
