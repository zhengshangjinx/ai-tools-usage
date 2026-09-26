# AI Usage · AI 用量统计

原生 macOS 菜单栏小工具：读取本机各个 AI 编程助手留下的会话日志，统计 token 用量与估算费用 —— 一份跨工具、跨设备、能长期保留的账。

[English](README.en.md) · **简体中文**

> 界面目前只有简体中文。

这里**没有放界面截图**：出图工装（`--render`）读的是本机真实日志，截出来就是自己的设备名、真实消费额和本机路径。
想看界面，按下面的「从源码构建」跑起来 —— 或者直接跑 `--render <目录>` 出一套图（浅色 / 深色各一张）。

---

## 为什么要做这个

同时用着 Claude Code、Codex、Cursor、Devin、Qoder 这些工具的时候，「这个月到底花了多少」没有一个地方能回答：
用量散在各家自己的目录里，格式各不相同，而且多数只给你看最近 30 天 ——
Claude Code 默认保留 30 天本地日志，过了就没了。

这个 App 把这些散落的日志收拢起来，解决三件事：

1. **一次看完所有工具**，而不是开五个页面各查一遍。
2. **本机日志被清掉之后账还在。** 每天的汇总写进 iCloud 档案，实测本机：codex 本机日志 38 天、档案 85 天，
   中间 47 天只剩档案里有。
3. **费用不落盘、只存 token。** 档案里记的是四个 token 分量，金额每次展示时按当时那张价格表算 ——
   所以换过价之后，历史消费会跟着重算，而不是留下一堆用旧价算死的历史数字。

## 功能

| 功能 | 说明 |
|---|---|
| **10 个数据源** | Claude Code、Codex（Desktop / IDE / CLI）、Devin、Cursor、Qoder、CodeBuddy、Windsurf、Antigravity、TRAE |
| **三种汇总维度** | 按设备 / 按模型 / 按日期，可排序，明细表与图表联动 |
| **费用估算** | 自动拉 LiteLLM 价格表计价；匹配不到的显示 `Unpriced`，可在设置里手动补价 |
| **菜单栏常驻** | 图标旁显示今日/本月费用、token、请求数，点开是带近 7 天迷你柱的面板 |
| **多设备同步** | 通过 iCloud Drive 交换每日汇总档案，不依赖任何服务器 |
| **导出** | 当前筛选结果导出 CSV / TSV / JSON，带完整口径元信息 |
| **留存对照** | 按环境列出「本机日志还剩多少天 / 档案有多少天 / 只在档案里多少天」 |

## 支持的数据源

| 环境 | 本地数据 | 统计方式 |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl`（含 `subagents/`） | `assistant` 消息的 `message.usage`，按 `message.id + requestId` 去重 |
| Codex（Desktop / IDE） | `~/.codex/sessions/**/rollout-*.jsonl`、`~/.codex/archived_sessions/` | 每条 `token_count` 事件的 `last_token_usage`，连续重复只算一次；fork / 子代理文件开头 1 秒内成批复制的父线程历史事件全部丢弃（与 T3 Code / ccusage 口径一致）；模型取自 `turn_context` |
| Codex CLI | 同上，按 `session_meta.originator` 区分 | 同上 |
| Devin（Desktop / CLI） | `~/.local/share/devin/cli/sessions.db`（SQLite, WAL） | `message_nodes.chat_message.metadata.metrics`，按 `message_id` 去重，按 `row_id` 增量扫描 |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `cursorDiskKV` 的 `bubbleId:*` 行（type 2）`tokenCount.inputTokens/outputTokens`，不区分缓存 |
| Qoder IDE | `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`、`~/.qoder/shared_client/…` | `chat_message.token_info`（prompt/completion/cached），模型多为 auto 路由档 → 未计价 |
| CodeBuddy Code | `~/.codebuddy/projects/**/*.jsonl` | 与 Claude Code 同格式 |
| Windsurf | `~/.codeium/windsurf/cascade/*.pb` | **本地加密**（熵 8.0），仅统计会话数与活跃日期 |
| Antigravity | `~/.gemini/antigravity*/conversations/*.pb` | **本地加密**，仅统计会话数与活跃日期 |
| TRAE | `~/Library/Application Support/Trae*/ModularData/ai-agent/database.db` | **SQLCipher 加密**（密钥仅存进程内存），暂无法读取，仅保留数据源占位 |

读不到的环境如实标注「加密」或「未检测到」，**不猜、不按 0 计**。

token 口径统一为：

```
processed = uncached input + cache read + cache write + output
```

（OpenAI 的 `input_tokens` 含 cached，已自动扣除。）

## 隐私

这个 App 读的是你本机上别人写的日志文件，所以有必要说清楚它到底做了什么：

- **所有数据都在本机。** 没有账号、没有遥测、没有上传。解析结果缓存在 `~/Library/Application Support/AIUsage/`。
- **全项目只有一个对外网络请求**：启动时拉一次
  [LiteLLM 的 `model_prices_and_context_window.json`](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)
  用来计价（6 小时内不重复拉）。可以在断网环境下用，只是价格表用缓存。
- **不读任何凭据。** 留存功能会看 `~/.claude/settings.json`，但**只读 `cleanupPeriodDays` 这一个键**，
  用 `JSONSerialization` 取出来就完事 —— 那个文件里有 `ANTHROPIC_AUTH_TOKEN` 之类的凭据，
  本 App **不碰、不打印、不记录、更不写回**。
- **App 未开沙盒**（`com.apple.security.app-sandbox = false`）—— 因为要读上面那张表里各家的数据目录。
  这也是它没上架 App Store 的原因。
- **同步是文件级的。** 多设备同步走你自己的 iCloud Drive 目录，交换的是每日汇总档案
  （`device-<deviceId>.json`，只含 token 分量与会话数）。档案里**不含**会话 id、不含 prompt 内容、不含费用。
- 加密读不了的数据源（Windsurf / Antigravity / TRAE），本 App 不做解密、不尝试绕过。

## 安装

### 从源码构建

目前只提供源码构建。需要 macOS 14+ 与 Xcode 命令行工具。

```bash
brew install xcodegen          # 本项目用 XcodeGen 管理工程
git clone <this-repo> && cd ai-tools-usage
xcodegen generate              # 必须先跑一次，见下
./scripts/build.sh             # Release 通用二进制（arm64 + x86_64）
```

产物在 `build/Build/Products/Release/AI Usage.app`，拖进「应用程序」即可。

> **`xcodegen generate` 不能省。** `AIUsage.xcodeproj/` 和 `AIUsage/Info.plist` 都是
> `project.yml` 生成的产物，没有进仓库（这样每次增删 Swift 文件不会在 `project.pbxproj` 里
> 产生几百行没法 review 的 diff）。clone 下来直接打开工程会失败。

想在 Xcode 里开发：

```bash
xcodegen generate && open AIUsage.xcodeproj
```

新增 Swift 文件之后要重新跑一次 `xcodegen generate`。

> **导出是可选的。** `scripts/build.sh` 走 scheme 构建，scheme 上挂了一个 build post-action
> 调 `scripts/export.sh` 打包产物到指定目录。它**默认什么都不做**，要开的话任选一种：
> `AIUSAGE_EXPORT_DIR="/path/to/dir" ./scripts/build.sh`，或者把目录写进
> `scripts/export-dir.local`（该文件在 `.gitignore` 里）。

App 是 ad-hoc 签名、未做公证，首次打开需要右键 →「打开」。

## 菜单栏

菜单栏常驻一段紧凑文字（默认今日费用），点开是一个富面板：**按「今日 / 本月」分两段**的费用、Tokens、请求数，
加近 7 天的迷你柱与页脚三个动作（打开主窗口 / 立即刷新 / 退出）。显示哪几项、面板里放哪几项，
都在 设置 → 显示与留存 → 菜单栏 里改（写 `menubar.config.v1`）。

两段分开是因为窗口不同 —— 六行同质的数排在一起，读者会以为它们是同一个时间窗里的六个指标。

面板读的是**固定窗口**（今日 / 本月），不跟随主窗口选的日期范围 ——
在主窗口选「近 90 天」不会让菜单栏跟着变。关掉开关只是不显示图标，主窗口与 Dock 图标照旧（**不是** `LSUIElement`）。

## 价格

启动时从 [LiteLLM](https://github.com/BerriAI/litellm) 拉取单价并缓存到 `~/Library/Application Support/AIUsage/`
（6 小时内不重复拉取）。匹配不到的模型显示 `Unpriced`，可在 设置 → **模型单价** 手动补价（$ / 1M tokens），手动价格优先。

费用**不落盘、只存 token**：档案里记的是四个 token 分量，金额每次展示时按当时那张价格表算。
所以导出文件里带上了价格表版本（`pricing.lastUpdated`）—— 换过价之后，只有对上版本号才解释得清差额。

## 数据留存

**Claude Code 默认只保留 30 天本地日志**（`cleanupPeriodDays`，本机实测未设置）。本 App 的 iCloud 档案
不受这把砍刀影响 —— 档案里那些天，本机日志可能早就没了。

设置 → 显示与留存 会把这个对照按环境列出来（本机日志 X 天 / 档案 Y 天 / 只在档案里 N 天），
并给出建议值 `370` 与一段可复制的 JSON 片段 —— **App 不替你改 `~/.claude/settings.json`**（那个文件里有凭据，
我们只读 `cleanupPeriodDays` 这一个键，也绝不写回）。

一句诚实的说明：**档案只覆盖它已经开始观测之后的日子**。在装这个 App 之前就被清掉的日志，找不回来。

## 导出

主界面筛选区最右边那个「导出」按钮（`square.and.arrow.up`）把**当前筛选结果**存成文件，
CSV / TSV / JSON 三种。导出的就是屏幕上那份表：同样的行、同样的顺序、同样的占比口径，
行取 `UsageStore.visibleRows`，与表格共用同一个来源。

- CSV / TSV 带 UTF-8 BOM、CRLF 行尾、RFC 4180 转义 —— 否则 Excel 打开 `claude-sonnet-5（日常使用）` 这类中文列是乱码。
- 数字一律原始值，日期用 ASCII 的 `yyyy-MM-dd`，**不用界面上那套**（`Formatters.tokens` 会变成 `12.4M`，给人看的不能给机器读）。
- `null` ≠ `0`：量不到的请求数留空（另用 `requests_partial` 表达「这是下界」），未计价的费用留空（`cost_partial=true`），
  分量不全时如实报 `unclassified_tokens`，**绝不猜成 input**。
- JSON 额外带 `meta`（导出时间、App 版本、维度、日期范围、筛选、排序、**价格表版本**）与每行的 `tokens_components`、单价 `prices`。
- 只写你选的那个路径，不自动往 iCloud 同步目录里写（那是设备档案的地盘）。

## 命令行核对

界面上的每个数都有一个机器可读的出口。这些参数都**先真扫一遍本机日志**（跟界面同一份数据），打印完 `exit(0)`：

```bash
APP="build/Build/Products/Release/AI Usage.app/Contents/MacOS/AI Usage"

"$APP" --dump 7            # 最近 7 天的汇总（天数必须是裸整数，见下）
"$APP" --menu              # 菜单栏面板那几个数：今日 / 本月 / 近 7 天
"$APP" --retention         # 留存对照：本机日志 vs iCloud 档案的覆盖天数、cleanupPeriodDays
"$APP" --selftest          # 解析 / 聚合 / 跨设备 schema / 导出 / 留存的自测，全过退出码 0
"$APP" --render /tmp/r     # 主界面、设置页、菜单面板，浅色深色各一张 PNG
"$APP" --bench             # 整页光栅化几遍，报中位数
"$APP" --export /tmp/x csv model   # 导出，不点界面（省略格式与维度就出 3×3 共 9 个文件）
```

| 参数 | 作用 |
|---|---|
| `--dump [天数]` | 打印汇总，默认 90 天。**天数写裸整数**：`--dump 7`。写成 `--dump "7 days"` 不报错但**不生效** —— 解析用的是 `Int($0)`，解析不出来就一声不响地退回 90 天 |
| `--menu` | 菜单栏摘要（固定窗口：今日 / 本月 / 近 7 天），末尾另打一行 `label:` —— 那是菜单栏上**真正显示的那行字**（由你的配置拼出来）。数字对得上不等于那行字对：「今日 $ $16.86」这种拼写毛病只有把拼好的串打出来才看得见 |
| `--retention` | 留存对照表。只打印 `cleanupPeriodDays` 这**一个**值，不碰 `~/.claude/settings.json` 里的其它内容 |
| `--selftest` | 156 条断言，失败退出码非 0 |
| `--render <目录>` | 离屏快照（`TextEditor` / `Form` / `Menu` 这类 AppKit 承载的视图走真实 `NSWindow` 抓图，见 `RenderHarness.captureWindow`；高度由内容决定的视图自己量，见 `captureFitting`） |
| `--bench` | 主界面光栅化耗时中位数 |
| `--export <目录> [csv\|tsv\|json] [device\|model\|day]` | 按维度导出三种格式，逐字节可核对 |

`--selftest` 的红线：**绝不碰 `ScanCache.shared`**（它读写并会清理 `~/Library/Application Support/AIUsage/`
下的缓存文件），也绝不写 `UserDefaults`。解析用例全部用临时目录里的合成 fixture，跑完自删，且不联网
（价格直接注入固定值）。

## 缓存

解析结果按文件 (path, size, mtime) 缓存在 `~/Library/Application Support/AIUsage/scan_cache_v3.json`，
首次全量扫描约十几秒，之后刷新只解析变化过的文件。设置 → 数据源 里有「清除缓存并重扫」。

## 项目结构

```
AIUsage/
├── App.swift                  App 入口、三个 scene、离屏渲染工装（--render / --bench）
├── SelfTest.swift             --selftest 的全部断言
├── Providers/                 各数据源的解析器 + 扫描缓存 + SQLite 读取
├── Store/UsageStore.swift     聚合、筛选、排序的唯一真相
├── Pricing/                   LiteLLM 价格表、手动补价
├── Sync/DeviceSync.swift      iCloud 档案的读写与合并
├── Retention/                 留存对照
├── Export/                    CSV / TSV / JSON 导出
├── MenuBar/                   菜单栏配置与面板
├── Views/                     主界面与组件
└── Util/                      格式化、主题令牌
scripts/
├── build.sh                   一键 Release 通用二进制
├── export.sh                  可选的打包导出（默认跳过）
└── export-dir.local           本机导出目录（不进仓库）
project.yml                    工程配置的唯一事实来源（XcodeGen）
```

## 已知限制

- **界面只有简体中文**，没有做本地化。
- **Windsurf / Antigravity / TRAE 读不到 token**：本地是加密的，只统计会话数与活跃日期。
- **费用是估算**，按 LiteLLM 的公共价格表算，不包含订阅制、额度包、企业折扣。
- **多设备同步是「各写各的档案」**，没有冲突解决 —— 同一台设备换 id 会导致两份档案并存。
  设计上设备之间会话天然不相交，所以按天相加是对的。
- **只在 macOS 14+ 上测过**，Intel 机器有通用二进制但没实机验证。

## 许可

[MIT](LICENSE) © 2026 zhengshangjinx

价格数据来自 [LiteLLM](https://github.com/BerriAI/litellm)（MIT）。
本项目与 Anthropic、OpenAI、Cursor、Devin 等任何 AI 厂商均无关联，也未获其授权或背书。
