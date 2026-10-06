import Foundation
import AppKit

/// 检查更新。形状照 `PricingService`：`@MainActor` + `ObservableObject` + `@Published private(set)`、
/// 内联 HTTP 状态判断、一把新鲜度闸门、演示模式在**每个**入口第一行短路。
///
/// 这个类只负责「问 GitHub 有没有新版本」并驱动状态机；真正替换 bundle 那一步在
/// `UpdateInstaller` 里 —— 那是唯一能伤到用户安装的代码，单独放、单独看。
///
/// **它做的是 GET，不是遥测。** 请求里不带你机器上的任何东西（除了一个固定的 UA 字符串），
/// GitHub 那边只会看到一个匿名 IP 在拉公开的 release 列表。
@MainActor
final class UpdateService: ObservableObject {

    /// 界面只认这一个状态。`Equatable` 是给 SwiftUI 的 `animation(_:value:)` 用的。
    enum Phase: Equatable {
        case idle(lastCheck: Date?)
        case checking
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        /// 包已经下回来、验完、暂存在临时目录里，**还没碰过正在跑的那一份**。
        /// 停在这一档等用户点头 —— 换 bundle 要重启，是全流程里唯一不可逆的一步。
        case readyToInstall(ReleaseInfo, staged: URL)
        case installing(ReleaseInfo)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle(lastCheck: nil)

    /// 配置项。**不是 private**：界面要绑同一个实例 ——
    /// 「关于」页自己 new 一个 `UpdateSettings()` 出来也能读写同一批 UserDefaults 键，
    /// 但那份内存副本和这里的会各走各的，症状是「开关关掉了，启动却还在查」。
    let settings: UpdateSettings
    private let session: URLSession
    /// 自建 session 的那个 delegate。存一份引用是为了下载前挂进度回调。
    private let delegate: UpdateSessionDelegate

    /// 6 小时。与 `PricingService` 拉价格表同一档 —— 一天查四次足够勤，而未认证的
    /// GitHub API 是 60 次/小时/IP，这个频率离限流差着两个数量级。
    static let freshnessInterval: TimeInterval = 6 * 3600

    /// 版本号**只从 bundle 读**。这是本项目第四次读它（另有 `DemoData` / `ExportMenu` / `UsageStore`），
    /// 但**不要**在这里或别处再写死一个字面量版本号 —— `project.yml` 的 `MARKETING_VERSION`
    /// 是唯一的事实来源，写死的那次真出过事（见 `DemoData.swift:26-29`）。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// `settings` 收可选而不是写 `= UpdateSettings()`：默认参数在**非隔离**上下文里求值，
    /// 而 `UpdateSettings` 是 `@MainActor` 的 —— 写成默认值编译不过。
    init(settings: UpdateSettings? = nil, session: URLSession? = nil) {
        let resolved = settings ?? UpdateSettings()
        self.settings = resolved
        let delegate = UpdateSessionDelegate()
        self.delegate = delegate
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        // 演示模式下**构造出来就是「有新版本」**，不指望调用方记得先查一次 ——
        // 出图工装少调一句，README 里那张带更新行的图就会静默变空。
        if DemoRuntime.isActive { phase = .available(DemoData.availableUpdate) }
    }

    var availableUpdate: ReleaseInfo? {
        switch phase {
        case .available(let r), .downloading(let r, _), .readyToInstall(let r, _), .installing(let r):
            return r
        default:
            return nil
        }
    }

    /// 「手上正有事没做完」。`readyToInstall` 也算：包已经躺在临时目录里了，
    /// 这时候放一次新的检查进来，暂存的那份就没人认领、也没人清理了。
    /// 用户想脱身有明确出口（`discardStaged` / `skip`），不存在被卡住的状态。
    var busy: Bool {
        switch phase {
        case .checking, .downloading, .readyToInstall, .installing: return true
        default: return false
        }
    }

    // MARK: - 检查

    /// 启动时调一次。**所有闸门都在这里**，调用方不必自己判断该不该查。
    ///
    /// 后三个无头模式的判断不能省：命令行可以跑一个**不带 `--demo`** 的 `--render`，
    /// 不拦的话出图过程里会夹一次真实网络请求，图就不再是可复现的了。
    func checkIfDue() async {
        // 演示模式：不联网，直接把编好的那一份装上（照 `PricingService.loadCachedThenRefresh`）
        if DemoRuntime.isActive {
            phase = .available(DemoData.availableUpdate)
            return
        }
        guard !SelfTest.isRequested,
              RenderHarness.outputDirectory == nil,
              !RenderHarness.benchMode,
              ExportHarness.request == nil,
              settings.autoCheckEnabled else { return }
        if let last = settings.lastCheck, Date().timeIntervalSince(last) < Self.freshnessInterval { return }
        await checkNow()
    }

    /// 用户手点「检查更新」。**不看新鲜度闸门** —— 手动点就是要现在查。
    func checkNow() async {
        if DemoRuntime.isActive {
            phase = .available(DemoData.availableUpdate)
            return
        }
        guard !busy else { return }
        phase = .checking
        defer { settings.lastCheck = Date() }
        do {
            var request = URLRequest(url: UpdatePolicy.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            // GitHub 的 API 不接受没有 User-Agent 的请求（会直接 403）
            request.setValue("AIUsage/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            switch http.statusCode {
            case 200..<300:
                break
            case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
                // 限流不是错误，是「稍后再试」—— 界面按提示色而不是报错色显示
                phase = .failed("检查太频繁，过一会儿再试")
                return
            case 404:
                phase = .failed("找不到发布页，仓库可能改名或转私有")
                return
            default:
                throw URLError(.badServerResponse)
            }

            let releases = try JSONDecoder().decode([GHRelease].self, from: data)
            if let found = UpdatePolicy.pickRelease(from: releases,
                                                    current: Self.currentVersion,
                                                    skipped: settings.skippedVersion) {
                phase = .available(found)
            } else {
                phase = .idle(lastCheck: Date())
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 动作

    /// 用户点了「跳过这个版本」。只写配置，不碰网络。
    func skip(_ release: ReleaseInfo) {
        settings.skippedVersion = release.tag
        phase = .idle(lastCheck: settings.lastCheck)
    }

    /// 打开这个版本的发布页（没有可下载资产、或替换失败时的退路）。
    func openReleasePage(_ release: ReleaseInfo?) {
        let url = release?.pageURL
            ?? URL(string: "https://github.com/\(UpdatePolicy.owner)/\(UpdatePolicy.repo)/releases")!
        NSWorkspace.shared.open(url)
    }

    /// 下载并校验，然后**停在 `.readyToInstall` 等用户点头**。
    ///
    /// 下载完不直接换 bundle：换的那一下要退进程、要重启，是全流程里唯一不可逆的一步
    /// （伪造成本很低的 ad-hoc 签名意味着这一步只能靠「HTTPS + GitHub 账号没被攻破」兜底）。
    /// 走到这一步为止，用户机器上除临时目录外什么都没被改过 —— 那就让他有机会说不。
    func downloadAndInstall() async {
        guard let release = availableUpdate, let asset = release.asset else { return }
        if DemoRuntime.isActive { return }   // 演示模式绝不落盘、绝不换 bundle
        guard !busy else { return }
        phase = .downloading(release, progress: 0)
        delegate.onProgress = { [weak self] p in
            Task { @MainActor in
                guard let self, case .downloading(let r, _) = self.phase else { return }
                self.phase = .downloading(r, progress: p)
            }
        }
        defer { delegate.onProgress = nil }
        do {
            let staged = try await UpdateInstaller.download(asset, release: release, session: session)
            phase = .readyToInstall(release, staged: staged)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 用户点了「重启并更新」。真正会动到用户安装的那一下，就在这个调用里。
    func installStaged() {
        guard case .readyToInstall(let release, let staged) = phase else { return }
        if DemoRuntime.isActive { return }
        phase = .installing(release)
        do {
            // 成功的话它会退掉本进程（换完 bundle 必须重启才生效），走不到下一行
            try UpdateInstaller.install(stagedApp: staged)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 用户点了「稍后」。把暂存的那份连同临时目录一起删掉，退回「发现新版本」那一档 ——
    /// 不删的话每放弃一次就在 `/var/folders` 里留一个几十兆的目录。
    func discardStaged() {
        guard case .readyToInstall(let release, let staged) = phase else { return }
        UpdateInstaller.discard(stagedApp: staged)
        phase = .available(release)
    }
}

/// 自建 session 的 delegate，一个人兼两职：
///
/// ① **重定向守门**：发布资产会 302 到 `release-assets.githubusercontent.com`
///    （实测；不是常被写进去的 `objects.githubusercontent.com`），那一步必须过白名单。
///    `URLSession.shared` 挂不了 delegate，所以这个 session 是自建的。
/// ② **下载进度**：`URLSessionDownloadDelegate` 的回调也走 session delegate，
///    所以不需要再单挂一个 task delegate（两者兼任还得操心「没实现的方法会不会回落到
///    session delegate」那套规则，合成一个就没这问题）。
private final class UpdateSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// 下载开始前设好、结束后清掉。同一时刻只会跑一次下载（`busy` 闸门保证）。
    var onProgress: (@Sendable (Double) -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // 不在白名单里的跳转一律不跟。返回 nil 之后 URLSession 会把那次 302 响应本身
        // 交给调用方，后面的状态码检查会自然失败 —— 不会把别处的内容当成安装包下下来。
        completionHandler(UpdatePolicy.isAllowedHost(request.url?.host) ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // 服务端没给 Content-Length 时是 -1，这时不报进度（界面显示不确定态的转圈）
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    /// `URLSessionDownloadDelegate` 的**必需**方法（不实现就整个协议不成立）。
    ///
    /// 这里什么都不做是刻意的：下载走的是 async 的 `session.download(from:)`，
    /// 临时文件的搬运由那个 API 自己管，它返回的 URL 才是我们要的。
    /// 实现了也不会被那条路径调用，留着纯粹是为了满足协议。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
