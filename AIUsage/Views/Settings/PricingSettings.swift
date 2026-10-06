import SwiftUI

/// 模型单价。LiteLLM 价格表的状态、手动补价、以及全表浏览。
struct PricingSettings: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var pricing: PricingService

    @State private var newModel = ""
    @State private var newInput = ""
    @State private var newCacheRead = ""
    @State private var newCacheWrite = ""
    @State private var newOutput = ""

    var body: some View {
        SettingsDetailPage(SettingsPane.pricing.title, subtitle: SettingsPane.pricing.subtitle) {
            SettingsHeaderAction(title: "刷新", busy: pricing.isRefreshing) {
                Task { await pricing.refresh() }
            }
        } content: {
            SettingsScroll {
                tableCard
                overridesCard
                if !store.snapshot.unpricedModels.isEmpty { unpricedCard }
                browserCard
            }
        }
    }

    private var tableCard: some View {
        SettingsCard("LiteLLM 价格表") {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已加载 \(pricing.remote.count) 个模型").font(.system(size: 12))
                    SettingsNote(pricing.lastUpdated.map { "更新于 \(Formatters.stamp($0))" } ?? "尚未拉取")
                    if let err = pricing.lastError {
                        SettingsNote(err, error: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var overridesCard: some View {
        SettingsCard("手动单价（美元 / 百万 tokens）",
                     footer: "手动单价优先于 LiteLLM；缓存字段留空则按输入单价计费。") {
            if pricing.overrides.isEmpty {
                SettingsNote("暂无手动单价。")
            }
            ForEach(pricing.overrides.keys.sorted(), id: \.self) { model in
                if let p = pricing.overrides[model] {
                    HStack(spacing: 8) {
                        Text(model).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        priceTag("输入", p.input); priceTag("缓存读", p.cacheRead)
                        priceTag("缓存写", p.cacheWrite); priceTag("输出", p.output)
                        SettingsIconButton(systemName: "trash", help: "删掉这条手动单价",
                                           destructive: true) {
                            pricing.overrides.removeValue(forKey: model)
                        }
                    }
                }
            }
            if !pricing.overrides.isEmpty { SettingsRule() }
            addRow
        }
    }

    private var unpricedCard: some View {
        SettingsCard("当前范围内未计价的模型") {
            ForEach(store.snapshot.unpricedModels, id: \.self) { m in
                HStack(spacing: 8) {
                    Text(m).font(.system(size: 12, design: .monospaced))
                    Spacer(minLength: 8)
                    Button("设置单价") { newModel = m }.settingsButton()
                }
            }
        }
    }

    private var browserCard: some View {
        SettingsCard("全部单价",
                     footer: "拉下来的价格表有三千多条，翻是翻不完的 —— 用搜索定位。行尾「覆盖」会把这条价格填进上面的手动单价表单，改完点「添加」生效。") {
            PricingBrowser { model, price in
                newModel = model
                newInput = ModelPrice.perMillionText(price.input)
                newOutput = ModelPrice.perMillionText(price.output)
                newCacheRead = price.cacheRead.map(ModelPrice.perMillionText) ?? ""
                newCacheWrite = price.cacheWrite.map(ModelPrice.perMillionText) ?? ""
            }
        }
    }

    private func priceTag(_ label: String, _ v: Double?) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.gray500)
            Text(PricingService.formatPerMillion(v)).font(.system(size: 11, design: .rounded)).monospacedDigit()
        }
        .frame(width: 58)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsTextField("模型标识（精确匹配，如 gpt-5.6-sol）", text: $newModel, monospaced: true)
            HStack(alignment: .bottom, spacing: 8) {
                SettingsNumberField(label: "输入", text: $newInput)
                // 缓存那两栏留空是按输入价算的，用 placeholder 直接说出来，
                // 省得用户回去读卡片底下那行说明
                SettingsNumberField(label: "缓存读", text: $newCacheRead, placeholder: "同输入")
                SettingsNumberField(label: "缓存写", text: $newCacheWrite, placeholder: "同输入")
                SettingsNumberField(label: "输出", text: $newOutput)
                Button("添加") { add() }
                    .settingsButton(.primary)
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty || Double(newInput) == nil || Double(newOutput) == nil)
                Spacer(minLength: 0)
            }
        }
    }

    private func add() {
        guard let i = Double(newInput), let o = Double(newOutput) else { return }
        pricing.overrides[newModel.trimmingCharacters(in: .whitespaces)] = ModelPrice.perMillion(
            input: i, output: o,
            cacheRead: Double(newCacheRead), cacheWrite: Double(newCacheWrite)
        )
        newModel = ""; newInput = ""; newCacheRead = ""; newCacheWrite = ""; newOutput = ""
    }
}
