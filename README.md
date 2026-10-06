# AI Usage · AI 用量统计

原生 macOS 菜单栏小工具：读取本机各个 AI 编程助手留下的会话日志，统计 token 用量与估算费用 —— 一份跨工具、跨设备、能长期保留的账。

[English](README.en.md) · **简体中文**

> 界面目前只有简体中文。

![AI Usage 主界面](docs/images/main-light.png)

## 名字与图标

App 叫 **AI Usage**，中文写作「AI 用量统计」—— 菜单栏上放不下副题，那里显示的是你自己挑的那几个数
（默认是今日费用）。

图标是三根从左到右递增的圆角柱子，每根顶上一颗四角星，蓝色由浅到深：最右边那根正是界面里的强调色
`#5D87FF`，往左依次调浅。其余几张界面图在 [`docs/images/`](docs/images/)。

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

三个维度各一张，另有深色与几个浮层，都在 [`docs/images/`](docs/images/)：

| 按模型 | 按日期 | 深色 |
|---|---|---|
| [![按模型维度](docs/images/main-model.png)](docs/images/main-model.png) | [![按日期维度](docs/images/main-day.png)](docs/images/main-day.png) | [![深色](docs/images/main-dark.png)](docs/images/main-dark.png) |

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

设置 → 数据源 把这张表原样列出来：每个工具能拿到什么口径（token 明细 / 仅会话 / 不可读）、
扫的是哪个目录，都能逐条改。

![设置 · 数据源](docs/images/settings-sources.png)

## 技术方案

**形态。** 纯 SwiftUI，只有 `Form` / `TextEditor` 这类控件由 AppKit 承载；**零第三方依赖** ——
图表是 Swift Charts，读 SQLite 直接走系统的 `SQLite3` 模块（只读打开，WAL 库并发读），
没有 SPM 包、没有 CocoaPods / Carthage。工程由 XcodeGen 从 `project.yml` 生成，
产物是 arm64 + x86_64 通用二进制。

**读法。** JSONL 逐行流式解析，只挑带用量标记的行；SQLite 只读，按 `row_id` 增量扫；
本地加密的（Windsurf / Antigravity / TRAE）不尝试解密 —— 能数会话的只报会话，读不出的如实标注，
**不猜、不按 0 计**。

**口径。** 四个 token 桶（未缓存输入 / 缓存读 / 缓存写 / 输出）统一成一个 `processed`，
各家按各自的去重键去重（Claude Code 用 `message.id + requestId`，Codex 认 `token_count`
且连续重复只算一次，Devin 用 `message_id`）—— 明细在「支持的数据源」那张表里。

**跨设备。** 不走 CloudKit（要付费账号，还会破坏 ad-hoc 签名），直接读写 iCloud Drive 里的 JSON 档案。
档案里只有「日 × 环境 × 模型」的四桶 token 与会话数，**不传费用、不传会话 id**：
费用对四个桶是线性的，展示端用本机当时那张价格表重算，与逐条计算完全等价 ——
所以换价之后历史消费跟着重算，而不是留下一堆用旧价算死的数字。

**价格。** LiteLLM 公共价格表，匹配先精确后模糊（去掉日期后缀、去掉 `-medium` 这类档位后缀），
手动补价优先于表里的值，查不到的显示 `Unpriced` 而不是 `$0.00`。

**工程。** 解析结果按 `(path, size, mtime)` 缓存，刷新只重解析变过的文件；
界面上的每个数都有一个机器可读的出口（`--dump` / `--menu` / `--retention` / `--export`），
排版有一组离屏快照核对（`--render`），口径有一份 174 条断言的自测（`--selftest`）。

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

需要 macOS 14+。发布的是通用二进制，Apple Silicon 与 Intel 都能跑。

### 下载

到 [Releases](https://github.com/zhengshangjinx/ai-tools-usage/releases) 下载
`AiToolsUsage-<版本>-macos-universal.zip`，解压后把 `AI Usage.app` 拖进「应用程序」。

App 是 ad-hoc 签名、未做公证，首次打开会被 Gatekeeper 拦下（提示「已损坏」或「无法验证开发者」）。
**用右键 →「打开」**，或者直接摘掉隔离属性：

```bash
xattr -dr com.apple.quarantine "/Applications/AI Usage.app"
```

> 之所以没买开发者账号公证：这个工具要读的是你自己机器上各家 AI 工具的数据目录，
> 花钱买证书并不会让它更可信 —— 介意的话请走下面的源码构建，自己编一个。

### 从源码构建

需要 Xcode 命令行工具。

```bash
brew install xcodegen          # 本项目用 XcodeGen 管理工程
git clone https://github.com/zhengshangjinx/ai-tools-usage.git && cd ai-tools-usage
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

自己编出来的这份和 Releases 里那份是同一条构建路径，所以也一样是 ad-hoc 签名。

## 菜单栏

菜单栏常驻一段紧凑文字（默认今日费用），点开是一个富面板：**按「今日 / 本月」分两段**的费用、Tokens、请求数，
加近 7 天的迷你柱与页脚三个动作（打开主窗口 / 立即刷新 / 退出）。显示哪几项、面板里放哪几项，
都在 设置 → 显示与留存 → 菜单栏 里改（写 `menubar.config.v1`）。

![菜单栏面板](docs/images/menubar-panel.png)

两段分开是因为窗口不同 —— 六行同质的数排在一起，读者会以为它们是同一个时间窗里的六个指标。

面板读的是**固定窗口**（今日 / 本月），不跟随主窗口选的日期范围 ——
在主窗口选「近 90 天」不会让菜单栏跟着变。

关掉「在菜单栏显示」只是不显示图标。**Dock 图标是另一套逻辑**：屏幕上没有真窗口时 App 会退成纯状态栏
（Dock 图标与菜单栏一起收掉），再从菜单栏面板打开窗口时临时出现；设置里有「关闭主窗口后保留在菜单栏」，
关掉它就变成关窗即退出。仍然**没有**开 `LSUIElement` ——
本 App 启动就有窗口（出生即 `.regular`），「纯状态栏」只在关掉最后一个窗口之后出现，那是运行期切换的活，
静态声明只会让启动多一次翻转还搭上两个已知坑，理由写在 `ActivationPolicyController` 开头。

一个残余风险，如实写在这里：macOS 26 起用户可以在「系统设置 → 菜单栏」里关掉本 App 的图标，
而本 App 只能读自己的配置、读不到系统那一侧的状态，会误判成「可以退成纯状态栏」。
这时从「应用程序」里重新打开一次即可（走 `applicationShouldHandleReopen`）。
另外，如果同时关掉菜单栏图标、又保留「关窗不退出」，App 会变成没有任何入口 —— 这一格刻意不让它退成纯状态栏，
Dock 图标会保留，设置页里也有对应的橙色提示。

## 价格

启动时从 [LiteLLM](https://github.com/BerriAI/litellm) 拉取单价并缓存到 `~/Library/Application Support/AIUsage/`
（6 小时内不重复拉取）。匹配不到的模型显示 `Unpriced`，可在 设置 → **模型单价** 手动补价（$ / 1M tokens），手动价格优先。

费用**不落盘、只存 token**：档案里记的是四个 token 分量，金额每次展示时按当时那张价格表算。
所以导出文件里带上了价格表版本（`pricing.lastUpdated`）—— 换过价之后，只有对上版本号才解释得清差额。

模型详情里能看到这一行单价是从哪来的（表里命中 / 手动设的），以及四个桶各占多少 ——
缓存读那一行通常占九成，它的单价只有输入价的十分之一，省下的钱也写在那里。

![模型详情](docs/images/model-detail.png)

## 数据留存

**Claude Code 默认只保留 30 天本地日志**（`cleanupPeriodDays`，本机实测未设置）。本 App 的 iCloud 档案
不受这把砍刀影响 —— 档案里那些天，本机日志可能早就没了。

设置 → 显示与留存 会把这个对照按环境列出来（本机日志 X 天 / 档案 Y 天 / 只在档案里 N 天），
并给出建议值 `370` 与一段可复制的 JSON 片段 —— **App 不替你改 `~/.claude/settings.json`**（那个文件里有凭据，
我们只读 `cleanupPeriodDays` 这一个键，也绝不写回）。

一句诚实的说明：**档案只覆盖它已经开始观测之后的日子**。在装这个 App 之前就被清掉的日志，找不回来。
设置页把两件事都写在明面上：上面是现状与建议，下面是按环境的对照表（右边那列绿字就是只在档案里的天数）。

![设置 · 显示与留存](docs/images/settings-display.png)

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

界面上的每个数都有一个机器可读的出口。这些参数都**先真扫一遍本机日志**（跟界面同一份数据），打印完 `exit(0)`；
加上 `--demo` 就改成读内存里编好的演示数据（见下表）。

```bash
APP="build/Build/Products/Release/AI Usage.app/Contents/MacOS/AI Usage"

"$APP" --dump 7            # 最近 7 天的汇总（天数必须是裸整数，见下）
"$APP" --menu              # 菜单栏面板那几个数：今日 / 本月 / 近 7 天
"$APP" --retention         # 留存对照：本机日志 vs iCloud 档案的覆盖天数、cleanupPeriodDays
"$APP" --selftest          # 解析 / 聚合 / 跨设备 schema / 导出 / 留存的自测，全过退出码 0
"$APP" --render /tmp/r     # 主界面、设置页、菜单面板，浅色深色各一张 PNG
"$APP" --bench             # 整页光栅化几遍，报中位数
"$APP" --export /tmp/x csv model   # 导出，不点界面（省略格式与维度就出 3×3 共 9 个文件）

"$APP" --render /tmp/r --demo      # 换成编好的演示数据，README 里那几张图就是这么出的
```

| 参数 | 作用 |
|---|---|
| `--dump [天数]` | 打印汇总，默认 90 天。**天数写裸整数**：`--dump 7`。写成 `--dump "7 days"` 不报错但**不生效** —— 解析用的是 `Int($0)`，解析不出来就一声不响地退回 90 天 |
| `--menu` | 菜单栏摘要（固定窗口：今日 / 本月 / 近 7 天），末尾另打一行 `label:` —— 那是菜单栏上**真正显示的那行字**（由你的配置拼出来）。数字对得上不等于那行字对：「今日 $ $16.86」这种拼写毛病只有把拼好的串打出来才看得见 |
| `--retention` | 留存对照表。只打印 `cleanupPeriodDays` 这**一个**值，不碰 `~/.claude/settings.json` 里的其它内容 |
| `--selftest` | 174 条断言，失败退出码非 0 |
| `--render <目录>` | 离屏快照（`TextEditor` / `Form` / `Menu` 这类 AppKit 承载的视图走真实 `NSWindow` 抓图，见 `RenderHarness.captureWindow`；高度由内容决定的视图自己量，见 `captureFitting`） |
| `--bench` | 主界面光栅化耗时中位数 |
| `--export <目录> [csv\|tsv\|json] [device\|model\|day]` | 按维度导出三种格式，逐字节可核对 |
| `--demo` | 演示模式，**加在上面某个参数后面**。数据换成编好的（`AIUsage/Demo/DemoData.swift`，一个固定种子的 xorshift，所以每次跑出来一样），同时关掉一切落盘与联网：配置域换成一次性的 suite、计价不联网、扫描读内存里的合成档案、iCloud 目录指向一条假路径。它不保证「不碰真实配置域」——出图会把窗口真的建起来，**AppKit 自己**会往真实域里写窗口尺寸，退出时按原值还回去（见 `DemoRuntime` 的文件头）。`scripts/shoot.sh` 出图前后各导一次配置域做比对，内容不一致就直接失败 |

`--selftest` 的红线：**绝不碰 `ScanCache.shared`**（它读写并会清理 `~/Library/Application Support/AIUsage/`
下的缓存文件），**绝不写 `UserDefaults.standard`，也绝不写用户配置所在的任何域**。解析用例全部用临时目录里的合成 fixture，
跑完自删，且不联网（价格直接注入固定值）。需要验读写的设置项（关窗行为那一组）走**一次性 suite**
（`UserDefaults(suiteName: "aiusage.selftest.<UUID>")`，跑完连域带壳一起删掉），与 App 的配置域没有关系 ——
跑自测前后 `defaults read com.local.aiusage` 应当逐字节一致。

## 缓存

解析结果按文件 (path, size, mtime) 缓存在 `~/Library/Application Support/AIUsage/scan_cache_v3.json`，
首次全量扫描约十几秒，之后刷新只解析变化过的文件。设置 → 数据源 里有「清除缓存并重扫」。

## 项目结构

```
AIUsage/
├── App.swift                  App 入口、三个 scene、离屏渲染工装（--render / --bench）
├── SelfTest.swift             --selftest 的全部断言
├── Demo/                      --demo 的合成数据与演示模式开关
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
├── shoot.sh                   出 README 用的那几张截图（--render --demo）
├── export.sh                  可选的打包导出（默认跳过）
└── export-dir.local           本机导出目录（不进仓库）
docs/images/                   README 里的截图，怎么重拍见目录里的 README
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
