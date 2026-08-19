# newbee — 会自我进化的 Elixir 编程 Agent

**状态**: M4 已实现（280 tests / DEE 双节点 / J-Space / PPT/Progress 落地），M5 基因库进行中
**语言**: Elixir

---

## 0. 已确认的设计决策

| 议题 | 决策 |
|---|---|
| **长期运行粒度** | **跨工程**：DEE 环境与记忆跨项目持久化；全局状态(工具库/记忆/缓存)与项目级状态分层存储，任意新工程可复用已有积累 |
| **沙箱策略** | **宽松(Lenient)**：默认直接放行文件读写与常用命令，仅对少数高风险操作(删目录、rm -rf、推送远端、修改环境内核文件)做审计记录；不做强制审批，靠审计日志与 git 快照回滚兜底 |
| **打底模型** | **OpenRouter · `deepseek/deepseek-v4-flash-0731`**（已在 OpenRouter API 验证存在：1.31M 上下文、支持 tools/function calling、约 $0.14/$0.28 每百万 token，极便宜）；LLM 层做成多后端适配器，默认走 OpenRouter，后续可切换 local 等其他后端 |
| **TUI 框架** | **M1 用 `ratatouille`(ELM 风格) 快速搭建**，渲染内核封装在 `Newbee.TUI.Renderer` 接口之后，后续可平滑替换为自研 ANSI，避免被单一依赖锁死 |
| **UX 范式** | **对齐 codex / pi**：单列流式对话、折叠工具块、内联 diff、`/`命令、`@文件`、`!shell`、Esc 打断——程序员零学习成本上手；差异化全在内核(DEE)，不在操作习惯上 |
| **模型操作语言** | **Elixir**：模型、工具、宿主环境同语言 |
| **上下文策略** | **极简主义（光头优先，§1.1）**：知识住环境不住 prompt，pull over push，可见工具面封顶 3 个 |

---

## 1. 一句话愿景

> **newbee 不是"让大模型替你写 Elixir 代码"，而是"把一个大模型放进一个长期运行的、动态的 Elixir 环境里，让它自己用 Elixir 作为手和脑来编程、操作文件、调用工具、构建工程，并反过来持续优化这个环境本身"。**

传统编程助手（Claude CLI、Codex 等）的工作方式是：模型输出文本 → 工具/沙箱**临时**执行 → 返回有限的结果 → 结束。模型与执行环境是一次性、松耦合、无记忆的。

newbee 反其道而行：给模型一个**持久、有状态、可编程、可自修改**的 Elixir 运行时环境。更精确地说，是给模型一个**它专属的 IEx**：变量跨轮存活、工具随用随写随热载、工程可探可改可测。时间一长，这个环境会积累它自己的工具库、约定、缓存与策略——**越用越懂、越用越省、越用越准**。

### 1.1 第一性原则：上下文极简主义（光头优先）
实验证明：工具面极简的 harness 在任务**质量**上优于挂满 skill 的重型 harness——上下文臃肿不只是贵，是**变笨**（注意力稀释、指令冲突、无关知识挤占工作记忆）。由此确立 newbee 的第一性原则：

- **知识住环境，不住 prompt**：系统提示词保持极小；工具、规则、记忆全部沉淀在环境里，默认一个字的文档都不注入。
- **拉而非推（pull over push）**：传统 harness 把知识防御性地"推"进 prompt；可编程环境让模型按需"拉"——`Newbee.Env.*` 自省、按需读文档、RepoMap 定位后再取细节。
- **工具面 = 3 个**：`run_elixir` / `done` / `ask`，封顶。新能力永远进环境（工具库），不进工具面。
- **JIT 阶梯是极简主义的引擎**（§6.2）：环境每编译掉一个模式，模型的上下文需求就永久降一分。**光头不是起点，是环境收敛的方向。**

---

## 2. 与 Claude CLI / Codex 的核心差异（创新点）

| 维度 | Claude CLI / Codex | **newbee** |
|---|---|---|
| 执行模型 | 一次性、临时、无状态沙箱 | **长期运行、有状态、可持久化**的 Elixir 环境 |
| 模型与环境的交互 | 模型输出文本，工具被动执行 | 模型是环境里的"首要用户"：**写 Elixir 代码、调用它的库、运行并检查结果** |
| 中间结果 | 每轮重新计算/重传 | **绑定持久化**：变量跨轮存活，像 IEx 一样直接引用 |
| 记忆 | 无 / 靠上下文 | 环境内持久化的**记忆、缓存、工具库、策略** |
| 工具的形态 | 预定义固定工具集 | **工具即运行时脚本**，模型可调用、可新增、可热载、可修改 |
| 自我进化 | 无 | **环境可自我重构**，且能把"多轮推理"**固化成零 token 的纯函数** |
| 环境目标函数 | 完成单次任务 | 持续优化（省 token / 高智能 / 高准确 / 最优），由内置评测台裁判 |
| 工作存储 | 临时目录 | **工程的 live 编辑、运行、测试都在同一环境里闭环** |
| 上下文 | 挂满 skill / 长系统提示 | **光头**：知识在环境里按需拉取，prompt 极简（§1.1） |

**一句话**：Claude CLI 是"模型吩咐工具干活"，newbee 是"模型住在一个它自己造的、能改的房子 (Elixir 环境) 里干活"。

---

## 3. 核心概念：动态 Elixir 环境（Dynamic Elixir Environment, DEE）

### 3.1 什么是 DEE
DEE 是一个长期存活（进程型、可被 TUI 挂起/恢复）的 Elixir 运行时：

```
┌────────────────────────────────────────────────────────────┐
│                    newbee TUI (Elixir)                      │
│   ┌───────────┐   ┌────────────────────────────────────┐   │
│   │  会话视图  │   │       动态 Elixir 环境 (DEE)       │   │
│   │  diff/日志 │   │  ┌──────────────────────────────┐ │   │
│   │  token监控 │   │  │ 求值器节点 (独立 BEAM node, │ │   │
│   │  模型输出  │   │  │  Code.eval + 持久 bindings)  │ │   │
│   └───────────┘   │  │   ┌────────┐ ┌──────────┐    │ │   │
│                   │  │   │ 内核    │ │ 工具库    │    │ │   │
│   大模型 (LLM)    │  │   │(dispatch│ │ ~/.newbee/│    │ │   │
│   ┌────────────┐  │  │   │  & loop)│ │ tools/*.ex│   │ │   │
│   │ API client │  │  │   └────┬───┘ │ 热载/git  │    │ │   │
│   │ 提示/记忆   │──┤  │  ┌─────┴──┐ └──────────┘    │ │   │
│   │ token记账  │  │  │  │ RepoMap │ ┌────────────┐  │ │   │
│   └────────────┘  │  │  │ 状态    │ │ 自进化引擎  │  │ │   │
│                   │  │  │(EXTS)  │ │ +评测台    │  │ │   │
│                   │  │  └────────┘ └────────────┘  │ │   │
│                   │  │  ┌────────────────────────┐  │ │   │
│                   │  │  │ 持久化层 (ETS/DETS/SQLite)│  │ │   │
│                   │  │  └────────────────────────┘  │ │   │
│                   │  └──────────────────────────────┘ │   │
└────────────────────────────────────────────────────────────┘
```

### 3.2 环境的能力（全部可由模型通过 Elixir 调用）
- **代码 IO**：读文件、写文件、追加、复制、移动、删除、遍历工程树。
- **双轨编辑**：
  - **文本轨 · 哈希锚点编辑**：`show` 给每行生成 `N#hash| 内容` 锚点（MD5 前 4 字节，8 位 hex）；`patch` 按**锚点对**（目标行 + 相邻行上下文 `N.#h|M.#ch`）定位，行号只是提示——数错行自动重定位，数错且对不上整体拒绝；上下文必填，空行/重复行靠锚点对消歧（show 标记 `[dup:...]`）；快照 tag 过期只警告（锚点对才是新鲜度检查）；多节补丁全部验证通过才统一落盘（原子）。消灭 string-not-found 重试循环这个最大 token 黑洞，显著降低编辑 token 消耗与失败率。
  - **结构轨 · Sourceror**（保留格式与注释的 AST 重写）：按 `模块::def`/AST 定位替换、`rewrite`、`mix format`、lint。这是选 Elixir 的最大技术红利——Claude/Codex 用 regex/diff patch 做不到保证可解析的结构化修改。
  - 分工：Elixir 工程走结构轨，其余一切文本走锚点轨。
- **运行**：`mix run`、`mix test`、`mix compile`、`elixir -e`、求值、执行任意 shell 命令。
- **工程**：`mix new`、`mix deps.get`、依赖管理、项目脚手架。
- **工具库**：`Newbee.Tools.*`（git 操作、搜索、AST 查询、文件 diff、JSON 处理、HTTP、正则等）。
- **统一寻址**：一个 `Newbee.read/1` 通吃文件、目录、URL 与内部 scheme——`memory://`、`skill://`、`agent://<id>/findings`（从子代理结果按路径抠字段）、`conflict://N`（写 `@theirs`/`@ours` 解决合并冲突）。只教模型一个接口。
- **内省**：模块文档、`Code.string_to_quoted`、`beam_lib` chunk 信息、类型信息。
- **记忆/状态**：读写全局或项目级持久化状态。
- **模型/调度**：向 TUI/LLM 发回"计划、进度、结果、需要确认、需要更多上下文"等信号。

### 3.3 绑定持久化（Bindings Persist）—— "模型的 IEx" ⭐核心创新
求值器像 IEx 一样维护**跨轮存活的变量绑定**：模型第 N 轮 `content = Fs.read!("lib/foo.ex")` 读入的 50KB 内容，第 N+1 轮直接 `content |> Ast.list_defs()` 引用——**不必重读、不必塞回上下文**。
- 中间结果（大文件内容、AST、搜索命中列表、测试报告）都留在环境侧的 binding 里，模型只持有**变量名**。
- 这是比"结果压缩"高一个量级的省 token 手段，也是 DEE 区别于一切"每次调用都是新沙箱"工具的物理本质。
- 实现：`Code.eval_string/3` 显式传入/取出 binding，存于求值器 GenServer 状态；会话恢复时绑定**值**可序列化（不可序列化的进程引用等置为 tombstone）。
- 模型可查询当前绑定清单（`Newbee.Env.bindings()`：名字 + 类型 + 大小的摘要，不回传内容本身）。

### 3.4 求值器隔离：独立 BEAM 节点
求值器**不与主进程同 VM**：模型代码运行在一个独立的 BEAM 节点（分布式 Erlang 原生 RPC，同机 spawn），主进程（TUI/会话/记忆/内核）与之一对一监督。

- **崩溃隔离**：模型代码里的 `System.halt`、NIF 崩溃、死循环耗尽，最坏只杀死求值器节点——主进程监督重启它（死则替换、当前调用重试一次），TUI 和会话毫发无损。自进化系统的前提：环境在进化中必然写出有 bug 的代码，宿主必须免疫。
- **绑定仍持久**（§3.3）：binding 存于求值器节点，跨轮存活不变；`reset` 语义 = 重启节点换新绑定。
- **环境过滤**：节点启动注入过滤后的 env——**denylist 剥离所有 LLM API key**（模型代码不应读到宿主凭证）。
- **工具回调仍无缝**：分布式 Erlang 节点间调用透明，模型代码里 `Newbee.Tools.*` 照常调用，背后是节点 RPC。
- **宿主契约（Host Bridge）**：求值器节点**不持有任何凭证、不直连 provider、不直写 transcript**。一切权威操作（调模型、代理间消息、审计日志、调度）都经 `Newbee.Host.*` 类型化请求，由主节点校验后执行。模型能改造环境的三层（§3.7），但物理上碰不到宿主的心脏——宽松策略管"行为"，宿主契约管"能力"，后者不依赖模型自觉。
- **会话挂起/恢复**：恢复的仍是状态与绑定值；节点本身总是重建。

### 3.5 工具即脚本 + 热代码升级 ⭐核心创新
BEAM/OTP 的超能力：**环境升级自己不用重启**。
- 工具**不写进 newbee 主应用源码**，而是放 `~/.newbee/tools/*.ex`（全局）与 `<project>/.newbee/tools/*.ex`（项目级），运行时 `Code.compile_file` 热加载。
- 工具目录用 **git 版本化**：每次模型新增/修改工具 = 一次 commit，天然获得回滚与审计。
- **主内核永远只读**：模型能改的只有工具层/提示层/记忆层，自我进化破坏核心系统的风险在架构上直接消除（回答了 §12 的权限边界问题）。
- **工具即文档**：工具模块的 `@doc` 自动汇集注入 prompt——自文档化，模型新增工具后立刻对自己可见，prompt 无需手工维护。
- 热替换失败（编译错误）不影响运行中的旧版本，符合 BEAM 语义。
- **Effect 回收 = 监督树语义**：每个热载工具是一个 OTP 子树，它的 ETS 表、事件订阅、注册名全归这棵子树所有；deopt/卸载 = 终止子树，所有 effect 自动陪葬——**零悬挂注册**。这是 §6.2 deopt 敢做的底座：环境的任何部件都能干净地"长出来"和"缩回去"。

### 3.6 RepoMap —— 工程结构图
给模型注入**紧凑的工程结构图**而非整文件：
- 从 AST / `.beam` chunk 提取：模块名、`@moduledoc` 摘要、公开函数签名、关键 struct 字段，压缩成分级大纲。
- 每次会话开始/工程变更后增量更新并缓存；注入 prompt 的是 RepoMap 而非文件全文。
- 模型凭 RepoMap 定位 → 只对目标区域 `Fs.read` / AST 查询取细节。实践证明这是省 token 的第一梯队手段。

### 3.7 环境的"自我"：同心圆权限环（mutability rings）
环境没有"只读内核"也没有"万物皆可改"——像操作系统的权限环，**越靠内的环，修改所需的证据越重**：

| 环 | 层 | 修改门槛 |
|---|---|---|
| **Ring 3** | 工具层 (`~/.newbee/tools/*`) | 评测台通过 → 自动热载（最外层，日常进化发生在这里） |
| **Ring 2** | 提示层/沉睡规则 | 评测台通过即可 |
| **Ring 1** | 记忆层/策略层 | 项目局部生效，跨项目验证后晋升全局 |
| **Ring 0** | 内核 + 宿主契约 (`kernel.ex`, `Newbee.Host.*`) | **完整反事实回放（§6.3）+ 人工签署** |

Ring 0 不是不能改，是代价极高——环境理论上可以进化自己的内核，但每一次都要过最重的裁判。权限环让"自我进化"在每一层都有与之相称的安全边际。

### 3.8 代理拓扑：常驻 daemon、worker + evolver 双角色 ⭐

**环境是常驻生命体，TUI 只是探视窗。** OS 层面：newbee **daemon**（常驻主节点：会话/记忆/内核/代理们/调度器，OTP 监督树）+ **求值器节点**（§3.4，唯一跑模型代码的地方，可被杀可重启）+ **TUI 客户端**（可 detach 的薄客户端——关掉终端不停止环境，`newbee attach` 随时接回。"跨工程长期运行"由此落地：环境在终端关闭后依然存活、记忆、进化）。

代理分两个角色，通过事件溯源日志解耦通信：

```
主代理 worker (1 个)                  专职进化代理 evolver (0..1 个, 后台)
─────────────────────                ─────────────────────────────
干活时察觉重复模式                     空闲/定时触发，读取：
  ↓ 只做一件便宜事                     · 事件日志(§6.5) + 指标
  往事件日志写一条"进化线索"            · worker 留下的进化线索
  ("这个模式第3次出现了")               ↓ 做所有贵的事
  ↓ 继续干活，不分心                    提炼工具 → 写测试 → 评测台验证
                                       ↓
                                       按策略：提请批准 / 自动合并+热载
                                       失败 → revert，归因干净
```

**为什么不让 worker 顺便做进化**（这是深思熟虑的决策，不是偷懒）：
1. **激励错位**：worker 当下的目标函数是"完成任务"，不是"环境长期变好"；中途进化要么敷衍、要么拖慢用户。
2. **视野不够**：最有价值的进化信号是**跨任务模式**（"这周出现 5 次"），只有旁观全局的 evolver 看得见。
3. **归因污染**：worker 任务中途改了环境，任务失败时无法区分"任务难"还是"新工具有 bug"——变异与执行必须隔离，因果才干净。
4. **不占前台**：复盘推理很烧 context，放后台不进主循环。

**为什么不让 evolver 全包**：它没亲历任务，"当时哪里痛"的高保真信号在事后日志里难完全还原——所以 worker 保留**写一句话进化线索**的轻量通道（几乎零成本、不分心），evolver 做贵的综合部分。分工原则：**worker 供信号，evolver 做合成，bench 做裁判**。

**其余并发子代理**：同一 VM 内还可临时 spawn 探索/测试子代理（共享 ETS 记忆、独立 LLM 上下文，监督树兜底；并行改代码时用 **git worktree 隔离**，返回 **schema 校验的结构化结果**而非散文。相对 Python/Node 系 CLI 的并发模型，这是 Elixir 的结构性优势。

**可选第三角色 advisor**：一个只读旁观的第二模型，读 worker 的每一轮输出并内联插评（concern/blocker），worker 看到后自我纠偏。与 evolver 互补：advisor 管当下质量，evolver 管长期进化。默认关闭，按模型角色路由配置开启。

**模型角色路由**：`default`(worker) / `evolver` / `explorer`(最便宜) / `advisor` / `plan` 等角色各自绑定不同模型，成本与能力按意图分配。

## 4. LLM 与环境的交互协议

### 4.1 循环（The Loop）
```
         ┌──────────────────────────────────────────┐
         │                                          ▼
  用户意图 ──▶ TUI ──▶ 组装 Prompt(记忆+工具清单+RepoMap+绑定摘要)
                        │
                        ▼
                     LLM 响应 (function calling)
                   ┌────────────┐
                   │ 计划/文本    │
                   │ run_elixir │◀──── code 参数 = 自由 Elixir 代码
                   └─────┬──────┘
                         ▼
                   DEE 求值器 (持久 bindings)
                         │
                         ├── 正常返回 ──▶ 结果(可选精简) ──▶ 反馈给 LLM
                         ├── 编译/运行错误 ─▶ 完整错误信息 ──▶ 反馈给 LLM
                         └── 需要人确认 ─▶ TUI 暂停, 等待用户 ──▶ 恢复
                         ▼
                   (loop) 直到用户满意 / 手动停止
```

### 4.2 协议：function calling 包裹自由代码（混合式）
裸文本 `<elixir>` 块组合性强但解析脆；纯离散工具调用又损失组合性。newbee 取两者之长：

**主协议（function calling）**——暴露给模型的工具面极小，只有几个：
| 工具 | 参数 | 说明 |
|---|---|---|
| `run_elixir` | `code: string` | 在 DEE 求值器执行任意 Elixir（可调用所有库与工具，binding 持久）。**主力通道** |
| `done` | `summary: string` | 声明本轮目标完成，附带给用户的总结 |
| `ask` | `question: string` | 需要用户确认/澄清，TUI 暂停等待 |

- deepseek v4 flash 原生支持 tools，tool call 解析稳定，不会出格式错误。
- `code` 参数内仍是**自由 Elixir**：循环、条件、批量处理、一次调用做多件事——组合性不丢。
- **降级通道**：模型偶发在文本里输出 ` ```elixir ` 代码块时，容错解析器兜底执行（并温和纠偏）。

### 4.3 结果反馈的 token 控制
- 执行结果的返回**默认做压缩**：截断、摘要、只返回 exit code + stdout 尾部 / diff 统计。
- 模型可在代码里主动控制返回量（自己先 `Enum.take`/`filter` 再 `IO.inspect`——**让模型写代码过滤，而非靠 LLM 摘要**，确定性压缩）。
- 长输出写入文件并给模型文件路径 + 行数摘要，而非全文塞回上下文；或存入 binding 留待后续引用（§3.3）。

### 4.5 沉睡规则：环境的免疫系统 ⭐
常规教训全塞进 system prompt 会让 prompt 无限膨胀。沉睡规则反其道而行：

- 规则平时**沉睡，不占 context**；每条规则带触发条件（regex 或 AST 模式），**实时监控模型的输出流**（正文、thinking、工具参数）。
- 命中条件的瞬间：**中断流 → 把规则作为 system reminder 注入 → 从断点重试**。模型在犯错的当口被当场纠正，而非事后返工。
- 注入**在 compaction 后依然存活**，纠偏不会因上下文压缩而丢失。
- 例：进化中发现"模型反复在非测试代码里用 `IO.inspect` 调试" → 编译成沉睡规则，下次模型再打出 `IO.inspect` 时当 token 拦截注入禁令。
- **这是自我进化产出的主要容器**（见 §6.4）：学到的教训编译成沉睡规则，而非 prompt 文本——"平时零成本、犯病才出现"。

### 4.6 事件总线与 turn/step 状态机
全系统**一条事件总线**，分两个域：

- **durable 事实**：`turn/*`、`step/*`、`user/message`、`assistant/*`、`tool/*`——追加进事件日志（§6.5），重启存活；
- **live 拦截点**：`agent/pre-step`（可拒绝或改写输入）、`llm/stream`（沉睡规则的监控面，§4.5）、`tools/pre-execute`（守卫管道）——不落盘，供策略与观察用。

**状态机**：一个 **turn** = 0+ 个 **step**（一次模型请求 + 它引发的工具调用）。turn 在首个输入被认领前开启，在"不再欠任何调用"时关闭；`pre-step` 拒绝或以空消息进入 → 直接关闭 turn 不产生 step。

**一切订阅同一条总线**：TUI 渲染、指标采集（§6.1）、沉睡规则、审计日志（§8）、evolver 触发——五个消费者，零各自为政的监听点。

## 5. TUI 界面设计（对齐 codex / pi 的交互范式）

**原则：交互模仿 codex / pi 等主流工具，让程序员零学习成本上手；差异化全部藏在内核（DEE），而不是让用户学一套新操作。**

### 5.1 交互范式（抄最熟的作业）
- **单列流式对话布局**（同 codex / pi / Claude Code）：滚动 transcript，用户消息、模型输出、工具调用块、diff 依次流式追加；**不做默认多窗格**（窗格作为可选 toggle）。
- **工具调用块折叠**：`run_elixir` 在 transcript 中显示为可折叠块（默认显示代码 + 压缩结果摘要，方向键展开看完整 stdout），与 codex 的工具块体验一致。
- **底部多行输入框**：Enter 发送、Shift+Enter（或 `\` 续行）换行、↑/↓ 历史、Tab 补全。
- **Esc 打断**模型执行；**Ctrl+C** 退出当前输入/双击退出程序——与 codex 一致。
- **内联 diff 渲染**：写文件/编辑以带语法高亮的 inline diff 展示在 transcript 里（同 codex），`/approve` 与否的提示也内联出现。
- **状态栏**（底部一行）：当前模型、项目、会话、累计 token / 花费、环境绑定数——信息密度对齐 codex 的 status line。

### 5.2 布局（默认单列流式，可选窗格）
```
newbee  ── project: newbee  ── model: ds-v4-flash-0731  ── session #12
────────────────────────────────────────────────────────────
› 帮我给这个模块加一个并行 mapreduce 函数，并写测试

● 我先看一下工程结构。
  ⏺ run_elixir                          ✓ exit 0 · 12 行
  │  mods = RepoMap.modules() …           [Tab 展开]
  ● 找到 lib/parallel.ex，准备插入新函数。
  ⏺ run_elixir                          ✓ wrote lib/parallel.ex (+28 -0)
  ┌─ diff lib/parallel.ex ────────────────┐
  │ +  def map_reduce(coll, m, r) do …    │
  └───────────────────────────────────────┘
  ⏺ run_elixir (mix test)               ✓ 8 tests, 0 failures
● 完成：新增 map_reduce/3，测试全绿。

────────────────────────────────────────────────────────────
› ▊                                                    [⏎发送]
  tokens: 12.4k in / 1.8k out · $0.002 · bindings: 3 · lenient
```
- 可选窗格（`Ctrl+T` 切换）：工程树 / 绑定清单 / 事件日志，默认收起，保持 codex 式的极简主界面。

### 5.3 命令与快捷键（对齐 codex / pi 习惯）
| 输入 | 行为 |
|---|---|
| `@文件路径` | 引用文件（Tab 补全），把文件加入模型视野 |
| `!命令` | 直接在 DEE 里执行 shell 命令，输出进 transcript |
| `/init` | 扫描工程生成 `NEWBEE.md`（项目说明/约定，兼容读取 `AGENTS.md`/`CLAUDE.md`） |
| `/model <id>` | 切换模型后端 |
| `/diff` | 查看会话累计 diff |
| `/undo` | 回滚到上一个 git 快照/工具版本 |
| `/bindings` | 查看环境绑定清单（名字+类型+大小，不含内容） |
| `/tokens` | token 记账详情 |
| `/compact` | 压缩对话历史（环境状态与绑定不受影响） |
| `/approve` `/permissions` | 审批与权限档位（`lenient`/`ask`/`deny`） |
| `/session save|load` | 会话挂起/恢复 |

环境常驻 daemon（§3.8）：关掉 TUI 只是 detach，环境继续存活与进化；`newbee attach` 随时接回。
| `/tools` | 查看/管理热载工具库 |
| `/dump` | 环境自画像：打印当前生效的完整组合树（工具/规则/记忆/策略）；用户调试用，模型也可自省「我现在的身体由什么构成」 |
| `Esc` / `Ctrl+C` / `Ctrl+T` | 打断 / 取消输入 / 切换窗格 |

### 5.4 项目记忆文件
- 每个工程根目录可有 **`NEWBEE.md`**（项目约定、常用命令、架构说明），会话开始自动注入——与 codex 的 `AGENTS.md`、Claude Code 的 `CLAUDE.md` 同一约定，**若已存在 `AGENTS.md`/`CLAUDE.md` 则直接读取复用**，降低迁移成本。

### 5.5 技术选型（已定）
- **前端**: `ratatouille`（ELM 风格）做单列流式布局足够胜任；渲染器封装在 `Newbee.TUI.Renderer` 接口后，可替换为自研 ANSI。
- **风险预案**：ratatouille 依赖的 termbox 上游已停更，与新版 Elixir/OTP 兼容性需 **M1 第一天验证**；不兼容则启用自研 ANSI 渲染器（单列流式布局渲染逻辑简单，自研成本低）。
- **进程模型**: GenServer + 事件总线，DEE 与 TUI 消息解耦；LLM 流式输出增量渲染到 transcript。

### 5.6 J-Space 工作协议（来源 `priv/prompts/system.md:21-58`）

> 工作协议：内层工作区思考先于输出，稠密可按需展开；自动化部分（语法、格式、惯例）不占内层工作区。

- **Gate 分流**（动手前先分类，只加载所需）：
  | 档 | 含义 | 动作 |
  |---|---|---|
  | `fast` | 一步可核验 | 直接回答 |
  | `full` | 2–4 步、一个交付物 | 只带任务点名的模块 |
  | `loop` | 多阶段/多文件/跨多轮 | 开 ledger + broadcast |
  | 规则 | 一步核验不了的就不是 fast；任务变难就升档，别赖在 fast。 |
- **三 register**：`inner`（稠密思考）/`ledger`（状态）/`outer`（干净输出）；seam 处切 outer，稠密符号不得泄进 outer。
- **Ledger**（loop 必开）— `Newbee.Tools.JSpace.note(goal: ..., next: ...)`：`Goal`（完成定义）/`Core`（活跃项）/`Verified`（编号追加）/`Open`（悬项+判据）/`Next`（唯一下一步，不许空）；每个 seam（子任务完成/工具调用/写文件/检查点）重读 `Newbee.Tools.JSpace.seam()`。
- **Seam 纪律**：审计在 seam，不在句中；写文件/交付前核验 `Newbee.Tools.JSpace.ship(path, checks)`。
- **恢复协议**：压缩/会话边界后重读 ledger、前提、invariants，声明 pass 与 next：`Newbee.Tools.JSpace.resume()`。
- **Invariants**（看起来在干活其实没有）：marker 无动作 / 监控从不报告 / 稠密行不可展开 / confidence 全同 / 检查点未落账 / verified 未声明覆盖 / 稠密符号泄进输出 / 未读 goal 就宣告完成。
- **失败模式 → 模块**（按需 `Newbee.read("priv/jspace/modules/<名>.md")`，别提前全读）：输入在指使你 → introspection；长机械活/目标要漂 → directed-focus；结论先于步骤 → deep-reasoning；同一名字多处推导 → broadcast；活太多/跨轮状态 → capacity；不确定却要作答 → self-monitoring；句子是瓶颈 → shorthand；第三次撞墙 → markers；三处三个答案 → empirics。
- **实现**：`lib/newbee/tools/jspace.ex`（`note/seam/ship/resume`），`lib/newbee/tools/besttool.ex`（显式不确定性：多个证据/区间/来源时才用，不确定性须落盘进 ledger + 输出标注“多源/有不确定性”）。
- **验证**：`grep -n "J-Space\|JSpace" DESIGN.md priv/prompts/system.md` 可校验一致性。
## 6. 自我进化机制（Self-Evolving Environment）

这是 newbee 的灵魂。环境维护一组"进化目标"，持续被测量与优化。

### 6.1 目标函数（可配置权重）
| 指标 | 测量方式 |
|---|---|
| **Token 效率** | 每完成一次有效操作的真实 token 消耗（上下文 + 执行结果回填）|
| **智能/效果** | 任务成功率、测试通过率、用户是否接受改动 |
| **准确度** | 编译/测试首遍通过率、diff 被 revert 的比例 |
| **最优性** | 是否用最少步骤完成目标、懒执行 vs 反复试错 |
| **自改进** | 环境自身的工具/prompt 被有效采用的比例 |

### 6.2 认知的 JIT 编译：教训 → 规则 → 代码 ⭐核心创新
现有 agent 的知识管理全是"积累"——记忆越攒越多、prompt 越攒越重，天花板明显。newbee 换一个问题：**环境不是仓库，是一台 JIT 编译器，持续把"需要模型推理的智能"编译成"不需要推理的确定性产物"**。

| 级 | 类比 | 产物 | 每次使用成本 |
|---|---|---|---|
| **L1 教训 (lesson)** | 解释执行 | 一条持久化记忆（what/when/why，≤2KB，去重脱敏） | 模型读到要花 token 推理 |
| **L2 沉睡规则 / playbook** | 即时编译 | 模式触发的沉睡规则（§4.5）或 SKILL.md 式片段 | 平时零，触发时极少 |
| **L3 蒸馏工具 (distilled skill)** | 原生编译 | **纯 Elixir 函数**进 `~/.newbee/tools/`，带测试 | **调用零 token** |

JIT 的三个标志性机制，一一对应：

- **热度剖析（profiling）**：事件日志统计每个模式的 **出现频率 × 单次 token 成本 = 编译收益**；只有越过编译阈值（收益 > 编译成本）才晋升——不热的模式永不编译，避免过度工程。
- **编译（compile）**：evolver 执行晋升。例："找到所有调用某函数的模块并批量改名"第一次花了 12 轮推理；固化成 `Newbee.Tools.Refactor.rename_callers/3` 后，一次 tool call 完成。
- **去优化（deopt）**：L3 工具被评测台判退化时，**降级回 L2 规则而非删除**——假设失效就去优化，知识不丢，等条件合适重新编译。

模型每固化一个模式，对自身智商的依赖就降一分——**环境在字面意义上变聪明，同时变便宜**。

### 6.3 进化的裁判：失败抗体 + 反事实回放 ⭐核心创新
没有 ground truth 的自我优化必然 Goodhart（环境会优化"看起来省 token"而非真省）。固定基准题（`priv/bench/` fixture 工程 + 验收标准）只是起点，newbee 的裁判系统有两个超越固定 bench 的活机制：

- **失败抗体（failure antibodies）**：worker 每次**真实失败**（测试不过、diff 被 revert、用户拒绝、编译反复报错）自动生成一条回归测试永久进入 bench。bench 随使用**单调增长**——环境在同一个错误上不会犯第二次。这反过来解锁了进化的激进度：安全网随使用变厚，evolution 档位才配开到 `:auto`。
- **反事实回放（counterfactual replay）**：事件溯源（§6.5）存了历史会话的完整轨迹。验证进化补丁时不只跑固定考题，还**把近期真实会话的关键片段用新环境版本回放**，对比新旧版本的实际 token/成功率——用真实使用当裁判，而非人造考题。固定 bench 的问题是题目会过时、不代表真实分布；回放永远代表。

外加两条工程约束：
- 评测由 evolver 在后台运行，消耗少量 token（deepseek v4 flash 极便宜，经济上成立）。
- **按模型分别度量**：harness 质量主导模型表现，同一 prompt 换模型结果天差地别——prompt 变体、编辑协议、工具清单的优劣，都要对每个候选模型单独跑分，允许按模型选择不同契约。
- 用户验收（`/approve` 与否）也作为真实世界信号回流到指标。

### 6.4 进化载体
1. **工具库扩展 (`~/.newbee/tools/`)**：worker 线索 + 重复模式 → evolver 合成新工具 → 评测台验证 → 热载注册。
2. **Prompt 演进**：有效的系统指令、few-shot、**Elixir 惯用法手册**固化到提示层（版本化）；**教训一律编译成沉睡规则（§4.5）而非 prompt 文本**，防止 prompt 无限膨胀。
3. **记忆/索引 (EXTS)**：后台管线逐会话抽取 → 跨会话合并 → 会话开始注入**有 token 上限**的 Memory Guidance 块；记忆条目去重、最新在前、**自动脱敏**（剥离密钥）、设上限；prompt 显式声明"记忆是启发式不是权威，与仓库现状冲突时以仓库为准，引用记忆须标注来源路径"。
4. **缓存与压缩策略**：模型可调整"结果回填压缩比""何时 fetch 全文"等参数。

### 6.5 事件溯源：上下文是日志的物化视图 ⭐
每次环境变异（工具新增/修改、prompt 变更、策略调整、评测结果）记为一条**事件**，追加进持久日志。核心心智模型：**LLM 看到的上下文不是日志，而是日志的物化视图（materialized view）**——

- **compaction = 视图维护**：压缩改的是视图，不动日志，原始事件永远完整；
- **沉睡规则在每次构建视图时重新应用**——这是 §4.5"compaction 后依然存活"的底层解释，不依赖上下文残留；
- **反事实回放 = 旧日志 + 新视图构建器**（§6.3 的实现定义）：同一段历史，换上进化后的环境重新投影，即得新旧版本的真实对比；
- 日志同时是回滚的数据基础与进化的审计网：可回答"环境是怎么一步步变好/变坏的"，任意时间点可重建。

### 6.6 进化循环（worker 供线索 / evolver 做合成 / bench 做裁判）
```
worker 干活 ──顺手写"进化线索"──▶ 事件日志(§6.5) + 指标(§6.1)
                                        │
                       evolver 后台触发(空闲/定时/线索累积到阈值)
                                        ▼
                        诊断(哪个环节浪费/出错, 跨任务视角)
                                        ▼
                        提出最小改进(写 Elixir 工具/prompt 补丁)
                                        ▼
                        评测台验证(§6.3, 对比基线) ──不达标──▶ revert(事件溯源/git)
                                        │达标
                                        ▼
                        按 evolution 策略：提请用户批准 / 自动合并 + 热载
```
- **进化与执行严格隔离**：变异永远发生在任务间隙的后台，worker 干活的进程内不改环境——保证任何任务失败都能干净归因。
- **补丁纪律**：每次进化改动必须**小**（最小相关单元，禁止成片重写）、**有据**（指向事件日志中的具体证据）、**带 before/after 快照**（一条进化 = 一个回滚单元）；默认**项目局部**生效，跨项目验证成熟后才晋升全局。
- **evolver 由 daemon 调度器驱动**（heartbeat/cron 触发），携带 **token 预算上限**——进化本身也要过成本关。
- **激进程度由策略层 `evolution` 档位控制**（`policies.ex`）：
  | 档位 | 行为 |
  |---|---|
  | `:off` | 不做任何进化 |
  | `:hint`（默认） | evolver 只产出"进化建议"到 TUI，用户逐个 `/approve` 后热载 |
  | `:background` | 验证通过的补丁自动热载，TUI 事后通知，可 `/undo` |
  | `:auto` | 全自动（含 prompt 层与策略层变更），仅当 bench 充分成熟后开启 |

### 6.7 进度验证器：连续分数 + 停滞干预 ⭐（LLM-as-a-Verifier 落地）

> 启发来源：Kwok et al., *LLM-as-a-Verifier*（2026）。验证是继 pre-training / post-training /
> test-time compute 之后的第四 scaling 轴；agent 不缺生成能力，缺"知道哪条轨迹是对的"。

- **问题**：主循环对模型是否在**绕路**无感知。失败轨迹的典型形态（装无关大包、反复同一方案、
  错误方向深挖）在长任务里无法被二元工具结果（成功/失败）识别——每步都"成功"但整体零进展。
- **机制**：`Newbee.Evolution.Progress` 对轨迹前缀打**连续分数**（1..20，字母刻度 A..T 单 token）。
  三轴齐备：**刻度粒度**（G=20）、**重复评估**（K 次采样，logprobs 不可用时降级）、
  **标准分解**（Specification/Output/Errors 三子标准 ensemble，替代整体 rubric）。
  logprobs 可用时对评分 token 的**全分布取期望**（连续分数，零 tie，捕获不确定性）。
- **集成**：kernel 每 `every` 步（默认 5）对 run_elixir 轨迹前缀打一次分，事件 `{:progress, score, scores}`
  流出；`stalled?`（窗口内净增长 ≤ threshold）触发**一次性干预注入**（user 消息提醒回退到高分状态），
  事件 `{:progress_stall, scores}`。verifier client 走 model.json 的 `verifier` role（无则回退 default），
  Kernel `progress:` 选项开启（默认关，opt-in 控制成本）。
- **进化闭环**：progress 分数进入 Metrics/事件日志，evolver 可把"某类任务频繁停滞"作为进化线索
  （教训 → 规则 → 工具，§6.2）；verifier 高方差（模型自己不确定）可驱动 `ask` 而非 `done`。

### 6.8 Best-of-N 进化：概率枢轴锦标赛（PPT）⭐（LLM-as-a-Verifier 落地）

> 论文 PPT 算法落地：从 N 个候选里选最优，成本 O(Nk) 而非 O(N²)。

- **问题**：evolver 合成是"单候选"——一次生成，失败即丢；生成有随机性，最优实现可能不在第一次采样里。
- **机制**：`Newbee.Evolution.PPT.select/4` 实现四步：**ring pass**（随机 Hamiltonian 环对相邻对做双槽
  比较，每个候选 A/B 槽各一次，抵消位置偏置）→ **pivot 选择**（ring-pass 累计分 top-k）→ **pivot
  tournament**（non-pivot vs pivot 全配 + pivot 内部全配，预算集中头部）→ **聚合**（w_i/c_i 归一化，
  argmax 为最佳）。比较用 `<score_A>/<score_B>` 双槽 1..20 刻度，logprobs 分布期望（连续分零 tie），
  判分器全挂时回退均匀排名。
- **集成**：`Evolver.publish/2` 对同 id 的多个 tool 候选自动分组 → `rank_tool_candidates/2` 用 PPT 选
  top-1 → 只有最优进 bench 门（抗体回放否决）。判分走 model.json 的 `verifier` role。
- **收益**：进化质量从"第一次采样的实现"提升到"N 个采样里最优的实现"，bench 通过率上升、发布回滚率下降。

---

---

## 7. 系统模块划分（Elixir 项目结构）

```
newbee/
├── mix.exs  # deps: jason ~> 1.0, req ~> 0.5, sourceror ~> 1.0；elixir ~> 1.18；telemetry/hpax/mint/finch 为 transitive
├── lib/
│   ├── newbee.ex                    # 顶层入口
│   ├── newbee/
│   │   ├── application.ex           # 监督树
│   │   ├── host.ex                  # Host Bridge（凭证/代理回主 VM，脱敏）
│   │   ├── permissions.ex           # 权限档位 lenient/ask/deny
│   │   ├── diff.ex                  # 行级 diff
│   │   ├── reader.ex                # 统一寻址 Newbee.read/1（memory:// skill:// agent:// conflict://）
│   │   ├── bus.ex                   # 事件总线
│   │   ├── event_log.ex             # 事件溯源日志
│   │   ├── session.ex               # 会话挂起/恢复
│   │   ├── memory.ex                # 全局记忆（脱敏）
│   │   ├── codec.ex + codec/fallback_parser.ex  # function calling + 降级解析
│   │   ├── tui/                     # TUI 前端（Key/Line/Screen/History/Cards/Highlight）
│   │   ├── tui.ex / cli.ex / commands.ex / staging.ex / goal.ex / cwd.ex / history.ex / debug_log.ex / markdown.ex / daemon.ex
│   │   ├── dee/                     # 动态 Elixir 环境（只读内核）
│   │   │   ├── evaluator.ex + evalworker.ex  # 独立 BEAM 节点：eval + 持久 bindings（双节点）
│   │   │   ├── kernel.ex            # 调度/循环/结果压缩（含 Progress/PPT 接线）
│   │   │   ├── rules.ex             # 沉睡规则
│   │   │   ├── repomap.ex           # 工程结构图（mtime 指纹缓存）
│   │   │   ├── tools.ex + tools/hotloader.ex  # 工具注册表/热载
│   │   │   └── result.ex            # 结果清洗/截断
│   │   ├── tools/                   # 工具库：Edit/Structural/Fs/Run/Git/Search/Json/Http/Scaffold/Introspect/JSpace/BestTool
│   │   │   ├── jspace.ex            # J-Space: note/seam/ship/resume（§5.6）
│   │   │   ├── besttool.ex          # 显式不确定性聚合
│   │   │   └── edit.ex / structural.ex / fs.ex / run.ex / git.ex / search.ex / json.ex / http.ex / scaffold.ex / introspect.ex
│   │   ├── evolution/               # 自我进化
│   │   │   ├── price_tags.ex        # 价签系统
│   │   │   ├── progress.ex / ppt.ex # Progress 验证器 / PPT 锦标赛
│   │   │   ├── jit.ex / bench.ex / evolver.ex / metrics.ex / snapshot.ex / policy.ex / gene.ex
│   │   ├── agents/explorer.ex       # 子代理（worktree 隔离）
│   │   └── llm/client.ex + llm/config.ex  # 模型客户端/配置
│   └── mix/tasks/newbee/{doctor,bench,daemon,tui}.ex
├── test/
├── priv/
│   ├── prompts/system.md            # 含 J-Space 协议（Gate/register/ledger/seam/resume/invariants，:21-58）
│   ├── jspace/modules/*.md          # 失败模式模块（introspection/directed-focus 等）
│   └── bench/                       # 评测台标准任务集
└── ~/.newbee/                        # （用户目录，非本仓库）
    ├── tools/*.ex                   # 全局工具脚本（git 版本化，热载）
    ├── memory/                      # 全局记忆
    ├── events.log                   # 事件溯源
    ├── sessions/<id>.jsonl          # transcript（追加写）
    └── session-artifacts/<id>/      # 会话制品：bindings 快照 / harness 状态 / 调度任务 / 子代理
```
---

## 8. 安全与沙箱

- **默认宽松(Lenient) + 审计**：文件读写、常用命令（`mix`/`git`/`elixir` 等）默认直接放行，不打断模型。
- **高风险操作审计+回滚**：删目录/递归删除、推送远端等记录审计日志；借助 git 快照与文件快照提供 `/undo` 回滚兜底。
- **内核只读**：模型只能改工具层/提示层/记忆层（§3.7），自我进化无法破坏核心系统。
- **工作目录隔离**：模型写入限制在目标工程目录树内。
- **资源限制（务实版）**：BEAM 无进程内强隔离，做得到的是**执行超时 + 输出大小上限**；内存/系统调用级隔离只在可选严格档（OS 容器如 `bwrap`）提供，不作为默认承诺。
- **提示注入防护**：宽松 ≠ 不设防。模型读取的任意文件内容一律当**数据**处理（prompt 中显式隔离引用），防止仓库里藏的恶意指令劫持模型。
- **副作用审计日志**：所有外部副作用操作记录，可回查、可撤销。
- **可选严格档**：`lenient`（默认）/ `ask` / `deny` 三种模式可配置。

---

## 9. Token / 上下文优化策略

以下一切服务于第一性原则（§1.1）：**上下文极简不只是省钱，是提质**。

1. **绑定持久化**（§3.3）：中间结果留在环境侧，模型只持有变量名——最大头的节省。
2. **RepoMap**（§3.6）：注入结构图而非文件全文。
3. **结果回填压缩**：默认只回 `exit code + 摘要/尾部`；鼓励模型**写代码过滤**（确定性压缩）而非 LLM 摘要。
4. **工具清单动态化**：只注入与当前工程/任务相关的工具 `@doc`（基于检索），而非全量。
5. **记忆分片**：长记忆按 topic 索引，按需检索注入（131 万上下文给了很大余地，但仍按需）。
6. **工具即缓存 / 推理固化**（§6.2）：高频子任务固化成单次调用，直至零 token。
7. **异步/后台**：复盘、索引构建走后台子代理，不占主循环 token 预算。
8. **增量 diff 上下文**：模型只需看到块的 delta 而非全文件。
9. **哈希锚点编辑**（§3.2）：编辑按"锚点对"（目标行 hash + 相邻行上下文 hash）而非复述原文；行号只是提示，数错行自动重定位，对不上整体拒绝——消灭编辑失败重试循环。
10. **沉睡规则**（§4.5）：纠正性知识平时零 context，触发才注入。
11. **价签系统（price tags）** ⭐：每个工具与常用操作路径携带**实测价签**（历史平均 token 成本 + 成功率），随工具清单一并暴露给模型——模型自己按"够用且最便宜"选路，省 token 从隐藏策略变成模型的显式决策。价签数据来自事件日志的持续测量（§6.1），越用越准。
12. **渐进式披露**：prompt 里只放工具/记忆的**一行签名清单**（名字+一句话描述），模型判定相关后才用 `Newbee.read/1` 取全文——永远不注入全量文档。

---

## 10. 路线图

- **M0（Spike，前置验证）**：拿 deepseek v4 flash 写 ~20 段真实工程操作的 Elixir（遍历工程、AST 定位、改源码、跑测试），统计首遍通过率。**这是全设计的最大赌注**（LLM 的 Elixir 熟练度）；若首遍通过率过低，优先投资"惯用法手册 + 错误反馈循环"再往下走。
- **M1（原型）**：先验证 ratatouille 兼容性 → TUI 骨架（codex 式单列流式界面 + `/`命令 + `@文件`）+ 独立节点求值器（持久 bindings、崩溃隔离、env 过滤）跑通"run_elixir → 执行 → 结果回填 → 循环"。支持 `fs`/`run`/`test` 基础工具。
- **M2（工程能力）**：双轨编辑（锚点轨优先，收益最直接）、Sourceror 结构轨、RepoMap、diff 渲染、工具热载（`~/.newbee/tools/` + git）、会话挂起/恢复、事件日志、`/evolve` 手动触发进化（worker 顺便做、用户逐个批准）。
- **M3（工具库）**：AST/搜索/git/脚手架工具集，@doc 自动注入 prompt，并发子代理（worktree 隔离），沉睡规则，统一寻址 reader。
- **M4（自我进化）**：指标采集 → 失败抗体/反事实回放裁判 → **专职 evolver 上线**（worker 线索通道 + heartbeat/cron 后台合成，带 token 预算）→ JIT 三级编译（含 deopt）→ 事件溯源/快照回滚 → `evolution` 策略档位逐步放开（`:hint`→`:background`）。
- **M5（成熟）**：策略细调、多种模型后端、可选 Web 接口、公开评测基准（对比 token/成功率）、**基因库**：进化出的 L3 工具以 **bundle** 打包（工具+规则+prompt 片段的声明式组合，可叠加、可被上层 patch），携带 fitness 分数与出处，可跨用户分享/安装——从单体进化走向群体进化。

---

## 11. 示例工作流（示意）

> 用户："帮我给这个模块加一个并行 mapreduce 函数，并写测试。"

1. TUI 收到意图，组装 prompt（RepoMap + 记忆：本工程用 `Task.async_stream` 惯例 + 相关工具 `@doc` + 当前绑定摘要）。
2. 模型经 `run_elixir` 提交：`mods = RepoMap.modules() |> Enum.filter(...)`、`content = Fs.read!("lib/target.ex")`、`defs = Ast.list_defs(content)`，`IO.inspect(defs)` —— **三个操作一个代码块完成**，`content` 留在 binding。
3. DEE 返回压缩结果（def 列表）。
4. 模型下一轮直接引用 binding 里的 `content` 做 Sourceror 结构化插入，`format` 后写回——**没有重读文件**。
5. `run_elixir` 跑 `mix test`，`report = ...` 留在 binding，只回传失败摘要。
6. 全部通过 → `done`，TUI 显示 diff，用户 `/approve` 落盘。
7. 后台复盘：该模式（定位→AST 插入→测试）值得固化吗？→ 写成工具 → 评测台验证 → 热载。
8. 以后类似任务，一次 tool call 完成 → token 下降、准确率上升。

---

## 12. 待细化问题

- 跨工程"全局记忆"的命名空间/标签设计，避免 A 项目经验误用于 B 项目。
- 会话挂起/恢复的序列化细节：绑定值中不可序列化项（PID、闭包）的 tombstone 策略。
- 评测台标准任务集的具体内容（哪些任务最能代表真实使用）。
- 模型后端适配优先级：除 OpenRouter 外是否需并行支持本地 Ollama / 其余路由。
- 子代理并发时的记忆一致性（ETS 并发读写冲突处理）。

---
