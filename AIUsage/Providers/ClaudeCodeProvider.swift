import Foundation

/// Claude Code stores one JSONL per session under ~/.claude/projects/<project>/<session>.jsonl
/// (subagent transcripts live in <session>/subagents/*.jsonl and are included).
/// Each assistant line carries `message.usage` (Anthropic semantics: input_tokens excludes cache tokens).
/// The same API response is often written multiple times, so dedupe by message.id + requestId.
/// CodeBuddy Code（~/.codebuddy/projects）是同一格式，通过 `kind` 区分展示环境。
struct ClaudeCodeProvider: UsageProvider {
    var kind: ProviderKind = .claudeCode
    private let markers = ["\"usage\"".data(using: .utf8)!]

    func scan(paths: [String]) -> [UsageRecord] {
        let files = paths.flatMap { ParseUtil.files(under: $0, withExtension: "jsonl") }
        return ScanCache.shared.scan(files, parse: scanFile)
    }

    /// 一次 API 响应会在 JSONL 里出现多行（一个内容块一行：thinking / text / tool_use），
    /// 同一份 usage 跟着每行重复写。**但重复行里的 usage 不一定一样**：
    /// 子代理转录（`<session>/subagents/agent-*.jsonl`）走的是流式写法 ——
    /// 前面的内容块先落盘、此时 usage 还全是 0，只有最后那一行带真实用量。
    /// 实测 2026-09-25 那天有 100 个请求是这个形状，涉及 515 万 token。
    ///
    /// 所以去重不能「先到先得」：原先的实现是先把 key 记进 `seen`、再判断 `total > 0` 丢弃空记录，
    /// 于是第一行那个全 0 的占位把 key 占了位、后面带真实用量的行反被当成重复丢掉 ——
    /// **整个请求直接消失**（那一档 claude-opus-5 因此只算出 93 万，实际 608 万）。
    /// 现在按 key 保留用量最大的那条：全 0 的占位入不了表，重复且相同的行也不受影响。
    ///
    /// **可见性是 internal 而不是 private**：`--selftest` 要拿合成日志直接调它。
    /// 上面那个 `scan(paths:)` 必经 `ScanCache.shared` —— 那会写用户的
    /// `~/Library/Application Support/AIUsage/scan_cache_v3.json`，还会顺手删掉同目录下别的
    /// `scan_cache_v*.json`。测试绝不能走那条路。**只放开了可见性，逻辑一行没动。**
    func scanFile(_ file: URL) -> [UsageRecord] {
        var records: [UsageRecord] = []
        /// key → 在 `records` 里的下标，用它就地换掉用量更大的那条
        var best: [String: Int] = [:]
        let fallbackSession = file.deletingPathExtension().lastPathComponent
        ParseUtil.forEachLine(in: file, containingAny: markers) { obj in
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let ts = ParseUtil.date(from: obj["timestamp"]) else { return }

            let messageId = message["id"] as? String
            let requestId = obj["requestId"] as? String
            let key = "\(messageId ?? (obj["uuid"] as? String ?? UUID().uuidString))|\(requestId ?? "")"

            let record = UsageRecord(
                provider: kind,
                sessionId: obj["sessionId"] as? String ?? fallbackSession,
                model: (message["model"] as? String) ?? "unknown",
                timestamp: ts,
                inputUncached: ParseUtil.int(usage["input_tokens"]),
                cacheRead: ParseUtil.int(usage["cache_read_input_tokens"]),
                cacheWrite: ParseUtil.int(usage["cache_creation_input_tokens"]),
                output: ParseUtil.int(usage["output_tokens"])
            )
            guard record.total > 0 else { return }
            if let i = best[key] {
                if record.total > records[i].total { records[i] = record }
            } else {
                best[key] = records.count
                records.append(record)
            }
        }
        return records
    }
}
