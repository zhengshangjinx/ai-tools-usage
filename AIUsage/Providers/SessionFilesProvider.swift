import Foundation

/// 本地会话文件加密（Windsurf / Antigravity 的 *.pb 熵值为 8.0，无法解析），只能按文件统计会话数与活跃日期。
/// 产出 total == 0 的"仅会话"记录：计入会话数，不计 token 与费用。
struct SessionFilesProvider: UsageProvider {
    let kind: ProviderKind
    let fileExtension: String

    func scan(paths: [String]) -> [UsageRecord] {
        var seen = Set<String>()
        var records: [UsageRecord] = []
        for root in paths {
            for file in ParseUtil.files(under: root, withExtension: fileExtension) {
                let id = file.deletingPathExtension().lastPathComponent
                guard seen.insert(id).inserted,
                      let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                records.append(UsageRecord(provider: kind, sessionId: id, model: "<sessions-only>", timestamp: mtime,
                                           inputUncached: 0, cacheRead: 0, cacheWrite: 0, output: 0))
            }
        }
        return records
    }
}

/// 本地无可读数据的工具（TRAE 的库为 SQLCipher 加密），只作为占位保留在数据源列表中。
struct EmptyProvider: UsageProvider {
    func scan(paths: [String]) -> [UsageRecord] { [] }
}
