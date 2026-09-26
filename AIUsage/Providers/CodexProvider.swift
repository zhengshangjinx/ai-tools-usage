import Foundation

/// Codex（Desktop、VS Code 扩展、`codex` CLI）都把 rollout JSONL 写在 ~/.codex/sessions/YYYY/MM/DD/。
///
/// 统计口径与 T3 Code / ccusage 对齐：
/// - 每条 `event_msg` / `token_count` 事件的 `last_token_usage` 即一次响应的用量；连续重复（限额刷新时重发）只算一次。
/// - fork / 子代理线程的文件开头会把父线程完整历史复制一遍，时间戳全部重打成 fork 那一刻，且在 1 秒内成批写入；
///   这些复制事件必须丢弃，否则子代理越多重复计得越多。
/// - 模型来自最近一条 `turn_context`；尚未出现模型的事件不计。
/// - `session_meta.originator` 含 cli 视为 Codex CLI。
struct CodexProvider: UsageProvider {
    private let markers = [
        "\"session_meta\"".data(using: .utf8)!,
        "\"turn_context\"".data(using: .utf8)!,
        "\"token_count\"".data(using: .utf8)!,
    ]

    /// 复制事件之间的最大间隔；真实的首次模型响应至少在数秒之后
    private static let forkCopyMaxGap: TimeInterval = 1.0

    func scan(paths: [String]) -> [UsageRecord] {
        let files = paths.flatMap { ParseUtil.files(under: $0, withExtension: "jsonl") }
            .filter { $0.lastPathComponent.hasPrefix("rollout-") }
        return ScanCache.shared.scan(files, parse: scanFile)
    }

    private struct State {
        var provider: ProviderKind = .codex
        var sessionId: String
        var model = ""
        var sawMeta = false
        var lastSignature: String?
        var suppressingForkCopies = false
        var forkAnchor: Date = .distantPast
    }

    /// **可见性是 internal 而不是 private**：`--selftest` 要拿合成 rollout 直接调它，
    /// 绕开 `scan(paths:)` 里那个会读写用户 `scan_cache_v3.json`（并删同目录其他
    /// `scan_cache_v*.json`）的 `ScanCache.shared`。**只放开了可见性，逻辑一行没动。**
    func scanFile(_ file: URL) -> [UsageRecord] {
        var out: [UsageRecord] = []
        var st = State(sessionId: file.deletingPathExtension().lastPathComponent)

        ParseUtil.forEachLine(in: file, containingAny: markers) { obj in
            guard let type = obj["type"] as? String, let payload = obj["payload"] as? [String: Any] else { return }
            switch type {
            case "session_meta":
                guard !st.sawMeta else { return }
                st.sawMeta = true
                if let id = payload["id"] as? String ?? payload["session_id"] as? String { st.sessionId = id }
                if let originator = (payload["originator"] as? String)?.lowercased(), originator.contains("cli") || originator == "codex_exec" {
                    st.provider = .codexCLI
                }
                if let ts = ParseUtil.date(from: obj["timestamp"]), Self.isForked(payload) {
                    st.suppressingForkCopies = true
                    st.forkAnchor = ts
                }
            case "turn_context":
                if let m = payload["model"] as? String { st.model = m }
                else if let cm = payload["collaboration_mode"] as? [String: Any],
                        let settings = cm["settings"] as? [String: Any],
                        let m = settings["model"] as? String { st.model = m }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let ts = ParseUtil.date(from: obj["timestamp"]),
                      !st.model.isEmpty else { return }

                let signature = Self.signature(last)
                guard signature != st.lastSignature else { return }
                st.lastSignature = signature

                if st.suppressingForkCopies {
                    if ts.timeIntervalSince(st.forkAnchor) < Self.forkCopyMaxGap {
                        st.forkAnchor = ts
                        return
                    }
                    st.suppressingForkCopies = false
                }

                let input = ParseUtil.int(last["input_tokens"])
                let cached = ParseUtil.int(last["cached_input_tokens"])
                let cacheWrite = ParseUtil.int(last["cache_write_input_tokens"])
                let record = UsageRecord(
                    provider: st.provider, sessionId: st.sessionId, model: st.model, timestamp: ts,
                    inputUncached: max(0, input - cached - cacheWrite),
                    cacheRead: max(0, cached),
                    cacheWrite: max(0, cacheWrite),
                    output: max(0, ParseUtil.int(last["output_tokens"]))
                )
                if record.total > 0 { out.append(record) }
            default: break
            }
        }
        return out
    }

    /// session_meta 是否标记为 fork 或子代理线程
    private static func isForked(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any] else { return false }
        return spawn["parent_thread_id"] is String
    }

    private static func signature(_ usage: [String: Any]) -> String {
        ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
            .map { String(ParseUtil.int(usage[$0])) }.joined(separator: "|")
    }
}
