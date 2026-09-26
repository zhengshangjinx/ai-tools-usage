import SwiftUI

/// LiteLLM 价格表的浏览器。
///
/// 拉下来三千多条，翻是翻不完的，所以给的是「搜索 + 分页」：
/// 搜索按空格分词、每段都要出现在标识里（顺序不限），分页把结果切成一页 50 条。
/// 行尾的「覆盖」把这条价格灌进手动单价表单 —— 查到价、改价在同一页完成。
struct PricingBrowser: View {
    @EnvironmentObject var pricing: PricingService
    /// 点「覆盖」时回调：把标识与当前价格交给上方的表单
    var onOverride: (String, ModelPrice) -> Void = { _, _ in }

    @State private var query = ""
    @State private var page = 0

    private static let pageSize = 50
    private static let rowHeight: CGFloat = 24

    var body: some View {
        let matched = matches
        let pageCount = max(1, (matched.count + Self.pageSize - 1) / Self.pageSize)
        let current = min(page, pageCount - 1)
        let slice = Array(matched.dropFirst(current * Self.pageSize).prefix(Self.pageSize))

        VStack(alignment: .leading, spacing: 8) {
            searchField
            HStack(spacing: 8) {
                Text("匹配 \(matched.count) 个模型 · 第 \(current + 1) / \(pageCount) 页")
                    .font(.system(size: 11)).foregroundStyle(Theme.gray500).monospacedDigit()
                Spacer(minLength: 8)
                pager(pageCount: pageCount, current: current)
            }
            columnHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(slice.enumerated()), id: \.element) { i, key in
                        if i > 0 { Divider().overlay(Theme.divider) }
                        row(key)
                    }
                    if slice.isEmpty {
                        Text("没有匹配的模型").font(.system(size: 12)).foregroundStyle(Theme.gray500)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                }
            }
            .frame(height: 232)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardBorder))
        }
        .onChange(of: query) { _, _ in page = 0 }
    }

    // MARK: 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.gray500)
            TextField("搜索模型标识，空格分词（如 claude opus）", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.gray500)
                }
                .buttonStyle(.plain).help("清空搜索")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.cardBorder))
    }

    /// 模糊匹配：空格分词，每段都要在标识里出现（顺序不限）。
    /// 不做编辑距离那种「差不多」匹配 —— 价格表里前缀高度相似的标识太多（各种日期与档位后缀），
    /// 相似度匹配会把真正要找的那条淹掉。
    private var matches: [String] {
        let keys = pricing.remote.keys.sorted()
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return keys }
        return keys.filter { key in
            let lower = key.lowercased()
            return terms.allSatisfy { lower.contains($0) }
        }
    }

    private func pager(pageCount: Int, current: Int) -> some View {
        HStack(spacing: 6) {
            Button("上一页") { page = max(0, current - 1) }
                .controlSize(.small).disabled(current == 0)
            Button("下一页") { page = min(pageCount - 1, current + 1) }
                .controlSize(.small).disabled(current >= pageCount - 1)
        }
    }

    // MARK: 表格

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("模型标识").frame(maxWidth: .infinity, alignment: .leading)
            Text("输入").frame(width: 66, alignment: .trailing)
            Text("缓存读").frame(width: 66, alignment: .trailing)
            Text("缓存写").frame(width: 66, alignment: .trailing)
            Text("输出").frame(width: 66, alignment: .trailing)
            Text("").frame(width: 46)
        }
        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.gray500)
        .padding(.horizontal, 8)
    }

    private func row(_ key: String) -> some View {
        let p = pricing.remote[key]
        let overridden = pricing.override(for: key) != nil
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                // 手动单价覆盖了这条表价，行上要看得出来，不然会以为改价没生效
                if overridden {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 9.5)).foregroundStyle(Theme.primary)
                        .help("这条已被手动单价覆盖")
                }
                Text(key)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.gray800)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            priceCell(p?.input); priceCell(p?.cacheRead); priceCell(p?.cacheWrite); priceCell(p?.output)
            Group {
                if let p {
                    Button("覆盖") { onOverride(key, p) }
                        .controlSize(.mini).help("把这条价格填进下方的手动单价表单")
                }
            }
            .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: Self.rowHeight)
    }

    private func priceCell(_ v: Double?) -> some View {
        Text(PricingService.formatPerMillion(v))
            .font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.gray700).monospacedDigit()
            .frame(width: 66, alignment: .trailing)
    }
}
