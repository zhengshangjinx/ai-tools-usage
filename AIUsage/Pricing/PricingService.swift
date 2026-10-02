import Foundation

/// Per-token USD prices for a model.
struct ModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheRead: Double?
    var cacheWrite: Double?

    /// 计价对 4 个 token 桶是线性的 —— 所以跨设备同步只传桶、不传费用，
    /// 远端历史在展示端用本机价格表重算，结果与逐条记录计算完全等价。
    var inputRate: Double { input }
    var cacheReadRate: Double { cacheRead ?? input }
    var cacheWriteRate: Double { cacheWrite ?? input }
    var outputRate: Double { output }

    func cost(inputUncached n1: Int, cacheRead n2: Int, cacheWrite n3: Int, output n4: Int) -> Double {
        let a = Double(n1) * inputRate
        let b = Double(n2) * cacheReadRate
        let c = Double(n3) * cacheWriteRate
        let d = Double(n4) * outputRate
        return a + b + c + d
    }

    func cost(for r: UsageRecord) -> Double {
        cost(inputUncached: r.inputUncached, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite, output: r.output)
    }

    func cost(for a: AggregateRow) -> Double {
        cost(inputUncached: a.inputUncached, cacheRead: a.cacheRead, cacheWrite: a.cacheWrite, output: a.output)
    }

    /// How much cheaper the cache reads were than paying full input price.
    func cacheSavings(cacheRead n: Int) -> Double {
        Double(n) * max(0, inputRate - cacheReadRate)
    }

    func cacheSavings(for r: UsageRecord) -> Double { cacheSavings(cacheRead: r.cacheRead) }

    func cacheSavings(for a: AggregateRow) -> Double { cacheSavings(cacheRead: a.cacheRead) }

    /// 从「美元 / 百万 tokens」构造 —— 表单里填的都是这个单位，换算只在这里做一次
    static func perMillion(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) -> ModelPrice {
        let perM = 1_000_000.0
        return ModelPrice(input: input / perM, output: output / perM,
                          cacheRead: cacheRead.map { $0 / perM }, cacheWrite: cacheWrite.map { $0 / perM })
    }

    /// 反算回「美元 / 百万 tokens」的纯数字文本，给表单回填用。
    /// 带 $ 的展示写法见 `PricingService.formatPerMillion`。
    static func perMillionText(_ perToken: Double) -> String {
        let v = perToken * 1_000_000
        if v == v.rounded() { return String(format: "%.0f", v) }
        if abs(v) >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
}

/// 这条价格是从哪来的。表里查不到 ≠ 价格是 0，弹窗里必须把两者分开说。
enum PriceSource {
    case manual, table, none
}

/// Fetches https://github.com/BerriAI/litellm model_prices_and_context_window.json, caches it in Application Support,
/// and layers user overrides on top. Lookup is tolerant of provider prefixes, date suffixes and effort suffixes.
@MainActor
final class PricingService: ObservableObject {
    static let liteLLMURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    @Published private(set) var remote: [String: ModelPrice] = [:]
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var overrides: [String: ModelPrice] {
        didSet { saveOverrides(); cache.removeAll() }
    }

    private var cache: [String: ModelPrice?] = [:]
    private var keyCache: [String: String?] = [:]
    private var normalizedRemote: [String: ModelPrice] = [:]

    private static let overridesKey = "pricing.overrides.v1"
    private static var cacheFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AIUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("litellm_prices.json")
    }

    init() {
        if let data = DemoRuntime.defaults.data(forKey: Self.overridesKey),
           let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    // MARK: Loading

    func loadCachedThenRefresh() async {
        // 演示模式：不读缓存文件（它在用户的 Application Support 里），更不联网 ——
        // 出图慢是一回事，联网截出来的「价格更新于 x 分钟前」每次都不一样才是真问题。
        if DemoRuntime.isActive {
            install(DemoData.priceTable)
            lastUpdated = DemoRuntime.priceUpdatedAt
            return
        }
        if let data = try? Data(contentsOf: Self.cacheFile) {
            apply(data: data)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.cacheFile.path), let d = attrs[.modificationDate] as? Date {
                lastUpdated = d
            }
        }
        if let last = lastUpdated, Date().timeIntervalSince(last) < 6 * 3600, !remote.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        // 演示模式下「刷新价格」按钮仍然可点，但它只是把那份编好的表再装一遍
        if DemoRuntime.isActive {
            install(DemoData.priceTable)
            lastUpdated = DemoRuntime.priceUpdatedAt
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.liteLLMURL)
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true else {
                throw URLError(.badServerResponse)
            }
            apply(data: data)
            try? data.write(to: Self.cacheFile, options: .atomic)
            lastUpdated = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 把一张已经解析好的价格表装进查表结构。`apply(data:)` 与演示模式共用它 ——
    /// 归一化与模糊匹配只该有一份实现，否则演示模式里命中的条目口径会和真表不一致。
    private func install(_ table: [String: ModelPrice]) {
        remote = table
        normalizedRemote = [:]
        for (k, v) in table {
            let stripped = Self.stripProvider(k).lowercased()
            if normalizedRemote[stripped] == nil || !k.contains("/") { normalizedRemote[stripped] = v }
        }
        cache.removeAll()
        objectWillChange.send()
    }

    private func apply(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var out: [String: ModelPrice] = [:]
        for (key, value) in obj {
            guard key != "sample_spec", let d = value as? [String: Any],
                  let input = d["input_cost_per_token"] as? Double,
                  let output = d["output_cost_per_token"] as? Double else { continue }
            let mode = d["mode"] as? String
            if let mode, !["chat", "responses", "completion"].contains(mode) { continue }
            out[key] = ModelPrice(input: input, output: output,
                                  cacheRead: d["cache_read_input_token_cost"] as? Double,
                                  cacheWrite: d["cache_creation_input_token_cost"] as? Double)
        }
        install(out)
    }

    private func saveOverrides() {
        if let data = try? JSONEncoder().encode(overrides) {
            DemoRuntime.defaults.set(data, forKey: Self.overridesKey)
        }
    }

    // MARK: Lookup

    func price(for model: String) -> ModelPrice? {
        if cache.keys.contains(model) { return cache[model] ?? nil }
        let hit = lookup(model)
        cache[model] = hit?.price
        keyCache[model] = hit?.key
        return hit?.price
    }

    /// 命中的价格表条目名。模型标识带日期 / effort 后缀时会模糊匹配到短名字，
    /// 弹窗里得说清楚价格是照哪一条算的，否则用户会以为表里真有这么一行。
    func matchedTableKey(for model: String) -> String? {
        _ = price(for: model)
        return keyCache[model] ?? nil
    }

    /// 手动单价（大小写不敏感，与查表口径一致）
    func override(for model: String) -> ModelPrice? {
        if let o = overrides[model] { return o }
        let lower = model.lowercased()
        return overrides.first { $0.key.lowercased() == lower }?.value
    }

    func source(for model: String) -> PriceSource {
        if override(for: model) != nil { return .manual }
        return price(for: model) != nil ? .table : .none
    }

    private func lookup(_ model: String) -> (key: String, price: ModelPrice)? {
        if let o = overrides[model] { return (model, o) }
        let lower = model.lowercased()
        if let hit = overrides.first(where: { $0.key.lowercased() == lower }) { return (hit.key, hit.value) }
        if lower.isEmpty || lower == "unknown" || lower.hasPrefix("<") { return nil }

        for candidate in Self.candidates(for: lower) {
            if let p = normalizedRemote[candidate] { return (candidate, p) }
        }
        // Fallback: longest remote key that is a prefix of the model name (e.g. "claude-sonnet-4-5" for "claude-sonnet-4-5-20250929-medium").
        let best = normalizedRemote.keys
            .filter { $0.count >= 6 && lower.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        return best.flatMap { k in normalizedRemote[k].map { (k, $0) } }
    }

    private static func stripProvider(_ key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return key }
        return String(key[key.index(after: slash)...])
    }

    /// Progressive simplifications of a model id to try against the price table.
    static func candidates(for model: String) -> [String] {
        var list: [String] = [model]
        var m = model
        // Drop effort / tier suffixes used by Devin and others: "-medium", "-high", "-low", "-thinking"
        for suffix in ["-medium", "-high", "-low", "-max", "-thinking", "-latest"] where m.hasSuffix(suffix) {
            m.removeLast(suffix.count); list.append(m)
        }
        // Drop trailing date stamps: "-20250929" / "-2025-09-29"
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) ?? m.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            m = String(m[..<r.lowerBound]); list.append(m)
        }
        // "claude-sonnet-4-5" <-> "claude-sonnet-4.5"
        if let r = m.range(of: #"-(\d)-(\d)$"#, options: .regularExpression) {
            let dotted = m.replacingCharacters(in: r, with: "-" + m[r].dropFirst().replacingOccurrences(of: "-", with: "."))
            list.append(dotted)
        } else if let r = m.range(of: #"-(\d)\.(\d)$"#, options: .regularExpression) {
            list.append(m.replacingCharacters(in: r, with: m[r].replacingOccurrences(of: ".", with: "-")))
        }
        return list
    }

    // MARK: Convenience

    static func formatPerMillion(_ perToken: Double?) -> String {
        guard let p = perToken else { return "—" }
        return String(format: "$%.2f", p * 1_000_000)
    }
}
