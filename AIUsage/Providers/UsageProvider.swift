import Foundation

protocol UsageProvider {
    /// Scan the given paths and return every usage record found. Must be safe to call off the main thread.
    func scan(paths: [String]) -> [UsageRecord]
}

// MARK: - Shared parsing helpers

enum ParseUtil {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from any: Any?) -> Date? {
        if let s = any as? String {
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let n = any as? Int { return Date(timeIntervalSince1970: n > 1_000_000_000_000 ? Double(n) / 1000 : Double(n)) }
        return nil
    }

    static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return 0
    }

    /// Iterate over lines of a (possibly large) file, only yielding lines that contain at least one of the byte markers.
    static func forEachLine(in url: URL, containingAny markers: [Data], _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            let count = buf.count
            var start = 0
            while start < count {
                let rest = count - start
                let nl = memchr(base + start, 0x0A, rest)
                let end = nl.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let len = end - start
                defer { start = end + 1 }
                guard len > 0 else { continue }
                let lineStart = base + start
                if !markers.isEmpty {
                    var hit = false
                    for m in markers where m.withUnsafeBytes({ mb in memmem(lineStart, len, mb.baseAddress, mb.count) }) != nil {
                        hit = true; break
                    }
                    if !hit { continue }
                }
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: lineStart), count: len, deallocator: .none)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    body(obj)
                }
            }
        }
    }

    static func files(under root: String, withExtension ext: String) -> [URL] {
        let url = URL(fileURLWithPath: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return url.pathExtension == ext ? [url] : [] }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in e where f.pathExtension == ext { out.append(f) }
        return out
    }
}
