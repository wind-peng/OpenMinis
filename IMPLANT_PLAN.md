# OpenMinis 植入 PhoneAgent「眼 + 手」实施方案

> 调查日期：2026-11-10。只读调查，未改 fork、未推送、未启动任何构建。
> 目标手机：iPhone 13 / iOS 16.1 / TrollStore（永不升级系统）。
> 用户 fork：`wind-peng/OpenMinis`（public，GPL-3.0，默认分支 main）。

> ## 更新（2026-11-10 晚）：Linux 沙箱已剥离
> 用户决定不要 Linux 沙箱（iSH/Alpine），要更小的文件和更快的构建。植入时一并执行了剥离，本文其余部分仍描述剥离前的调查结论（沙箱相关的段落不再适用）：
> - **删掉的构建**：LAME、FFmpeg、iSH 内核、Alpine rootfs（`.github/workflows/build-tipa.yml` 不再编它们；只有 rclone 还在编，因为它是 Backup 功能的 Go 库，与沙箱无关）。
> - **删掉的 Agent 工具**：`shell_execute`、`file_read`、`file_write`、`file_edit`（注册、执行、提示词、开关引用全部移除；系统提示词已重写为“无 shell、无文件工具”版本）。保留：`browser_use`、`phone_screen`、`phone_act`、`memory_write`、`memory_get`、`read_image`、`subagent_task`、`user_ask`。
> - **桩化（stub）而非删除**：`iSH/ISHKernel.m`、`ISHShellExecutor.m`、`CurrentRoot.m`、`iSH/RootfsManager.swift`、`NativeOffloads/FFmpegOffload.m` 改写为桩（接口不变，行为是 no-op 或安全失败；`isBooted` 恒为 NO，所以需要沙箱的功能会干净地拒绝而不是崩溃）。`NativeOffloads/*.m` 其余文件原样保留（它们调的两个 libish 函数 `native_offload_add_handler` / `native_offload_set_abort_handler` 由桩内核提供；注册函数再也不会被调用）。pbxproj 去掉了 rootfs 复制、FFmpeg 链接/嵌入、`-lish` 链接参数和 4 个沙箱资源。
> - **一并失去的能力**：MCP 服务器（跑在沙箱里）、同步的文件变化跟踪、外部文件夹挂载（`/var/minis/mounts/`）、终端界面入口（已隐藏）、Apple 框架命令行（`apple-healthkit` 等，只能经 shell 调用）、`minis-config` / `minis-scheduled` / `minis-model-use` 等 CLI。Backup（rclone）保留。测试 target 仍引用沙箱/FFmpeg，未改（CI 不编测试）。
> - **预期结果**：不再有 30–60 分钟原生依赖构建；.tipa 从几百 MB 降到几十 MB。

---

## 0. 结论先行

**能做，而且路是通的。** OpenMinis 本身就是一个带 Agent 循环的 Swift 应用，工具注册、系统提示、权限开关、Obj-C 桥接的现成位置都有；PhoneAgent / MiniPaw 的「眼 + 手」是一套不依赖 Xcode 工程的纯 Obj-C 代码（约 1300 行），可以直接搬进来。最大的工作量不在植入本身，而在**第一次把 OpenMinis 在 GitHub Actions 里编出来**（原生依赖 30–60 分钟）以及**用 ldid 给一个带多个 extension + SPM framework 的大应用正确重签**。

推荐路线：**直接把 MiniPaw 的能力以原生模块形式接进 Minis 的 Agent 循环**（不走 8300 HTTP 中转）；HTTP 接口只留一个默认关闭的调试开关。

---

## 1. 仓库现状（已验证）

| 项目 | 事实 |
|---|---|
| 克隆 | `git clone --recurse-submodules https://github.com/wind-peng/OpenMinis.git` 成功，**297 MB** |
| HEAD | `1a71df0` Merge pull request #495（android-1.15-tailscale-fix） |
| 子模块 | `deps/ish` 0fd17a13、`deps/ish/deps/libapps` b8cacae3、`deps/ish/deps/libarchive` fc6563f5、`deps/proot` 8b31a69，全部干净；**`deps/ish/deps/linux` 未初始化**（克隆日志写明 `Skipping submodule 'deps/ish/deps/linux'`，`git submodule status` 显示 `-8ec9bf17…`）。构建前要确认 `build_ish.sh` 是否需要它，不需要就不用管，需要就补 `git submodule update --init deps/ish/deps/linux` |
| 版本 | 主 App `MARKETING_VERSION = 1.15`；bundle id `com.openminis.app`；显示名 Minis |
| 部署目标 | 主 App target（含 extension）`IPHONEOS_DEPLOYMENT_TARGET = 16.0`（10 处）；另有 2 处 16.2、4 处 26.2（测试 target）。**App 本身可以在 iOS 16.1 上跑** |
| 构建要求 | Xcode（iOS 26.2 SDK / Swift 6.0）、Metal Toolchain、Go 1.25+、`ninja llvm libarchive pkg-config`、meson；首次编原生依赖约 30–60 分钟（见 `BUILDING.md`） |
| CI | **仓库里没有任何 `.github/workflows`**，没有现成的 IPA 构建 |
| 许可证 | GPL-3.0。植入后分发的 .tipa 仍须遵守 GPL：源码保持公开即可（fork 本来就是 public，工作流文件放进仓库就满足） |

---

## 2. OpenMinis iOS 结构地图（植入要动的位置）

### 2.1 Agent 工具：注册 → 执行 → 提示词，三处一体

| 环节 | 文件 | 关键点 |
|---|---|---|
| 工具注册（唯一可信源） | `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`（297 行） | `makeAgentTools() -> [AgentToolDefinition]`。现有工具：`shell_execute`、`file_read`、`file_write`、`file_edit`、`browser_use`、`memory_write`、`memory_get`、`read_image`、`subagent_task`、`user_ask`。每个工具 = name + description + parameters（`AgentToolParam`，含 `enumValues`）+ required + propertyOrdering。`read_image` 是按模型是否原生支持图片动态切换 description 的范例（`activeModelHasNativeVision`，同一文件顶部） |
| 工具执行（分发） | `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift` | `switch tu.name { case "shell_execute": … }`（约 435 行起）。`shell_execute` 的 handler 是范例：先解析参数 → 空参数报错 → `OffloadPermissionManager` 权限检查 → 执行 → 把结果写回 `messages[msgIdx].blocks[blockIdx].content`。新工具在这里加 `case "phone_screen"` / `case "phone_act"` |
| 系统提示词 | `src/ios/Agent/Chat/AIChatViewModel+SystemPrompt.swift` | `baseSystemPrompt`（约 48 行起）手写拼接 "Available tools:" 列表，每个工具一行 bullet。**工具不在 schema 里就不应出现在提示词里**（文件里多处注释强调这点，如 browser 开关的 `(!Self.toolEnabled(.browser) ? "" : …)` 写法）。新工具要在这里加 bullet，且同样跟开关走 |
| Agent 循环 | `src/ios/Agent/Chat/AIChatViewModel+AgentLoop.swift`（2369 行） | `runAgentLoop`；工具调用走并发执行器。现成循环是「模型调工具 → 看结果 → 再调工具」的回合制，**不需要像 PhoneAgent 那样另写一个内置循环**，见 §3.3 |
| 工具开关 | `src/ios/Views/Settings/ToolsSettingsView.swift` | `AgentToolSwitch` enum（33–34 行现有 `browser` / `agents`，对应 UserDefaults key 如 `agent.tools.browser.enabled`）；`nonisolated static func toolEnabled(_:)`（209 行）。新工具加一个 case，如 `phone = "agent.tools.phone.enabled"`，设置页自动出现开关 |

### 2.2 模型与 API Key

- Provider 目录：`src/ios/Providers/`（`AgentProvider.swift`、`LLMProviderFactory.swift`、`ModelGroupRouter.swift`、`ProviderConfigStore.swift` 等），支持 Anthropic / OpenAI / Gemini / Kimi / OpenRouter / Copilot / Antigravity 等。
- Key 存储：**Keychain**（`ProviderKeychainHelper`，见 `Providers/ProviderConfigStore.swift` 224、1246 行附近），配置元数据放数据库/UserDefaults。用户在设置页自己填 Key，植入不需要动这一块。`read_image` 的原生图片分支说明：只要模型支持图片输入（`supportedModalities.contains(.imageInput)`），工具结果里的图片就能直接被模型看到——`phone_screen` 复用这条路。
- 构建期定制：`src/ios/Configs/ProviderCustomization.xcconfig.example` → 复制为 `ProviderCustomization.xcconfig` 才能编（值留空也能编，见 `BUILDING.md`）。

### 2.3 原生能力现状：已经有「半只手」和「一只眼」

| 能力 | 位置 | 现状与结论 |
|---|---|---|
| 触摸模拟（App 内） | `src/ios/Debug/AutoTouch.h` / `AutoTouch.m` | `simulateTapAtPoint` / `inputText` / `simulateScrollAtPoint`，用私有 UIKit API 合成 UITouch + `sendEvent`。**两个致命限制**：① 整个 `.m` 包在 `#if TARGET_OS_IOS && DEBUG` 里，Release 编译出来是空文件；② 只能点**自己 App 自己的窗口**，点不到别的 App。**不能作为 Agent 的手**，只能留着做 App 内 UI 测试。调用方是 `src/ios/Debug/DebugJSONRPC.swift`（约 2596、2908、2925 行） |
| OCR | `src/ios/NativeOffloads/VisionOffload.h` / `.m` | `apple-vision` offload，给 shell 里的 agent 用：`VNRecognizeTextRequest`，返回 `{text, blocks:[{text, bbox}]}`（bbox 是 0–1 归一化坐标）。能用，但输出格式是给 shell 脚本用的 JSON；PhoneAgent 的 OCR 返回的是屏幕 pt 坐标中心点 + id，更适合直接给模型点。建议**移植 PhoneAgent 的 `ocrImage`**（见 §3.1），而不是改 VisionOffload |
| 屏幕录制 / ReplayKit | 无 | 全仓库 grep `ReplayKit` / `RPBroadcast` / `RPScreenRecorder` **零命中**。广播扩展要全新加 |
| 权限门 | `src/ios/Agent/Offload/OffloadPermissionManager.swift` | `OffloadPermissionLevel` + `checkPermission(for:sessionId:fullCommand:)`（226 行）。`shell_execute` 的 handler 里就是先过这道门再执行。新工具应复用同一道门（或至少同款「首次使用弹窗确认」），不要让模型无声地乱点用户手机 |
| Obj-C 桥接 | `src/ios/MinisApp-Bridging-Header.h` | 已有先例：`#import "ISHKernel.h"`、`#import "FFmpegOffload.h"`、`#import "AutoTouch.h"` 等。**新 Obj-C 文件只要加一行 `#import` 就能被 Swift 调用**，不用另建 bridging header |
| NativeOffloads 模式 | `src/ios/NativeOffloads/`（`FFmpegOffload`、`CalendarOffload`、`ClipboardOffload` 等，.h + .m + 部分有 `*Bridge.swift`） | 仓库里「给 shell agent 加原生能力」的标准做法：Obj-C 实现 + 注册函数（如 `vision_offload_register()`）。手机控制模块可以照这个目录结构放 |

### 2.4 Extension 与签名现状

- 现有 targets：`Minis`（app）、`MinisShare`、`MinisFileProvider`、`AgentWidgetExtension`，另加 `MinisTests` / `MinisUITests` / `MinisTestHost`。
- Extension 点：`com.apple.share-services`（ShareExtension）、`com.apple.fileprovider-nonui`（FileProvider）、`com.apple.widgetkit-extension`（AgentWidget）。每个 extension 有自己的 `.entitlements` 文件和自己的 `Info.plist`，通过 `Embed Foundation Extensions` phase 嵌进主 App。
- 主 App entitlements（`src/ios/Minis.entitlements`）：现在**只有公开 entitlement**——`aps-environment`、`HealthKit`、`HomeKit`、iCloud（`iCloud.com.openminis.app`）、NFC、WeatherKit、app group `group.com.openminis.app`。**没有任何私有 entitlement**，植入要往里加（§3.2）。
- 签名设置：`CODE_SIGN_STYLE = Automatic`，`DEVELOPMENT_TEAM = ""`（空）。`BUILDING.md` 的命令行构建是 `CODE_SIGNING_ALLOWED=NO` 编无签名版——**这正是 TrollStore 路线的起点**：先编无签名，再用 ldid + 私有 entitlements 重签。
- SPM：19 处 `XCRemoteSwiftPackageReference`。构建时要联网解析 SPM 包（Actions runner 上没问题）。
- 值得注意的现成脚本：工程里已有一个 Release-only 的 build phase 脚本，会 `strip -x` 某个 SPM framework 后**用 `codesign` 重签**（它自己处理了 `CODE_SIGNING_ALLOWED=NO` 时跳过重签的逻辑）。说明「构建后改 Mach-O 再重签」的做法在这个工程里已有先例，不会和现有流程冲突。

---

## 3. 植入设计

### 3.1 总体结构：把 MiniPaw 搬进来，改成 Minis 的一个原生模块

不要把 MiniPaw 当成独立 App 塞进来，也不要用进程间 HTTP 当主通道。把它的两个源文件拆成 Minis 的一个模块：

```
src/ios/PhoneControl/
  PhoneControlBridge.h / .m     ← MiniPaw main.m 的核心移植（见下）
  PhoneControlBroadcast/        ← 广播扩展 target 的源码（MiniPaw ext.m 移植）
  PhoneControl.swift            ← Swift 薄封装：给 Agent 工具调用的 async 接口
  PhoneControl.entitlements     ← 主 App 要追加的私有 entitlement（实际是改 Minis.entitlements）
  MinisBroadcast.entitlements   ← 扩展的 entitlement
```

**`PhoneControlBridge.m` 移植清单**（源文件 `~/workspace/minipaw/MiniPaw-v1_2/MiniPaw/src/main.m`，1180 行；只取需要的部分，约 600 行有效代码）：

| 移植内容 | MiniPaw 里的位置 | 说明 |
|---|---|---|
| `loadHID()` | main.m:47–60 | `dlopen` IOKit + `dlsym` 取 `IOHIDEventSystemClientCreate` / `DispatchEvent` / `CreateDigitizerEvent` / `CreateDigitizerFingerEvent` / `CreateKeyboardEvent`，建 `gClient`。**必须在启动时调一次**（v1.0.2 的教训：漏调会导致第一次 tap 调空函数指针直接崩溃） |
| `doTap / doSwipe / doLongPress / doKey` | main.m:71–145、597 | IOHID 触摸注入；坐标用屏幕 pt（MiniPaw 里 `nx, ny` 是归一化 0–1，见 71–80 行附近）。滑动是多点插值 + 时间步进 |
| 输入法（剪贴板粘贴） | main.m:963–973（`/input`） | iOS 不允许后台 App 写剪贴板：先把文字写进 `UIPasteboard`，再用 HID 发 Cmd+V（MiniPaw 是 `doCmdKey` 发左 Cmd + V）。PhoneAgent 的做法是临时切回自己 App 写剪贴板再切回目标 App；MiniPaw 同理。**中文输入走粘贴，不逐字打** |
| `loadShot()` + `shotA–D` + `takeScreenshot()` | main.m:163 起、308 起 | 截图四种方法：R=广播帧、A=`UIWindow createScreenIOSurface`、B=`UIGetScreenImage`、C/D（另外两种私有接口）。**铁律（PhoneAgent main.m:308–312 的注释）：广播开着的时候只能用广播帧，私有 IOSurface 接口和 ReplayKit 同时工作可能触发系统进程级崩溃** |
| `ocrImage()` / `ocrWithHandler()` | main.m:358 起 | Vision `VNRecognizeTextRequest`，**固定 Revision 1 / Fast**（注释：iOS 16.1 上 Revision 3 会触发 `Semaphore object deallocated while in use`）。先缩放到 1400 宽、转灰度、对比度 1.18 再识别。返回 `[{text, x, y, w, h}]`，x/y 是中心点 pt 坐标 |
| `renderForModel()`（红格子） | PhoneAgent `src/main.m:1079` 起 | 把截图缩放到 **780×1688**，画红色 100px 网格 + 边缘数字。模型返回的坐标就是这张图的像素坐标，换算回 pt 再点。OCR 列表的坐标也要换算到同一套 780×1688 坐标系（`hybridMessages` 里 `k = MODEL_W / sc.width`） |
| 帧接收 socket | main.m:1042 起、ext.m:17 起 | 主 App 在 127.0.0.1 监听一个 TCP 端口收 JPEG 帧；扩展用 `FRAME_KEY`（`src/shared.h`）做暗号握手。端口不要用 MiniPaw 的 8300（用户手机上可能同时装着 MiniPaw，端口会撞），建议用 **8310** |
| 保活音频 | main.m:1148 起（v1.0.1 的改动） | 静音音频会话**在前台就激活**，退后台才稳；iOS 经常拒绝「进后台那一刻才激活」。回前台时 `resumeKeepAlive()`。这是「App 在后台时 HTTP/录屏服务不掉线」的关键 |

**`PhoneControlBroadcast`（新 target，移植 MiniPaw `ext.m`，164 行）**：

- `RPBroadcastSampleHandler` 子类，`processSampleBuffer` 里把 `CVPixelBuffer` 压成 JPEG，用 socket 发给主 App（ext.m:117–151）。JPEG 编码走 CoreImage。
- `Info.plist`：`NSExtensionPointIdentifier = com.apple.broadcast-services-upload`，`RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer`，主类 `SampleHandler`。
- bundle id：`com.openminis.app.MinisBroadcast`；product type `com.apple.product-type.app-extension`；像 `MinisShare` 一样走 `Embed Foundation Extensions` phase。
- 扩展是独立进程，**它只管送帧**；所有决策、OCR、注入都在主 App。

### 3.2 权限（entitlements）：给「完整权限」

主 App（追加到 `src/ios/Minis.entitlements`，保留现有公开项）：

```xml
<key>platform-application</key><true/>
<key>com.apple.private.security.no-container</key><true/>
<key>com.apple.private.security.no-sandbox</key><true/>
<key>com.apple.private.hid.client.event-dispatch</key><true/>
<key>com.apple.private.hid.manager.client</key><true/>
<key>com.apple.backboard.client</key><true/>
<key>com.apple.springboard.launchapplications</key><true/>
<key>com.apple.springboard.opensensitiveurl</key><true/>
<key>com.apple.security.iokit-user-client-class</key>
<array>
  <string>IOSurfaceRootUserClient</string>
  <string>IOSurfaceAcceleratorClient</string>
  <string>AGXDeviceUserClient</string>
</array>
```

（与 MiniPaw `entitlements.plist` 逐项一致，已用 diff 验证过 PhoneAgent v56 的同一份文件完全相同。）

广播扩展（新建 `MinisBroadcast.entitlements`）：`platform-application`、`no-container`、`no-sandbox`、`iokit-user-client-class` 三项即可（与 MiniPaw `entitlements-ext.plist` 一致；扩展不需要 HID entitlement）。

**关键说明**：这些私有 entitlement 只有 ldid 假签名 + TrollStore 才认，苹果开发者证书签不出来。所以这条路线**只能走 .tipa**，不能上架、不能用 Xcode 直接真机调试签名。`CODE_SIGNING_ALLOWED=NO` + ldid 是唯一走法。

### 3.3 Agent 工具设计（复用现有循环，不另写循环）

Minis 的 agent 循环本身就是「模型 → 工具调用 → 结果回填 → 模型再决策」的回合制，PhoneAgent 的 `agentRunCore` 内置循环（`src/main.m:1902` 起：截屏 → OCR → 调模型 → 执行动作 → 循环）在 Minis 里**不需要复制**。只要给模型两个工具，现有循环自然就走出「看 → 点 → 再看」的闭环。

**工具一：`phone_screen`（眼睛）**

- 参数：只有 `tool_title`（必填，跟所有工具一样的惯例）。
- 返回：**图片本身**（走 `read_image` 原生图片分支的同一条结果通道——模型直接看到像素）+ 一段文字：OCR 列表，格式照搬 PhoneAgent 的 `hybridMessages`：
  ```
  [1] (120,340) 设置
  [2] (300,340) 通用
  …
  ```
  坐标是 780×1688 截图的像素坐标。超过 80 条截断（PhoneAgent 的上限）。
- 行为：取最新一帧（广播开着时用广播帧，否则用 `takeScreenshot()` 的 A–D 回退）。如果录屏没开且回退方法都失败，返回明确的错误文字，告诉模型「请让用户先开屏幕录制」而不是瞎猜。
- 图片处理：截图先过 `renderForModel`（缩 780×1688 + 红格子 + 边缘数字），跟 PhoneAgent 完全一致，模型坐标系才不会乱。

**工具二：`phone_act`（手）**

- 参数：`tool_title`（必填）；`action`（enum：`tap` / `long_press` / `swipe` / `input_text` / `open_app` / `press_home` / `key`）；`x`, `y`, `x2`, `y2`（780×1688 像素坐标，`tap`/`swipe` 用）；`id`（OCR 编号，优先于坐标——PhoneAgent 的经验：按 id 点比按坐标准）；`text`（`input_text` / `key` 用）；`name`（`open_app` 用，App 中文名；找不到时返回已安装 App 列表让模型重试，照搬 PhoneAgent `main.m:898` 的做法）；`direction`（`swipe` 没给坐标时的方向：up/down/left/right）。
- **返回：动作执行结果文字 + 执行后新截屏的图片**。这样模型每调一次手就自动看到新屏幕，省掉一次 `phone_screen` 调用，回合数减半。这是比 PhoneAgent 更省 token 的做法（PhoneAgent 每步都要重新调一次完整请求）。
- 坐标换算与越界检查照搬 PhoneAgent（`agentRunCore` 约 1960–2000 行）：`kx = 屏幕宽 / 780`，坐标 clamp 到屏幕内，超范围（>780+20 或 >1688+20）拒绝执行并告诉模型。

**安全刹车（照搬 PhoneAgent，必须有）**：

- 支付/密码关键词表（PhoneAgent `kDangerWords`，`src/main.m:1144` 起：立即支付、确认支付、去支付、付款、提交订单、立即购买、去结算、确认付款、支付密码、免密支付等）：OCR 文本或模型可见文本命中任一词 → **停止任务，交用户手动处理**。在 handler 里做两层检查：执行前看当前屏幕 OCR，执行后看新屏幕 OCR。
- 卡死检测：连续 4 步屏幕无变化 → 停（PhoneAgent 的 `same >= 4` 规则）。
- 权限门：首次使用 `phone_act` 时走 `OffloadPermissionManager` 同款确认（或设置页里一个明确的「允许 Agent 控制手机」开关 + 首次弹窗）。`phone_screen` 只读，可以不设门；`phone_act` 必须有。

**系统提示词**（`AIChatViewModel+SystemPrompt.swift` 的 "Available tools:" 段，照搬 PhoneAgent `kAgentSystem` 的动作说明，`src/main.m:1000–1028`）：

```
- phone_screen: 看当前手机屏幕。返回一张 780x1688 的截图（带红色网格和坐标数字）和本地 OCR 文字列表 [编号] (x,y) 文字。每次要决定点哪里之前先调它。
- phone_act: 操作手机。tap 点一下，long_press 长按，swipe 滑动，input_text 往输入框输文字（走剪贴板粘贴），open_app 打开 App，press_home 回主屏幕，key 按按键。优先用 OCR 编号 id，不要自己估坐标；没有 id 才用 x,y。每次调用后都会返回新截图，根据新截图判断动作有没有生效。看到支付、付款、密码界面立刻停下来交给用户，不要继续点。
```

**工具开关**：`AgentToolSwitch` 加 `phone = "agent.tools.phone.enabled"`，设置页（`ToolsSettingsView.swift`）自动出现开关；`makeAgentTools()` 里关掉时不注册，`baseSystemPrompt` 里关掉时不写 bullet（照抄 browser 的写法）。

**图片回传通道**：工具结果怎么把图片塞给模型，要复用 `read_image` 的实现（它已经解决了「工具结果带图片」的问题）。实施时先读 `read_image` 的 handler 和 `AIChatViewModel+SSEStream.swift` 里的工具结果组装（约 560、802、917、1196 行附近有 `shell_execute` / `browser_use` 的结果处理），确认图片块的类型再接线——这是实施第一步要验证的细节，本文不臆测。

### 3.4 HTTP 服务器：不作为主通道，只留调试开关

**推荐：不保留 MiniPaw 的 8300 HTTP 接口作为 Agent 的主通道。** 直接进程内调用（Swift → Obj-C bridge）更快、不用管 token、不占端口、少一个故障点。

但留一个**默认关闭**的调试 HTTP 服务有价值：可以在电脑上 `curl` 测眼睛和手，不用经过 LLM。做法：把 MiniPaw 的 socket server 代码（`main.m:1042` 起的 `bind/listen/accept` 循环）原样放进 `PhoneControlBridge`，只暴露最小集（`/ping`、`/screenshot`、`/tap`、`/status`），端口用 **8310**（避开 MiniPaw 的 8300，防止两 App 同装时撞口），开关放设置页，默认关。等 Agent 工具稳定后可以整个删掉。

### 3.5 用户侧操作（装好以后）

1. TrollStore 装 `.tipa`（覆盖安装即可，bundle id 不变就不用重装）。
2. 打开 Minis → 设置 → 手机控制：点「开启屏幕录制」，在系统录屏选择器里选 **Minis**，点「开始直播」。录屏开着，眼睛才有画面；手（HID）不需要录屏也能用。
3. 在聊天里直接说任务（例如「打开淘宝搜袜子」），Agent 自己 `phone_screen` → `phone_act` 循环做完。
4. 录屏一直开着会耗电、状态栏常驻红条，这是 ReplayKit 方案的固有代价，和 PhoneAgent 完全一样。锁屏后录屏会停，Agent 也就看不见了——同样是固有限制。

---

## 4. 在 GitHub Actions 里编 TrollStore .tipa：可行性

### 4.1 已验证：runner 有 Xcode 26.2

2026-11-10 从 `actions/runner-images` 官方 README 实测：

- **`macos-26` 镜像存在**（Image Version 20260824.0517.1，macOS 26.6.1），自带 Xcode **26.2**（`/Applications/Xcode_26.2.app`），同时有 26.0.1–26.6；默认 Xcode 是 26.6；iOS SDK `macosx26.2` 对应 Xcode 26.2/26.3。
- 工作流里用 `sudo xcode-select -s /Applications/Xcode_26.2.app` 锁定 26.2（不要用默认 26.6，避免 SDK 漂移）。
- **fork 是 public，Actions 分钟免费**（public 仓库不计费）。即使 30–60 分钟的原生依赖构建也不花额度。`macos-26` 是 arm64 runner（也有 `macos-26-arm64` 的 readme，同一镜像）。
- 注意：不要用 `macos-15-intel`（PhoneAgent/MiniPaw 用的那个）——Minis 的原生依赖要 Apple Silicon 才能编 iSH（`BUILDING.md` 明确说 Apple Silicon strongly recommended；DSH 的教训：Intel runner 编 ARM64 模拟器会失败）。

### 4.2 工作流草图（`.github/workflows/build-tipa.yml`，新建）

```yaml
name: build-tipa
on:
  push:
  workflow_dispatch:
jobs:
  build:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Select Xcode 26.2
        run: sudo xcode-select -s /Applications/Xcode_26.2.app
      - name: Install deps
        run: |
          brew install ninja llvm libarchive pkg-config meson
          brew install go   # 需要 1.25+，若 brew 的 go 版本不够改用 actions/setup-go
          xcodebuild -downloadComponent MetalToolchain
      - name: ProviderCustomization
        run: cp src/ios/Configs/ProviderCustomization.xcconfig.example src/ios/Configs/ProviderCustomization.xcconfig
      - name: Cache native deps
        uses: actions/cache@v4
        with:
          path: |
            deps/lame-build
            deps/frameworks
            deps/libs
            deps/include
            deps/resources
          key: minis-native-${{ hashFiles('deps/build_*.sh', 'deps/prepare_alpine_rootfs.sh') }}
      - name: Build native deps (order matters: LAME first, FFmpeg links it)
        run: |
          ./deps/build_lame.sh
          ./deps/build_ffmpeg.sh
          ./deps/build_ish.sh
          ./deps/prepare_alpine_rootfs.sh
          ./deps/build_rclone_ios.sh
      - name: Build unsigned
        run: |
          xcodebuild -project src/ios/Minis.xcodeproj -scheme Minis \
            -configuration Release -destination 'generic/platform=iOS' \
            CODE_SIGNING_ALLOWED=NO build
      - name: Re-sign with ldid (TrollStore entitlements)
        run: |
          brew install ldid
          APP=$(find ~/Library/Developer/Xcode/DerivedData -name "Minis.app" -type d | head -1)
          # 先签内层（appex、frameworks），再签主 App；每一步用对应的 .entitlements
          ldid -S src/ios/MinisBroadcast/MinisBroadcast.entitlements "$APP/PlugIns/MinisBroadcast.appex/MinisBroadcast"
          ldid -S src/ios/ShareExtension/ShareExtension.entitlements "$APP/PlugIns/MinisShare.appex/MinisShare"
          ldid -S src/ios/FileProvider/FileProvider.entitlements "$APP/PlugIns/MinisFileProvider.appex/MinisFileProvider"
          ldid -S src/ios/AgentWidget/AgentWidget.entitlements "$APP/PlugIns/AgentWidgetExtension.appex/AgentWidgetExtension"
          # 嵌在 Frameworks 里的 SPM framework 也要逐个签（无 entitlement）
          find "$APP/Frameworks" -name "*.framework" -type d | while read fw; do
            bin="$fw/$(basename "$fw" .framework)"; [ -f "$bin" ] && ldid -S "$bin"
          done
          ldid -S src/ios/Minis.entitlements "$APP/Minis"
          mkdir Payload && cp -R "$APP" Payload/
          zip -qr Minis.tipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: Minis-tipa
          path: Minis.tipa
```

要点：

- `submodules: recursive`：`deps/ish/deps/linux` 也会被拉（它默认被 skip，recursive 会不会拉它要实测；如果拉不到又不需要，忽略即可）。
- **缓存是关键**：原生依赖 30–60 分钟，只应在第一次或 `deps/build_*.sh` 变化时重编。`actions/cache` 的 key 挂在脚本 hash 上。
- `CODE_SIGNING_ALLOWED=NO`：`BUILDING.md` 官方给的命令行就是这么编的，无签名构建是被支持的。
- ldid 签名顺序：**先内后外**（appex 和 framework 先签，主 App 最后签），否则外层签名会被内层修改破坏。PhoneAgent/MiniPaw 只有两个二进制所以没暴露这个问题；Minis 有 3 个 appex + 若干 SPM framework，必须逐个签。
- 那个 VAD strip 脚本在 `CODE_SIGNING_ALLOWED=NO` 时会跳过重签（脚本自己判断了），不用改。
- 产物会很大：iSH + Alpine rootfs + FFmpeg + rclone，.tipa 预计几百 MB（对比：MiniPaw 43KB、PhoneAgent 100KB、DSH 82MB）。artifact 上传没问题（GitHub 单个 artifact 上限很大），TrollStore 安装大包也没问题，但要提醒用户下载体积。

### 4.3 风险清单（按严重程度）

1. **iOS 16.1 运行时兼容（最大风险）**。部署目标是 16.0，但工程按 iOS 26.2 SDK / Swift 6.0 编译。上游代码如果用了 iOS 17+ 的 API 且没包 `@available` 守卫，在 16.1 上会启动即崩或用到才崩。植入的新代码必须只用 ≤16.1 的 API（ReplayKit 广播上传是 iOS 10+ 的 API、Vision Revision 1、IOHID 私有函数都不挑版本，这部分是安全的）；但**要先在 16.1 真机上跑通一次未改动的 Minis**，确认基线本身没问题，再植入。
2. **ldid 重签大应用的完整性**。要签的 Mach-O 数量多（主 App + 3–4 个 appex + SPM frameworks + 可能的 dylib），漏签一个就启动失败（TrollStore 会报签名错误）。工作流里最后要加一步验证：`ldid -e` 逐个导出 entitlement 核对，`codesign --verify --deep --strict` 只能做参考（ldid 签名过不了苹果的 strict 校验是正常的，别被它误导）。
3. **原生依赖首次构建 30–60 分钟 + 体积**。GitHub macOS 任务单次上限 6 小时，够用；但 `build_ffmpeg.sh` / `build_ish.sh` 在 runner 上出任何错，排错周期很长。先用缓存把「编依赖」和「编 App」拆成两步验证。
4. **录屏必须手动开一次**。ReplayKit 广播扩展不能由 App 自己静默启动；用户每次都要在控制中心里选 Minis 并点「开始直播」。PhoneAgent 是靠盲点系统面板自动化的，Minis 里可以复用同一招（`RPSystemBroadcastPickerView` + 盲点），但那是第二阶段的优化，第一版接受手动开。
5. **私有 entitlement 的副作用**。`platform-application` + `no-sandbox` 会让 App 脱离沙盒；iCloud / HealthKit / 推送这些依赖苹果签名的能力在 ldid 包里会失效（大概率是调用失败而不是崩溃，但 HealthKit offload 那条路要实测确认不崩）。`com.apple.security.iokit-user-client-class` 只列了三个 IOSurface 客户端，是 MiniPaw 验证过的最小集，不要多加。
6. **`deps/ish/deps/linux` 子模块被 skip**。`build_ish.sh` 是否需要它尚未验证；如果需要，`submodules: recursive` 可能自动补上，也可能要显式 `git submodule update --init deps/ish/deps/linux`。
7. **Swift 6 语言模式**。工程里 12 处 `SWIFT_VERSION = 5.0`、2 处 `6.0`——新加的 Swift 文件（`PhoneControl.swift`）要跟所在 target 的语言模式一致，写 Swift 5 风格最稳妥，避免 Swift 6 的严格并发检查在旧 target 上报错。

---

## 5. 实施步骤（按顺序）

| 步骤 | 内容 | 验收 |
|---|---|---|
| 1 | **先通 CI，不动业务代码**：在 fork 里新建 `.github/workflows/build-tipa.yml`（§4.2），跑一次未改动的 Minis，拿到无签名的 `.tipa`（先不加私有 entitlement，只签个空壳验证流程） | Actions 绿了，artifact 里有 `Minis.tipa`，`Payload/Minis.app/Minis` 是 arm64 Mach-O |
| 2 | **真机基线**：把步骤 1 的包（此时还没有私有 entitlement，只有公开项，用 ldid 空签）装到 iPhone 13 上，能打开、能进设置填 Key、能跑一次 `shell_execute` | 确认未改动的 Minis 在 iOS 16.1 上本身就能跑，排除风险 1 |
| 3 | **移植眼睛和手**：新建 `src/ios/PhoneControl/`，移植 `PhoneControlBridge.m`（§3.1 清单）+ `PhoneControl.swift` 薄封装；在 bridging header 加 `#import "PhoneControlBridge.h"` | Xcode 本地或 CI 能编过；先不接 Agent |
| 4 | **加广播扩展 target**：`MinisBroadcast`（`com.apple.broadcast-services-upload`），移植 `ext.m`；`Embed Foundation Extensions` 挂进主 App | 编过；扩展出现在 `Payload/Minis.app/PlugIns/` |
| 5 | **加私有 entitlement**：改 `Minis.entitlements`（§3.2），新建 `MinisBroadcast.entitlements`；工作流的 ldid 步骤按 §4.2 签全 | `ldid -e` 逐个核对 entitlement 都在 |
| 6 | **接 Agent**：`makeAgentTools()` 加 `phone_screen` / `phone_act`；`ConcurrentTools.swift` 加两个 `case`；`baseSystemPrompt` 加 bullet；`AgentToolSwitch` 加 `phone` 开关；权限门 + 危险词刹车 | 编过 |
| 7 | **设置页**：加「手机控制」设置页——录屏状态、HID 就绪状态、`RPSystemBroadcastPickerView`、一键测试（截屏 / 点一下屏幕中心） | 用户能自助验证眼和手 |
| 8 | **真机端到端**：TrollStore 装包 → 开录屏 → 聊天里说「打开设置，截个图告诉我看到了什么」→ 再说一个多步任务（开淘宝搜东西） | 眼睛（截图+OCR）和手（点/滑/输/开App）都通；支付界面能刹住 |
| 9 | （可选）**调试 HTTP**：加 8310 端口最小集 + 设置开关，默认关；稳定后可删 | `curl 127.0.0.1:8310/screenshot` 能出图 |
| 10 | （可选）**自动开录屏**：复用 PhoneAgent 的盲点面板做法，`RPSystemBroadcastPickerView` + 自动点「开始直播」 | 不用每次手动开 |

---

## 6. 关键文件速查

**OpenMinis（fork `wind-peng/OpenMinis`，本地 `~/workspace/openminis-check/`）**

- `BUILDING.md`——构建要求与顺序
- `src/ios/Minis.xcodeproj/project.pbxproj`——targets、bundle id、部署目标
- `src/ios/Minis.entitlements`——主 App entitlement（要追加私有项）
- `src/ios/MinisApp-Bridging-Header.h`——Obj-C 桥接（加一行 import 即可）
- `src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift`——`makeAgentTools()`
- `src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift`——工具分发 `switch tu.name`
- `src/ios/Agent/Chat/AIChatViewModel+SystemPrompt.swift`——`baseSystemPrompt`
- `src/ios/Views/Settings/ToolsSettingsView.swift`——`AgentToolSwitch`、`toolEnabled`
- `src/ios/Agent/Offload/OffloadPermissionManager.swift`——权限门范例
- `src/ios/Debug/AutoTouch.h/.m`——App 内触摸模拟（DEBUG-only、只能点自己，别当成手）
- `src/ios/NativeOffloads/VisionOffload.m`——现有 OCR（shell 用，bbox 0–1）
- `src/ios/Providers/ProviderConfigStore.swift`——Keychain 存 Key

**PhoneAgent / MiniPaw（移植源，本地只读）**

- `~/workspace/minipaw/MiniPaw-v1_2/MiniPaw/src/main.m`（1180 行）——HID、截图、OCR、HTTP、保活
- `~/workspace/minipaw/MiniPaw-v1_2/MiniPaw/src/ext.m`（164 行）——广播扩展
- `~/workspace/minipaw/MiniPaw-v1_2/MiniPaw/src/shared.h`——`FRAME_KEY`、端口
- `~/workspace/minipaw/MiniPaw-v1_2/MiniPaw/entitlements.plist` / `entitlements-ext.plist`——私有 entitlement 清单
- `~/workspace/phoneagent/PhoneAgent-src-v25/PhoneAgent_v56/src/main.m`——`agentRunCore`（1902 行）、`hybridMessages`（1103 行）、`renderForModel` 红格子（1079 行）、`kDangerWords`（1144 行）、系统提示动作说明（1000–1028 行）

**已验证的外部事实**

- GitHub `macos-26` runner 自带 Xcode 26.2（`/Applications/Xcode_26.2.app`，Image Version 20260824.0517.1），来源：`actions/runner-images` 官方 README，2026-11-10 实测抓取。
- Public 仓库 Actions 免费，不消耗用户 2000 分钟额度（该额度 2026-12-01 重置，私有仓库才计费）。
