# cmux 每终端状态快照与会话恢复设计

> 状态：待实现的需求与技术建议。供接手实现的 Agent 阅读。
>
> 依据：2026-09-23 对本地仓库 `67a3296e0d` 的代码检查，以及用户在本次讨论中确认的产品意图。本文不表示功能已经实现。

## 1. 用户想要的行为

关闭并重新打开 cmux 后，每个原有终端应尽量回到**该终端自己最近一次被确认的状态**：

1. 如果终端里仍是某个 agent，恢复**该终端绑定的 agent 类型和准确的 session ID**。Claude、Codex、Grok 等都应遵循相同原则；不能从全局“最近的会话”猜一个 ID。
2. 如果 agent 已退出、终端回到 shell，就恢复普通终端，而不是重新启动刚才的 agent。保留工作目录和有界的可见历史，让用户看得出此前做过什么。
3. 如果是普通终端，也保留工作目录和有界历史。布局、终端身份和已有的字体等快照属性继续恢复。
4. 后台按固定间隔重新核对**每一个终端**。用户可以接受几分钟的延迟；十分钟也是可接受的资源节约选项。正常退出时尽可能再核对一次。突然断电或崩溃时，按最近一次成功写入的快照恢复。
5. 对远程终端、tmux、持久化 PTY 和休眠中的会话，优先接回原有的持久会话；不要同时再启动一个本地 agent。

这里的“恢复终端状态”是合理的重建，不是让操作系统重启后原来的本地进程继续运行。普通 shell 的历史只是显示/上下文；任意未持久化的前台进程（例如 `vim`、`python`）不能保证继续执行。界面应诚实显示这种区别。

## 2. 设计原则与边界

- **以终端 surface ID 为归属键。** 工作区 ID 可能在恢复时变化；历史记录必须跟随原终端。若恢复到现有窗口时发生 surface ID 冲突，应明确处理冲突，不可把旧绑定悄悄应用到新终端。
- **定时核对是正确性的基础路径。** hook、shell integration、启动器和退出事件可以使状态更快更新，但漏掉事件后，下一次核对仍须能自我修正。无需为了第一版覆盖所有启动/退出事件。
- **区分“最近确认的当前状态”和“上一个 agent”。** 上一个 session ID 可供手动恢复，却不构成自动恢复的许可。
- **把“有记录”与“进程仍在该终端”分开。** agent 的 `Stop` 往往是一次回答结束，不等于进程退出；单凭旧 hook、标题、同目录文件或最近修改时间，也不足以确认当前终端仍运行该 agent。
- **未知就保持未知。** 核对失败、远程不可达或证据冲突时，不得把旧 agent 当作当前进程，也不得把一次扫描失败写成“agent 已退出”。保留可见历史、目录和手动恢复入口。
- **每个终端只有一份最终恢复计划。** 现有 `agent`、`resumeBinding`、tmux、远程 PTY、休眠信息可能同时存在，必须先归并、判优，再决定一次启动动作。
- **避免恢复错误的会话优先于自动启动率。** 要在日志和 UI 中说明为何没有自动启动，并允许用户在正确终端手动恢复已知会话。

## 3. 建议的状态模型

在 `SessionTerminalPanelSnapshot` 增加版本化的、每 surface 一份的观察结果。以下是概念模型，不要求照抄类型名：

```swift
struct TerminalRecoveryObservation: Codable, Sendable {
    var surfaceID: UUID
    var generation: UInt64             // 本终端每次状态更改递增
    var observedAt: Date               // 证据核对完成时间
    var state: CurrentState            // agent / shell / otherProcess / unknown
    var agent: AgentIdentity?          // 仅 state == agent 时有效
    var processIdentity: ProcessIdentity? // pid + 启动时间等，防止 PID 复用
    var provenance: ObservationSource  // hook+process / process / remote / shell 等
    var cwd: String?
    var lastKnownAgent: AgentIdentity? // 只用于用户选择的手动恢复
    var historyReference: String?      // 有界历史单独存储时的引用
}

struct AgentIdentity: Codable, Sendable {
    var kind: String                   // 注册 agent kind，避免只支持硬编码的两种
    var sessionID: String              // 从该 agent 的可靠来源获得
    var launchContext: ...             // 实际可恢复所需的最小参数
}
```

`state == agent` 必须同时有可信的 kind、session ID 和该终端的归属证据；如果只知道程序名、不知道准确 session ID，记为 `unknown` 或“agent 身份待确认”，不能猜最新 session。`state == shell` 表示当前 shell 已重新取得前台控制且先前 agent 已不在该终端。`otherProcess` 记住进程类别供显示，但默认只恢复 shell、目录和历史。`unknown` 保留原观察和诊断原因，供下一轮核对。

进程归属至少核对终端的 tty/PTY、前台进程组或受控进程树；PID 要连同进程启动时间或同等身份信息保存。agent session ID 应来自该终端绑定的 hook/启动参数/受控注册信息，并与实际进程归属交叉核验。远程和 tmux 使用各自可验证的适配器，不能拿 Mac 本地 `ps` 的阴性结果判定远端 agent 已退出。请复用仓库现有的 surface token、进程扫描与 binding 设施；不要另建按 cwd 或最新文件时间猜测的绑定系统。现有 `docs/agent-session-tracking-spec.md` 对 surface 身份和可靠绑定有背景说明，但其 iOS GUI 目标与本文的重启恢复目标不同；实现前应以**当前代码**再次核实其历史结论。

## 4. 采集与持久化流程

### 4.1 独立的定时核对

建议第一版默认每 **5 分钟**进行一次全终端状态核对，间隔可配置到 10 分钟；用户已经明确接受几分钟误差。每轮只做一次共享的进程快照，然后按 surface 分配/核验，避免每个 pane 各自运行一遍 `ps` 或扫描同一目录。仅在底层进程/绑定指纹变化时做较贵的解析。后台任务应在 utility 优先级运行、限制并发、避免阻塞主线程和用户输入。

已有 `SessionPersistencePolicy.autosaveInterval = 8s` 是**快照保存频率**，不应直接变成昂贵的完整状态核对频率。目前 `AppDelegate` 的 autosave 路径会加载 `ProcessDetectedResumeIndexes` 并进行指纹跳过；实施时要实测并把“便宜的布局/元数据保存”与“每几分钟一次的完整状态核对”分开。刷新成功后及时持久化新的观察结果，而不是等下一次较慢的全量保存。可利用现有缓存，但不能让缓存年龄冒充实际核对时间。

建议状态更新的时序：

```text
启动一个核对轮次，记下每个 surface 的 generation
  -> 在后台获取共享进程/远程证据
  -> 对每个 surface 解析 state 与 agent identity
  -> 返回主模型时，仅当 surface 仍存在且 generation 未被更新时提交
  -> 原子写入元数据快照；有变化才写盘
```

hook、shell `preexec/precmd`、cmux 自己发起的 agent 启动/退出，可提前触发单 surface 核对或提交强证据。即使这些信号丢失，定时轮次仍会修正。异步扫描返回顺序可能错乱；使用 generation 或采集时的比较条件，防止旧轮次覆盖新状态。不要因为扫描暂时失败而抹掉最后一个可信 `lastKnownAgent`。

### 4.2 历史、工作目录和退出时快照

状态元数据与终端 scrollback 分开保存。历史有明确容量上限、截断标记和原子替换策略；可以先沿用现有每终端最多 4,000 行 / 400,000 字符的限制，再按内存和磁盘实测调整。历史采集可与状态核对同频或在有输出变化时节流保存；正常退出、关机前尽力进行最终采集。若关机时间不足，沿用上一份完整快照，不能写入半截文件。

恢复历史必须走显示层的 scrollback 恢复，不得把历史文本送入新 shell 当命令执行。对 agent pane，可选择在启动新 agent 前显示旧屏幕，或提供可展开的“上次终端历史”；避免旧 TUI 画面与新 agent 输出混在同一可编辑屏幕中。对普通终端，恢复历史和 cwd 是核心验收项。保留现有关闭确认、隐私与持久化策略语义；如当前策略阻止历史保存，要在产品和测试中明确其影响。

### 4.3 崩溃与不确定性

记录 `observedAt`、`persistedAt` 和观察来源，调试时能说清“上次确认是何时”。突然重启前 5 分钟内状态改变，可能只能按旧快照恢复，这是用户接受的轮询权衡；因此自动启动仍应在启动时做一次低成本的**当前环境/会话重复检查**。若旧进程或远程持久会话仍在，不再起第二个。判断快照是否过期，要比较观察时间与**最后一次保存/退出时间**，不能仅因为 cmux 关闭了几天就丢掉一个在关闭前刚确认的 agent。对于无法确认、缺少 ID、来源冲突或观察早于最终快照太久的记录，恢复 shell 和历史，保留手动入口，并记录可解释的原因。不要把“间隔过长”笼统当成所有恢复失败的原因：错误归属、缺 ID、启动失败和重复保护是不同故障。

## 5. 启动恢复决策

对每个 pane 构造一次 `RecoveryPlan`，由单一协调器执行。推荐顺序如下：

| 已确认状态/条件 | 恢复动作 |
| --- | --- |
| 可重新附着的远程 PTY、tmux 或休眠会话 | 优先附着；核对其内部状态；不要并行启动本地 agent |
| `agent`，kind 与 session ID 完整且终端绑定可信 | 在原 surface 以该 ID 恢复；先查同 session 是否已存活/被其他 pane 认领 |
| `shell` | 新 shell + cwd + 有界历史；旧 agent 只留手动恢复入口 |
| `otherProcess` | 新 shell + cwd + 有界历史，明确原普通进程未延续 |
| `unknown` 或相互矛盾的证据 | 新 shell + cwd + 历史；说明无法安全自动恢复 |

遵守现有用户的自动恢复设置。多个 pane 指向同一 agent session 时，必须定义归属：有可靠原 owner 时只恢复它；确属用户复制出的独立 pane 时不要偷用同一个 session。启动前去重与锁定可复用 `AgentResumeLaunchGuard` / `AgentResumeLiveness`，但“发出了命令”不等于“恢复成功”。只有进程启动且绑定到预期 surface 和 session 后才标记 `resumed`。启动失败应保留原快照和一键重试，不得把失败误写为当前 shell 的已确认正常状态。启动完成后的首轮核对可加速验证，不必等五分钟。

恢复时的旧字段迁移要明确：旧版 `wasAgentRunning: Bool?` 只有弱证据，不能直接映射为新 `agent` 确认态；结合 `agent`、`resumeBinding`、进程与远程信息形成一次迁移观察。若仍不能证实，按 `unknown` 处理，保留手动恢复能力。迁移前备份或保持向后可读，避免新版本运行一次就删除既有 session ID。新模型稳定后，再考虑淘汰布尔字段。

## 6. Grok 与 `cmux restore` 的具体问题

`cmux restore grok <session-id>` **不是全局按 session ID 查找并恢复**。当前 `CLI/CMUXCLI+Restore.swift` 首先按调用终端的 `CMUX_SURFACE_ID`（或 tty）查询 `surface.resume.get`；随后校验该 surface 的记录是否为 `grok`、checkpoint 是否等于参数。若在 Codex pane 调用 Grok ID，会报 kind mismatch；若在别的 Grok pane 调用，也可能报 checkpoint mismatch；在 cmux 外运行则可能无法识别当前 surface。`--surface <id>` 允许读取指定 surface 的记录，但目前 CLI 最终是在**调用它的终端进程中**执行恢复命令，不能把它理解为“将程序启动进另一个 pane”。

这与 Grok 客户端能否按 ID 恢复是两回事。当前 cmux 的 Grok resume 参数生成逻辑使用 `grok -r <id>`；本机安装的 Grok CLI 也支持 `-r`。因此，用户给出的 `cmux restore grok 01a0cf2e-bda0-7181-97a2-ec8bcf36f44e` 报错，**不能仅凭这条命令断言 Grok 不支持恢复**。本次没有拿到那次命令的完整 stderr，不能断言具体失败点。接手 Agent 应在对应 Grok pane 和错误现场核实 surface、记录 kind、checkpoint、cwd、CLI 启动结果。

建议改进 CLI：报错时显示“当前终端的 surface、其记录 kind/ID 与用户请求不一致”以及正确操作；日志保留结构化阶段名。保留现有“当前 pane 恢复”语义。如要增加“从任意位置恢复某 surface”，应设计单独的控制 socket 指令，在目标 pane 内执行，并处理已存活、重复认领和用户权限；不要悄悄改变 `--surface` 的执行位置。

## 7. 代码落点建议

| 文件/模块 | 建议工作 |
| --- | --- |
| `Sources/SessionPersistence.swift` | 增加版本化的 `TerminalRecoveryObservation`，保留旧字段解码与迁移；定义历史容量/存储引用。 |
| `Sources/Workspace.swift`、`Sources/DockSplitStore+SessionSnapshot.swift` | 两条 snapshot 构造路径都接入同一观察模型；移除用 `wasAgentRunning` 单布尔值做最终恢复决策的路径；统一 scrollback 采集/恢复条件。 |
| `Sources/AppDelegate.swift` | 将 8 秒 autosave 与低频状态核对调度拆开；终止/关机时最终核对和历史采集；确保异步扫描不会覆盖更新的结果。 |
| `Sources/ProcessDetectedResumeIndexes.swift`、`Sources/SurfaceResumeBindingIndex.swift`、`RestorableAgentSessionIndex` | 复用共享扫描和 surface 绑定；输出证据及采集时间，而不只是“可恢复会话”列表。 |
| `Packages/macOS/CmuxWorkspaces/.../RestorableAgentProcessLiveness.swift` | 将进程仍存活、属于哪个 surface、agent 身份完整性分开表达；防 PID 复用。 |
| `Packages/macOS/CmuxWorkspaces/.../WorkspaceSessionRestorePolicyService.swift` | 输入统一 `RecoveryPlan` 所需事实；明确普通终端、agent、tmux/远程和 unknown 的历史显示与启动策略。 |
| `Sources/AgentResumeLaunchGuard.swift`、`Sources/AgentResumeLiveness.swift` | 沿用重复启动保护，并补充“启动后证实”与失败重试状态。 |
| `CLI/CMUXCLI+Restore.swift`、`Packages/macOS/CMUXAgentLaunch/.../AgentResumeArgv.swift` | 改善 pane 范围错误说明，测试 Grok 的准确 ID 恢复；若扩展跨 pane 操作，显式新增 API。 |

以上是调查入口而非预先要求逐个修改。应先找现有模型与测试可复用的边界，再做最小必要改动。不要为了此功能重写整个 agent 跟踪体系。

## 8. 推荐实施顺序与验收

1. **先锁定语义。** 加入状态模型、旧快照迁移、单 pane 恢复计划及诊断输出；用真实的 surface 归属证据判断 agent 身份。
2. **再接入定时核对。** 共享一次扫描，默认五分钟；事件只负责提速。度量空闲 CPU、扫描耗时、主线程阻塞、磁盘写入及 10/50/100 pane 情况，再决定默认间隔和节流。
3. **补齐普通终端历史。** 有界采集、原子写盘、可见历史恢复；覆盖 agent 退出后回到 shell 的情况。
4. **最后统一特殊路径和 CLI。** 远程/tmux/休眠优先级、Grok 手动恢复报错、重复恢复与失败重试。

至少覆盖以下行为测试，而不只测试字段序列化：

- Grok/Claude/Codex 在某 pane 启动，记录准确 kind 和 ID；回答结束的 `Stop` 不被当成进程退出；真正退回 shell 后下一轮更新为 `shell`。
- 同 pane 从 agent A 切到 B、同类型更换 session ID、无 hook 启动、遗漏 hook 后下一轮自愈；旧异步扫描不能覆盖新结果。
- 同目录多个 pane 不串 session；PID 复用不误判；两个 pane 指向同一 session 不重复启动。
- 普通 shell 的 cwd 与有界 scrollback 在崩溃/正常退出后可见；历史不会被送进 shell 执行。agent 启动失败后保留可重试记录。
- 扫描失败与远程暂不可达显示 unknown，不误判为退出；tmux/持久化 PTY 能附着时不重复启动 agent。
- 旧快照迁移后仍可手动找回旧 ID；`cmux restore grok <id>` 在正确/错误 pane 的结果和提示准确。

**完成标准：** 每个恢复出的终端都能说明“快照何时采集、当时是什么状态、绑定哪个 session、为何自动恢复或没有自动恢复”；普通终端保有可见上下文；Grok 与其他支持的 agent 依据同一 per-surface 规则准确恢复；资源消耗在多个 pane 下有实测数据。
