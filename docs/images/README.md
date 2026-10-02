# 界面截图

README 里的截图都放在这个目录，跟着仓库一起提交（README 在 GitHub 上要能直接显示）。
界面改了要照着重拍时走 `scripts/shoot.sh`：

```bash
xcodegen generate && ./scripts/build.sh
./scripts/shoot.sh
```

它会带着 `--demo` 跑一遍出图工装（`--render <临时目录>`），再把 README 要用的那几张按下面的
名字拷进这个目录。工装本身会产出二十多张——三种维度、最小窗口宽度、几个浮层、深浅两套——
**只有这个目录里列出来的这几张会进仓库**，其余留在临时目录里。

| 文件 | 拍的是什么 | 工装输出的那一张 |
| --- | --- | --- |
| `main-light.png` | 主界面，默认的「按设备」维度。跨设备合并、环比、折线、环形、明细表都在这一屏 | `main-light.png` |
| `main-dark.png` | 同一屏的深色 | `main-dark.png` |
| `main-model.png` | 「按模型」维度。明细表第一列换成模型名，未计价的模型在这一列里露出来 | `main-light-model.png` |
| `main-day.png` | 「按日期」维度 | `main-light-day.png` |
| `settings-sources.png` | 设置 · 数据源：每个工具能不能拿到 token 明细、默认扫哪里 | `settings-sources-light.png` |
| `settings-display.png` | 设置 · 显示与留存：`cleanupPeriodDays` 现状与建议，下面是对照表 | `settings-display-light.png` |
| `menubar-panel.png` | 菜单栏点开的那块面板 | `menubar-panel-light.png` |
| `model-detail.png` | 模型详情：单价来自哪里、四个 token 桶各占多少、缓存读省了多少 | `model-detail-light.png` |

浅色和深色两套的排版完全一样，所以除了头图那一对，其余只提交浅色那张——两套都留会让这个
目录大一倍，而要核对的东西一张就已经在里面了。设置页用 680×620（设置窗口的默认尺寸），
主界面按 1520（`WindowFrameKeeper.designSize`）。

## 演示数据

截图里的每一个数、每一个名字、每一条路径都是编出来的：`AIUsage/Demo/DemoData.swift` 里
一个 xorshift 种子铺出两百来天的合成记录，走的是和真实扫描完全相同的聚合与合并代码——
数据是假的，算账的代码一行没换，所以图上每个数字都是真算出来的，包括「未计价」那一行和
明细表里的请求数下界。

演示模式还负责一件事：**出图不能碰到用户自己的东西**。`--demo` 时配置域换成一次性 suite、
计价不联网、扫描读内存里的假档案、共享目录指向一条假路径，退出时把 AppKit 自己写进去的
窗口尺寸按原值还回去。`scripts/shoot.sh` 会在出图前后各导一次真实配置域做比对，
内容不一致就直接失败——这条断言写在脚本里，不指望每次出图的人记得手动核。

细节（哪几个键拦不住、为什么拦不住）在 `AIUsage/Demo/DemoRuntime.swift` 的文件头。

## 发之前先看一眼

截图是提交进仓库的产物，图里不该出现本机用户名、真实设备名或真实金额。演示数据是编的，
但顺手扫一眼总是便宜的：

```bash
# 演示数据里的路径一律写成 /Users/you/...，扫出别的就是漏改了
grep -rnoE "/Users/[A-Za-z0-9._-]+" AIUsage/Demo/ AIUsage/Models/UsageRecord.swift | grep -v "/Users/you" | sort -u

# 设备名只有这两个，都以「演示用」开头
grep -rhoE '演示用 [A-Za-z]+( [A-Za-z]+)?' AIUsage/Demo/ | sort -u

# 文档里不该出现作者本人的机器名或账号
grep -rn "zhengshangjin" README.md README.en.md docs/ scripts/
```

更直接的一条：把 `docs/images/` 里的图逐张打开看一眼。八张而已，看得完——图上出现一个
你认得的项目路径或者一位真实金额，说明演示数据又漏了一处。
