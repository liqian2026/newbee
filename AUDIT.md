# newbee 实现度审计（对照 DESIGN.md）

> 审计日期 2026-08-20。方法：7 路并行取证（设计章节→代码→接线→测试），关键指控逐行复核。
> 测试基线（OTP 29 + Elixir 1.20，系统默认 Elixir 1.9.1 无法运行本项目）：
> 全套件 282~284/287 通过，3~5 个 flaky；`acceptance_test.exs` 单跑 12/12 全过，
> 混跑时 §15.4/15.6/15.10 因并发干扰失败（测试污染，见 G 节）。

## 总判

架构骨架已成型：对象模型、EventStore、Coordinator 状态机、Generation/Binding 迁移、
五层评价框架、Autonomy 合取门都真实存在且有端到端验收。差距集中在**「建成未通车」**——
大量机制有模块、有单测，但生产路径不调用；另有 1 个活锁级 bug。

## P0 活锁 bug（已逐行坐实）→ 已修复（store.ex fresh_environment 播种 + manifest.ex new/from_map/rollback-rev0 同步内置基线图；acceptance §15.1/§15.4 断言更新）

**内置插件从不进 active 图 → 生产环境全部内置工具被能力门拒绝。**

证据链：

1. `lib/newbee/plugins.ex:53` `builtin_active_map/0`（初始 active 图）全库零调用方；
2. `lib/newbee/environment/store.ex:70-78` 新环境 `active: %{}`，仓根 `.newbee/environment.json` 实测 `"active": {}`；
3. 非 test 环境 Coordinator 自启（`application.ex:20`）→ `capability_gate.ex:44-54` 走 active 图校验
   → `Newbee.Tools.Fs` 映射 `tool.fs` 不在图 → `{:deny, :plugin_not_active}`；
4. `lib/newbee/agent/loop.ex:533-541` 拒绝后不执行，直接回填错误。

test 环境不启 Coordinator 走 standalone 放行，所以测试全绿、狗食即炸。
修复 = 播种：`fresh_environment` / Coordinator init 用 `builtin_active_map()` 初始化 active 图。

## REFACTOR_PLAN 17 项逐项判定

| # | 项 | 判定 | 关键证据 / 缺口 |
|---|---|---|---|
| 1 | EventStore | ✅ | checksum frame(`event_store.ex:194`)、单调 id 重启不回退(`:117`)、replay(`:47`)、崩溃截断(`:234`)、durability 三档(`:154`)；4 单测+§15.1 验收。瑕疵：档位硬编码 `:batch`(coordinator.ex:116) 无配置面 |
| 2 | Environment.Store | 🟡 | 布局/原子写(tmp→fsync→rename→fsync dir, `store.ex:113-122`)/临时清理 ✅；**`with_lock` 零调用方**(`:155`)；migration 缺 candidate 目录+原子切换且不落盘(`:199-205`, boot.ex:87 丢弃返回值) |
| 3 | 对象模型 structs | 🟡 | Release/Change/Revision 齐备且被用；**Evaluation struct 不存在**（评测结果是裸 map） |
| 4 | Contract+Manager+Supervisor | 🟡 | 9 callback behaviour(`plugin_contract.ex:15-27`)、物化+静态校验+依赖拓扑 ✅；**PluginSupervisor 的 start_plugin/register_effect/leak_check 零业务调用方** |
| 5 | 内置插件 registry | 🟡 | 13 个内存 builtin release、md5 寻址(`plugins.ex:16-45`) ✅；~~不进 active 图（见 P0）~~ → 已修复（rev0 播种）；仍**不落盘、工具模块不实现 contract** |
| 6 | BindingCodec+Generation | ✅ | 白名单编解码+预算+tombstone+粒度隔离(`binding_codec.ex:109-268`)；quiesce/快照 checksum/原子切换/排空/失败回滚(`generation.ex:37-147`, `evaluator_pool.ex:218-246`)；§15.5/15.5b 验收。瑕疵：recompute_recipe 无生产者、迁移摘要不进 worker 投影 |
| 7 | EvaluatorPool | ✅ | 多 generation 路由/原子切换/drain；复用 DEE.Evaluator `:peer` 双节点+env denylist 剥离(`evaluator.ex:30-31,629-644`)；接线完整。瑕疵：pool/Evaluator 自身 GenServer.start 非 link、不在监督树 |
| 8 | 抗体+Verifier+PPT | 🟡 | 两态晋升+分层 GC+确定性门、PPT 全机制、成本模型选路都有且有单测；但 **verify/gc 无生产调用方、分层只按龄期、usage/longitudinal 层恒 passed、counterfactual 默认 builder 是 identity 占位(verifier.ex:222)、执行回放 rerun/stub 全缺、select_top 未接线** |
| 9 | Autonomy+Fitness 价签 | 🟡 | 四档+Ring 上限表+合取判定(autonomy.ex:22/27-40/109 → coordinator.ex:585)、建议升档、价签记账分桶+样本不足不展示+进投影 ✅；缺：**replay_coverage 占位(有 change 即 1.0, coordinator.ex:1049)、无自动降档、/approve 无签名不可撤销、canary/cross_project 被豁免(verifier.ex:80)、convergence 未接线** |
| 10 | JIT | 🟡 | profile/promote_*/deopt_decision 全有+单测；但 **daemon//evolve 不传 events → 热度恒空(adapter.ex:70)；promote_* 无调用方；check_deopts 只 Logger.info 不发起 Change 且无人调用(adapter.ex:206)** |
| 11 | Coordinator 状态机 | 🟡 | 单写者+expected_version(:982)+deadline→timeout(:466-476)+幂等键(:292-325)+candidate_ready 去重(:232)+checkpoint 重放(:143) ✅；缺：**崩溃后 in-flight 评测卡死不重驱动**、无预算扣减幂等键、同 plugin 双 candidate 激活无冲突检测 |
| 12 | Protocol+Agents | 🟡 | message_id={agent,seq} 持久化、8 种载荷、Worker 三通道、Adapter 走 Coordinator 无旁路 ✅；**Protocol.dedupe 未接进 Coordinator、rollback_request 无消费者、Advisor 模块零调用方(loop 内联重写且 note 不进 worker 上下文)、worker 发出的消息不进 EventStore** |
| 13 | Projection | 🟡 | 全成分视图(projection.ex:26-113) ✅；**生产 loop.ex:1167 内联自建 prompt，Projection.build 仅验收测试调用 → module_ready 通知链(§7.3③④)断头**；无 adapter/TUI 视图变体 |
| 14 | Host.Shell+受控 transport | 🟡 | 白名单+凭证注入+预算+审计+emergency_stop(host/shell.ex:39-142) ✅；**LLM 主路径绕过：llm/client.ex:14,74-77 直持 api_key 经 Req 直连**(§12 违背)；`shell.ex:112 llm_call` 零调用方；`plugins/provider/openrouter.ex` 不存在 |
| 15 | 命令层 | 🟡 | 19 项中 16 项真实现；**/diff 默认值 bug(commands.ex:303-306)、/undo 语义偏移、/attach stub** |
| 16 | 删除旧旁路 | ✅ | evolution/* 10 文件+dee/kernel.ex+dee/tools* 全删，lib/ 零残留引用；§15.12 防回归断言(acceptance_test.exs:422)。瑕疵：loop.ex:403 Metrics 注释残留 |
| 17 | 验收测试 | 🟡 | 架构验收 11/12 条真端到端；**§15.7 完全缺失**；智能验收 13/16 仅单元级、14 占位、15/17 空白 |

可勾选：1、6、7、16。其余 13 项半身。

## §15 验收标准 17 条

| 条 | 状态 | 证据 |
|---|---|---|
| 1 首启/重启恢复 | ✅ | acceptance_test.exs:64 |
| 2 两类非工具插件同 Runtime | ✅ | :87 |
| 3 候选失败不改 active | ✅ | :131 |
| 4 回退历史 release | ✅ | :156 |
| 5 绑定迁移 | 🟡 | 正确性 ✅(:190/:229)，P95 预算无测量 |
| 6 worker 四通道 | ✅ | :277（module_ready 断言手工 drain 非真实投递） |
| 7 adapter 隔离 | ❌ | 无测试（且 adapter 直接读宿主 API key） |
| 8 幂等 | ✅ | :312 |
| 9 known-good 恢复 | ✅ | :345 |
| 10 审计五问 | ✅ | :371 |
| 11 沉睡规则 compaction 存活 | 🟡 | :401 视图级，非真实 LLM 流 |
| 12 旧旁路删除 | ✅ | :422 |
| 13 抗体零复现 | 🟡 | 单元级（门已接线 verifier.ex:152） |
| 14 反事实回放 | 🟡 | identity 占位，无统计含义 |
| 15 token 下降实测 | ❌ | 无 |
| 16 价签收敛 | 🟡 | 机制单测，非实测验收 |
| 17 PPT 对照基线 | ❌ | 仅算法单测 |

## 其他断链（建成未通车，按严重度）

1. **Daemon 从未启动**：`daemon.ex` 的 `start_link` 全库零调用方，`mix newbee daemon` 只调阻塞 stub(mix/tasks/newbee/daemon.ex:10) → 定时进化心跳永不触发；不在监督树。`/evolve` 手动同步可用(commands.ex:392)。→ 已修复（application.ex 非 test 分支监督树加 Newbee.Daemon；Daemon.start/0 改造为 ensure-GenServer + 常驻，不再绕过 GenServer）
2. **事件溯源被绕过**：worker loop/Protocol/Fitness 事件直发 `Bus.emit`(loop.ex:874-876 等)，不经 Events.emit durable 落盘 → 项目 `.newbee/events.jsonl` 实测空文件，`~/.newbee/events.jsonl` 已 30MB。§4.6「Event Store 唯一同步事实写入」只对 change/revision 类事件成立。→ 已修复（loop.ex emit 与 protocol.ex send_message 改走 Events.emit；@durable_prefixes 补齐 usage/progress/rule/candidate/rollback；standalone 优雅降级已冒烟验证；Fitness 事件仍直发 Bus 属未覆盖残留）
3. **沉睡规则运行时半身**：工具参数面拦截 ✅(loop.ex:527)；正文/thinking 面收流后才注入 reminder，无「中断流→断点重试」(loop.ex:415-428)；AST 模式未实现（只 regex）；老规则存 rules.json 旁路无版本/评测/回退；存储身份桥（rule release→Change→sync_runtime_rules 挂载, coordinator.ex:900）存在。
4. **GC 类机制无人触发**：`Memory.gc/0` 零调用方；`BindingGC.maybe_gc` 已接(evalworker.ex:48) 但 pin/touch 无调用方、LRU 时钟每 cell 全量刷新退化为按大小逐出。
5. **小模块缺口**：BestTool 仅 stub(`def run, do: :better`)；Explorer 零调用方+无 ETS 共享记忆+无真 schema 校验，位置 `agents/`（复数）而非 §13 `agent/`；`agent/pre-step`、`llm/stream`、`tools/pre-execute` live topic 声明但从不 emit；step 级事件不落盘；Evaluation struct 缺；`discover project root` 未实现（直接 cwd）；`evaluations/<id>/`、`profile.md`、`~/.newbee/plugins/` 无写入方。
6. **TUI**：自研 ANSI（设计允许 fallback 但要求 Renderer 接口抽象——没有）；Shift+Enter 换行不可达(tui/key.ex:186-189 修饰键被吞)。

## 修复优先级

1. ~~修活锁：builtin_active_map() 播种~~ → 已修复；
2. Projection 接生产（loop.ex:1167 → Projection.build）→ 打通 module_ready 通知、迁移摘要、绑定摘要三条断头链；
3. Daemon 进监督树或删 stub；worker 事件改走 Events.emit 落盘；→ 已修复（见严重断裂 1/2 条目标注）
4. 评价闭环接线：抗体 verify/gc 调度、select_top 进评测流、deopt 发 Change、JIT events 喂入；
5. provider 插件化：LLM.Client 改走 Host.Shell.execute_request_plan，消灭主路径持凭证；
6. 补 §15.7 验收 + 修 3 条全套件 flaky。
