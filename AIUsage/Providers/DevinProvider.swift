import Foundation
import SQLite3

/// Devin (Desktop and CLI) keeps a SQLite database at ~/.local/share/devin/cli/sessions.db.
/// Assistant messages live in `message_nodes.chat_message` (JSON) with `metadata.metrics` holding token counts
/// (Anthropic semantics) and `metadata.generation_model`. The DB is WAL-mode and may be open by a running Devin;
/// we read it directly read-only (WAL permits concurrent readers) and fall back to a temp snapshot if that fails.
struct DevinProvider: UsageProvider {
    func scan(paths: [String]) -> [UsageRecord] {
        var records: [UsageRecord] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            records.append(contentsOf: scanDatabase(at: path))
        }
        return records
    }

    private func snapshot(_ path: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aiusage-devin-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("sessions.db")
        do { try fm.copyItem(atPath: path, toPath: dest.path) } catch { return nil }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: dest.path + suffix)
        }
        return dest
    }

    private func scanDatabase(at path: String) -> [UsageRecord] {
        // WAL mode allows concurrent readers, so try the live file first; fall back to a snapshot copy if it is locked.
        var db: OpaquePointer?
        var snapshotDir: URL?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK || !canRead(db) {
            if let db { sqlite3_close(db) }
            db = nil
            guard let snap = snapshot(path) else { return [] }
            snapshotDir = snap.deletingLastPathComponent()
            guard sqlite3_open_v2(snap.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        }
        guard let db else { return [] }
        defer {
            sqlite3_close(db)
            if let snapshotDir { try? FileManager.default.removeItem(at: snapshotDir) }
        }
        sqlite3_busy_timeout(db, 3000)

        // Session-level model fallback.
        var sessionModel: [String: String] = [:]
        query(db, "SELECT id, model FROM sessions") { stmt in sessionModel[text(stmt, 0)] = text(stmt, 1) }

        // Incremental: the table is append-only (AUTOINCREMENT row_id), so only rows past the cached high-water mark
        // need parsing. A margin of rows is re-read in case metadata was attached slightly after insert.
        var cache = DevinCache.load(for: path)
        let fromRow = max(0, cache.maxRowId - 2000)
        var maxRow = cache.maxRowId
        var byKey = cache.records
        query(db, "SELECT session_id, chat_message, created_at, row_id FROM message_nodes WHERE row_id > \(fromRow) AND chat_message LIKE '%\"metrics\"%'") { stmt in
            maxRow = max(maxRow, Int(sqlite3_column_int64(stmt, 3)))
            let sessionId = text(stmt, 0)
            guard let raw = sqlite3_column_text(stmt, 1) else { return }
            let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, 1)))
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["role"] as? String == "assistant",
                  let meta = obj["metadata"] as? [String: Any],
                  let metrics = meta["metrics"] as? [String: Any] else { return }

            let key = (obj["message_id"] as? String) ?? (meta["request_id"] as? String) ?? UUID().uuidString

            let ts = ParseUtil.date(from: meta["created_at"])
                ?? ParseUtil.date(from: meta["started_generation_at"])
                ?? Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))
            let model = (meta["generation_model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? sessionModel[sessionId].flatMap { $0.isEmpty ? nil : $0 }
                ?? "unknown"

            let record = UsageRecord(
                provider: .devin, sessionId: sessionId, model: model, timestamp: ts,
                inputUncached: ParseUtil.int(metrics["input_tokens"]),
                cacheRead: ParseUtil.int(metrics["cache_read_tokens"]),
                cacheWrite: ParseUtil.int(metrics["cache_creation_tokens"]),
                output: ParseUtil.int(metrics["output_tokens"])
            )
            if record.total > 0 { byKey[key] = record }
        }
        query(db, "SELECT max(row_id) FROM message_nodes") { stmt in maxRow = max(maxRow, Int(sqlite3_column_int64(stmt, 0))) }
        cache.maxRowId = maxRow
        cache.records = byKey
        cache.save(for: path)
        return Array(byKey.values)
    }

    struct DevinCache: Codable {
        var maxRowId = 0
        var records: [String: UsageRecord] = [:]

        private static func file(for path: String) -> URL {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsage", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = path.data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "/", with: "_").suffix(60)
            return dir.appendingPathComponent("devin_cache_\(name).json")
        }

        static func load(for path: String) -> DevinCache {
            guard let data = try? Data(contentsOf: file(for: path)),
                  let c = try? JSONDecoder().decode(DevinCache.self, from: data) else { return DevinCache() }
            return c
        }

        func save(for path: String) {
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.file(for: path), options: .atomic) }
        }

        static func clearAll() {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsage", isDirectory: true)
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("devin_cache_") {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private func canRead(_ db: OpaquePointer?) -> Bool {
        guard let db else { return false }
        var ok = false
        query(db, "SELECT count(*) FROM sessions") { _ in ok = true }
        return ok
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}
