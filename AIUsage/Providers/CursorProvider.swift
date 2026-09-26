import Foundation

/// Cursor 把对话存在 `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` 的 `cursorDiskKV` 表：
/// - `composerData:<composerId>`：会话元数据（createdAt、模型配置）
/// - `bubbleId:<composerId>:<bubbleId>`：单条消息，type 2 为助手回复，带 `tokenCount:{inputTokens,outputTokens}`
/// Cursor 不区分缓存 token，全部记入未缓存输入。
struct CursorProvider: UsageProvider {
    func scan(paths: [String]) -> [UsageRecord] {
        paths.flatMap(scanDatabase)
    }

    private func scanDatabase(_ path: String) -> [UsageRecord] {
        guard let db = SQLiteReader(path: path), db.hasTable("cursorDiskKV") else { return [] }

        var composerCreated: [String: Date] = [:]
        var composerModel: [String: String] = [:]
        db.query("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'") { stmt in
            let key = SQLiteReader.text(stmt, 0)
            guard let obj = SQLiteReader.json(stmt, 1) else { return }
            let id = String(key.dropFirst("composerData:".count))
            if let d = ParseUtil.date(from: obj["createdAt"]) { composerCreated[id] = d }
            if let m = Self.model(in: obj) { composerModel[id] = m }
        }

        var records: [UsageRecord] = []
        db.query("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'") { stmt in
            let key = SQLiteReader.text(stmt, 0)
            let parts = key.split(separator: ":")
            guard parts.count >= 3, let obj = SQLiteReader.json(stmt, 1),
                  ParseUtil.int(obj["type"]) == 2,
                  let tc = obj["tokenCount"] as? [String: Any] else { return }
            let composerId = String(parts[1])
            let input = ParseUtil.int(tc["inputTokens"])
            let output = ParseUtil.int(tc["outputTokens"])
            guard input + output > 0 else { return }

            let timing = obj["timingInfo"] as? [String: Any]
            let ts = ParseUtil.date(from: timing?["clientRpcSendTime"])
                ?? ParseUtil.date(from: timing?["clientSettleTime"])
                ?? ParseUtil.date(from: obj["createdAt"])
                ?? composerCreated[composerId]
            guard let ts else { return }
            let model = Self.model(in: obj) ?? composerModel[composerId] ?? "cursor-unknown"

            records.append(UsageRecord(provider: .cursor, sessionId: composerId, model: model, timestamp: ts,
                                       inputUncached: input, cacheRead: 0, cacheWrite: 0, output: output))
        }
        return records
    }

    private static func model(in obj: [String: Any]) -> String? {
        for key in ["modelInfo", "modelConfig"] {
            if let m = obj[key] as? [String: Any], let name = m["modelName"] as? String, !name.isEmpty { return name }
        }
        if let name = obj["modelName"] as? String, !name.isEmpty { return name }
        return nil
    }
}
