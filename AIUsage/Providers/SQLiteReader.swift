import Foundation
import SQLite3

/// 只读打开 SQLite（WAL 允许并发读）；被独占锁住时回退到临时快照副本。
final class SQLiteReader {
    private var db: OpaquePointer?
    private var snapshotDir: URL?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, probe() {
            sqlite3_busy_timeout(db, 3000)
            return
        }
        if let db { sqlite3_close(db) }
        db = nil
        guard let snap = Self.snapshot(path),
              sqlite3_open_v2(snap.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        snapshotDir = snap.deletingLastPathComponent()
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let snapshotDir { try? FileManager.default.removeItem(at: snapshotDir) }
    }

    private func probe() -> Bool {
        var ok = false
        query("SELECT 1") { _ in ok = true }
        return ok
    }

    private static func snapshot(_ path: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aiusage-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((path as NSString).lastPathComponent)
        do { try fm.copyItem(atPath: path, toPath: dest.path) } catch { return nil }
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
            try? fm.copyItem(atPath: path + suffix, toPath: dest.path + suffix)
        }
        return dest
    }

    func hasTable(_ name: String) -> Bool {
        var found = false
        query("SELECT name FROM sqlite_master WHERE type='table' AND name='\(name)'") { _ in found = true }
        return found
    }

    func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    /// TEXT 或 BLOB 列按 UTF-8 取出（Cursor 的 cursorDiskKV.value 是 BLOB）
    static func data(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        guard let raw = sqlite3_column_blob(stmt, col) else { return nil }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    static func int64(_ stmt: OpaquePointer, _ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }

    static func json(_ stmt: OpaquePointer, _ col: Int32) -> [String: Any]? {
        guard let d = data(stmt, col) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}
