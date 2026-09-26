import Foundation

/// Per-file cache of parsed records keyed by path + size + mtime, so a rescan only re-parses files that changed.
/// Persisted as JSON in Application Support. Thread-safe.
///
/// **改了 `parse` 的口径就必须换缓存文件名。** 这里判的是「文件没变就沿用旧结果」，
/// 而文件没变时解析规则变了它并不知道 —— 沿用下去等于新逻辑永远不生效。
/// 沿革：`v1` → `v2`（加子代理转录）→ `v3`（同一 message.id 取用量最大的那条，
/// 修子代理转录里「首行 usage 全 0 占位」把整个请求顶掉的问题，见 `ClaudeCodeProvider.scanFile`）。
final class ScanCache {
    static let shared = ScanCache()

    private struct Entry: Codable {
        let size: Int
        let mtime: TimeInterval
        let records: [UsageRecord]
    }

    private var entries: [String: Entry] = [:]
    private var touched = Set<String>()
    private var dirty = false
    private let lock = NSLock()
    private var loaded = false

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan_cache_v3.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.file),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
        Self.removeSupersededCacheFiles()
    }

    /// 清掉上一版留下的缓存文件。
    ///
    /// 上面那条「改了 parse 口径必须换文件名」的规矩，代价是每换一次就在磁盘上永久多留一份 ——
    /// 实测 `scan_cache_v1.json` 16.7MB、`v2` 10.4MB 都还躺在 Application Support 里。
    /// 当前版本的文件名是这个进程**唯一**会读写的那个，所以同目录下其它 `scan_cache_v*.json`
    /// 按定义都是孤儿，直接删掉。
    ///
    /// 敢删是因为它只是缓存、不是数据源：万一回退到旧版本，那个版本重扫一遍就是了，
    /// 不会丢任何东西。只在启动后的第一次扫描时跑一次，不占热路径。
    private static func removeSupersededCacheFiles() {
        let dir = file.deletingLastPathComponent()
        let keep = file.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("scan_cache_") && name.hasSuffix(".json") && name != keep {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Parse `files` concurrently, reusing cached results for unchanged files.
    func scan(_ files: [URL], parse: @escaping (URL) -> [UsageRecord]) -> [UsageRecord] {
        lock.lock(); loadIfNeeded(); lock.unlock()
        var results = [[UsageRecord]](repeating: [], count: files.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let url = files[i]
            let path = url.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return }
            let size = (attrs[.size] as? Int) ?? 0
            let mtime = ((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970

            lock.lock()
            let cached = entries[path]
            touched.insert(path)
            lock.unlock()

            let records: [UsageRecord]
            if let cached, cached.size == size, cached.mtime == mtime {
                records = cached.records
            } else {
                records = parse(url)
                lock.lock()
                entries[path] = Entry(size: size, mtime: mtime, records: records)
                dirty = true
                lock.unlock()
            }
            resultsLock.lock(); results[i] = records; resultsLock.unlock()
        }
        return results.flatMap { $0 }
    }

    /// Drop entries for files that no longer exist and flush to disk.
    func finishScan() {
        lock.lock(); defer { lock.unlock() }
        let stale = entries.keys.filter { !touched.contains($0) && !FileManager.default.fileExists(atPath: $0) }
        if !stale.isEmpty { stale.forEach { entries.removeValue(forKey: $0) }; dirty = true }
        touched.removeAll()
        guard dirty else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.file, options: .atomic)
        }
        dirty = false
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); dirty = false; loaded = true
        try? FileManager.default.removeItem(at: Self.file)
        // 清缓存可能在本次进程还没扫过之前发生（`loadIfNeeded` 就还没轮到），
        // 这里补一次，免得孤儿文件要等到下次扫描才清掉
        Self.removeSupersededCacheFiles()
        DevinProvider.DevinCache.clearAll()
    }
}
