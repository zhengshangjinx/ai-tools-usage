import Foundation

/// Qoder IDE 把对话存在 `SharedClientCache/cache/db/local.db` 的 `chat_message` 表：
/// role='assistant' 行带 `token_info` JSON（prompt_tokens / completion_tokens / cached_tokens，OpenAI 口径，prompt 含 cached）
/// 与 `model_info` JSON（model_key，多为 auto / ultimate 等路由档，LiteLLM 无单价时显示未计价）。
struct QoderProvider: UsageProvider {
    func scan(paths: [String]) -> [UsageRecord] {
        paths.flatMap(scanDatabase)
    }

    private func scanDatabase(_ path: String) -> [UsageRecord] {
        guard let db = SQLiteReader(path: path), db.hasTable("chat_message") else { return [] }
        let hasRecord = db.hasTable("chat_record")
        let sql = hasRecord
            ? "SELECT cm.id, cm.session_id, cm.gmt_create, cm.token_info, cm.model_info, cr.extra FROM chat_message cm LEFT JOIN chat_record cr ON cr.request_id = cm.request_id WHERE cm.role = 'assistant' AND cm.token_info IS NOT NULL AND cm.token_info != ''"
            : "SELECT id, session_id, gmt_create, token_info, model_info, NULL FROM chat_message WHERE role = 'assistant' AND token_info IS NOT NULL AND token_info != ''"

        var records: [UsageRecord] = []
        var seen = Set<String>()
        db.query(sql) { stmt in
            let id = SQLiteReader.text(stmt, 0)
            guard seen.insert(id).inserted, let info = SQLiteReader.json(stmt, 3) else { return }
            let prompt = ParseUtil.int(info["prompt_tokens"])
            let completion = ParseUtil.int(info["completion_tokens"])
            let cached = min(prompt, ParseUtil.int(info["cached_tokens"]))
            guard prompt + completion > 0 else { return }

            let ts = ParseUtil.date(from: SQLiteReader.int64(stmt, 2)) ?? Date()
            var model = (SQLiteReader.json(stmt, 4)?["model_key"] as? String) ?? ""
            if model.isEmpty, let extra = SQLiteReader.json(stmt, 5),
               let cfg = extra["modelConfig"] as? [String: Any], let k = cfg["key"] as? String { model = k }
            if model.isEmpty { model = "qoder-auto" }

            records.append(UsageRecord(provider: .qoder, sessionId: SQLiteReader.text(stmt, 1), model: model, timestamp: ts,
                                       inputUncached: prompt - cached, cacheRead: cached, cacheWrite: 0, output: completion))
        }
        return records
    }
}
