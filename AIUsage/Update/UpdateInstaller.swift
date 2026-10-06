import Foundation
import AppKit
import CryptoKit

/// 下载、校验、替换 bundle。**这是整个更新流程里唯一能伤到用户安装的一步**，
/// 所以它单独成文件、单独 review，而且每一步失败都往「什么都不改」那一侧倒。
///
/// ## 安全姿态（照实说，别把下面这些当成签名）
///
/// **能验的**：HTTPS 全程、下载地址的 host 白名单（含每一次重定向跳）、
/// 长度与 SHA-256（release 正文里那份）、包体结构（bundle id / 可执行名 / 版本号一致）、
/// 版本单调递增（不降级、不等价重装）。
///
/// **验不了的**：本 App 是 **ad-hoc 签名**（`CODE_SIGN_IDENTITY: "-"`），没有信任锚。
/// `codesign --verify` 只能证明**这个包自身是完整的**，不能证明**它是谁做的** ——
/// 任何人都能 ad-hoc 签一个自己的 bundle。真正的信任来源只有「HTTPS + GitHub 账号没被攻破」，
/// 与 README 里那套安装说明是同一个信任故事。
///
/// 所以下面这一串防的是**损坏与意外，不是攻击**。将来要真边界，无依赖的路子是 CryptoKit 的
/// Ed25519（公钥内嵌进 App、`export.sh` 加一步签名）—— 注意本机 `openssl` 是 LibreSSL 3.3.6，
/// **不支持 Ed25519**，签名器得是个用 CryptoKit 的小 Swift 脚本，不能是 openssl 一行命令。
enum UpdateInstaller {

    // MARK: - 错误

    enum Failure: LocalizedError {
        case badStatus(Int)
        case truncated(expected: Int, got: Int)
        case checksumMismatch(expected: String, got: String)
        case unzipFailed(String)
        case noAppInArchive
        case ambiguousArchive(Int)
        case bundleIdMismatch(String)
        case versionMismatch(expected: String, got: String)
        case executableMissing(String)
        case signatureInvalid(String)
        case translocated
        case notWritable(String)
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "下载失败（HTTP \(code)）"
            case .truncated(let expected, let got):
                return "下载不完整（\(got)/\(expected) 字节），已放弃"
            case .checksumMismatch:
                return "下载内容与发布页公布的校验和不一致，已放弃"
            case .unzipFailed(let detail):
                return "解压失败：\(detail)"
            case .noAppInArchive:
                return "更新包里没有 .app，已放弃"
            case .ambiguousArchive(let n):
                return "更新包里有 \(n) 个 .app，判不出该用哪个，已放弃"
            case .bundleIdMismatch(let id):
                return "更新包的 bundle id 是 \(id)，不是本 App，已放弃"
            case .versionMismatch(let expected, let got):
                return "更新包版本是 \(got)，与发布页声称的 \(expected) 不符，已放弃"
            case .executableMissing(let name):
                return "更新包里找不到可执行文件 \(name)，已放弃"
            case .signatureInvalid(let detail):
                return "更新包签名校验没通过（\(detail)），已放弃"
            case .translocated:
                return "请先把 App 移到「应用程序」再更新"
            case .notWritable(let dir):
                return "没有权限写入 \(dir)，请手动替换"
            case .helperFailed(let detail):
                return "替换失败：\(detail)"
            }
        }
    }

    // MARK: - 下载与暂存

    /// 下回来、解开、验完，返回**暂存好的 .app**（还没有动过正在跑的那一份）。
    /// 走到这里为止，用户机器上除了临时目录什么都没被改过。
    static func download(_ asset: ReleaseAsset, release: ReleaseInfo, session: URLSession) async throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // ① 下载。用 `download(from:)` 流式落盘，不用 `data(from:)` 把整个包读进内存。
        let (tempURL, response) = try await session.download(from: asset.url)
        if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
            throw Failure.badStatus(http.statusCode)
        }
        let zipURL = workDir.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: zipURL)
        try FileManager.default.moveItem(at: tempURL, to: zipURL)

        // ② 长度：能在解压之前拦下截断的下载
        let size = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? nil
        if let size, asset.size > 0, size != asset.size {
            throw Failure.truncated(expected: asset.size, got: size)
        }

        // ③ SHA-256。发布正文里公布了就核（已实测 v0.1.0 有），
        //    解析不出来（正文格式自由）就跳过 —— 它是加分项，不是前提。
        if let expected = release.checksum {
            let got = try sha256(of: zipURL)
            if got != expected.lowercased() {
                throw Failure.checksumMismatch(expected: expected, got: got)
            }
        }

        // ④ 解压。**用 ditto 而不是 unzip**：要保留符号链接与扩展属性，
        //    而且 `export.sh` 打包用的就是 `ditto -c -k`，这一对是严格互逆的。
        //    zip 根是 `AI Usage.app/` 加一个 `__MACOSX/` 旁支，ditto 会把后者并回扩展属性。
        let extractDir = workDir.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])
        guard unzip.status == 0 else { throw Failure.unzipFailed(unzip.stderr.isEmpty ? "ditto 退出码 \(unzip.status)" : unzip.stderr) }

        // ⑤ 顶层必须**恰好一个** .app。`__MACOSX` 那类旁支按目录名过滤掉。
        let entries = (try? FileManager.default.contentsOfDirectory(at: extractDir,
                                                                    includingPropertiesForKeys: nil)) ?? []
        let apps = entries.filter { $0.pathExtension == "app" && !$0.lastPathComponent.hasPrefix("_") }
        guard !apps.isEmpty else { throw Failure.noAppInArchive }
        guard apps.count == 1 else { throw Failure.ambiguousArchive(apps.count) }
        let stagedApp = apps[0]

        try validate(stagedApp, expecting: release.version)
        return stagedApp
    }

    /// 包体校验。**这一步才是安全姿态真正落地的地方。**
    static func validate(_ app: URL, expecting version: SemanticVersion) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw Failure.noAppInArchive
        }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == UpdatePolicy.expectedBundleId else { throw Failure.bundleIdMismatch(id) }

        // 版本必须与发布页声称的一致 —— 这条拦的是「tag 写 0.2.0、包里其实是 0.1.0」
        let claimed = info["CFBundleShortVersionString"] as? String ?? ""
        guard let parsed = SemanticVersion.parse(claimed), parsed == version else {
            throw Failure.versionMismatch(expected: version.description, got: claimed)
        }

        let executable = info["CFBundleExecutable"] as? String ?? ""
        let bin = app.appendingPathComponent("Contents/MacOS/\(executable)")
        guard !executable.isEmpty, FileManager.default.isExecutableFile(atPath: bin.path) else {
            throw Failure.executableMissing(executable)
        }

        // 完整性检查，**不是**信任凭据：ad-hoc 签名任何人都能签（见文件开头）。
        let verify = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else {
            throw Failure.signatureInvalid(verify.stderr.isEmpty ? "codesign 退出码 \(verify.status)" : verify.stderr)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 替换

    /// 能不能就地替换。**在碰任何东西之前问**，不行就直接给用户一条明路。
    static func preflight(target: URL) throws {
        // 从下载目录/DMG 里直接双击运行的话，App 跑在一条只读的随机挂载点上
        // （App Translocation）—— 那里根本没有「可替换的 bundle」这回事。
        if target.path.contains("/AppTranslocation/") { throw Failure.translocated }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure.notWritable(parent.path)
        }
    }

    /// 换掉正在运行的 bundle 并重启。
    ///
    /// **先退再换**：写一个脱离进程的 shell 脚本，等本进程 PID 消失之后才动 bundle。
    /// 不做「运行中就地替换」—— 旧进程可能还在懒加载自己的资源，读到换了一半的包就是崩溃；
    /// 而且脚本里带得动回滚，能保证最坏情况下用户手里还剩一个能用的旧版本。
    @MainActor
    static func install(stagedApp: URL) throws {
        let target = Bundle.main.bundleURL
        try preflight(target: target)

        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-swap-\(UUID().uuidString).sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $4 是暂存目录本身（`<tmp>/aiusage-update-<UUID>`），换完之后由脚本删掉 ——
        // 本进程那时已经退了，删不了；交给 LaunchServices 起的那个新实例更不可能知道它。
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                       target.path, stagedApp.path, workDirectory(for: stagedApp).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        // 脚本已经起来了，它会等我们死。**这里必须真的退**，否则它一直等下去。
        NSApp.terminate(nil)
    }

    /// 用户放弃安装时把暂存目录删干净。**不动正在跑的那一份**，只删我们自己下回来的东西。
    static func discard(stagedApp: URL) {
        try? FileManager.default.removeItem(at: workDirectory(for: stagedApp))
    }

    /// `<tmp>/aiusage-update-<UUID>/extract/AI Usage.app` → `<tmp>/aiusage-update-<UUID>`。
    ///
    /// 往上是**两级**，不是一级：中间那层 `extract/` 是解压出来的，真正要删的是整个工作目录
    /// （里面有 zip 和解压结果）。用 `deleteLastPathComponent()` 而不是字符串截断，
    /// 免得路径里出现同名片段时切错地方。
    private static func workDirectory(for stagedApp: URL) -> URL {
        stagedApp.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 换 bundle 的脚本。写成模板而不是拼字符串，引用处一眼能看全流程。
    ///
    /// 每条外部命令都走 `if !`，**不用 `set -e`** —— 失败要能走到回滚那一步，
    /// 而不是让脚本在中途直接结束、把用户撂在一个没有 App 的状态里。
    private static let swapScript = """
    #!/bin/sh
    # $1 = 旧进程 PID，$2 = 目标 .app，$3 = 暂存的新 .app，$4 = 暂存用的工作目录
    PID="$1"; TARGET="$2"; STAGED="$3"; WORK="$4"

    # 等 App 真的退出。替换一个还在跑的 bundle 是自找麻烦。
    while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done

    BACKUP="${TARGET}.old-$$"
    if ! mv "$TARGET" "$BACKUP"; then exit 1; fi
    if ! /usr/bin/ditto "$STAGED" "$TARGET"; then
      # 回滚：宁可让用户留在旧版本，也不能让他手里没有 App
      rm -rf "$TARGET"
      mv "$BACKUP" "$TARGET"
      rm -rf "$WORK"
      exit 1
    fi
    rm -rf "$BACKUP"
    # 暂存目录用完就删（成功、回滚两条路都删）：本进程已经退了，没人替它收尾
    rm -rf "$WORK"

    # URLSession 下来的文件一般不带隔离属性，但万一有，重启后会被 Gatekeeper 拦下
    # 或者被 translocation —— 那个失败要等用户报「更新之后打不开」才会被发现。
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null

    # -n：换完 bundle 之后 LaunchServices 可能还记着旧的注册，强制起一个新实例
    /usr/bin/open -n "$TARGET"
    """

    // MARK: - 跑外部命令

    /// 跑一个外部命令并收好它的 stderr。
    ///
    /// **stderr 走临时文件，不能用 `Pipe`** —— `ditto` 处理十兆的 bundle 时输出会超过
    /// 64 KB 的管道缓冲区，而 `waitUntilExit()` 在管道被读空之前不会返回，两边互等就是死锁。
    /// （`DeviceSync.materialize` 那种把 stderr 直接丢进 nullDevice 的写法在这里不够用：
    /// 失败时要能看到 ditto 说了什么。）
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) throws -> (status: Int32, stderr: String) {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = handle
        try p.run()
        p.waitUntilExit()

        let text = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, text)
    }
}
