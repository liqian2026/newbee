# newbee

**会自我进化的 Elixir 编程 Agent** —— 把一个大模型放进一个长期运行的、动态的 Elixir 环境里，让它自己用 Elixir 作为手和脑来编程、操作文件、调用工具、构建工程，并反过来持续优化这个环境本身。

设计文档见 [DESIGN.md](DESIGN.md)。

## 核心概念

| 概念 | 说明 |
|---|---|
| **DEE** (动态 Elixir 环境) | 模型专属的持久 IEx：`run_elixir` 变量跨轮存活、工具随写随热载、工程可探可改可测 |
| **绑定持久化** | 中间结果（大文件、AST、搜索结果）留在环境侧 binding，模型只持有变量名——最大头的 token 节省 |
| **求值器隔离** | 模型代码运行在独立 BEAM 节点：崩溃只杀节点、自动重启，TUI/会话毫发无损；节点剥离所有 LLM 凭证 |
| **双轨编辑** | 文本轨：哈希锚点补丁（`show` 给每行生成 8 位 hash 锚点，`patch` 按锚点对定位，数错行自动重定位）；结构轨：Sourceror AST 重写 |
| **光头优先** | 工具面封顶 3 个（`run_elixir` / `done` / `ask`）；知识住环境不住 prompt |
| **沉睡规则** | 环境免疫系统：教训编译成规则，平时零 context，模型犯错当口注入纠正 |
| **自我进化** | worker 供线索 → evolver 后台合成 → 评测台裁判（失败抗体 + 反事实回放）→ 热载；JIT 三级：教训 → 规则 → 蒸馏工具 |
| **事件溯源** | 上下文是日志的物化视图：compaction 改视图不动日志，任意时间点可重建 |
| **常驻 daemon** | 环境是常驻生命体，TUI 只是探视窗；关掉终端环境继续存活、记忆、进化 |

## 快速开始

```bash
# 工具链（OTP 29 + Elixir 1.20）
export PATH=$HOME/toolchains/otp-29/bin:$HOME/toolchains/elixir-1.20/bin:$PATH

mix deps.get

# 配置模型（OpenRouter）
mkdir -p ~/.newbee
cat > ~/.newbee/model.json <<'EOF'
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "apiKey": "${OPENROUTER_API_KEY}",
      "models": []
    }
  },
  "roles": {
    "default":  { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" },
    "evolver":  { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" },
    "verifier": { "provider": "openrouter", "model": "deepseek/deepseek-v4-flash-0731" }
  }
}
EOF
export OPENROUTER_API_KEY=sk-...

./bin/newbee            # 全屏 TUI（推荐）
./bin/newbee cli        # 单列流式 CLI
./bin/newbee daemon     # 常驻 daemon（后台自动进化）
./bin/newbee bench      # 公开基准
./bin/newbee doctor     # 环境体检
```

## TUI 交互（对齐 codex / pi）

- 单列流式对话：模型输出、思考流（灰色）、工具块、审计事件依次流式追加
- `Enter` 发送 · `\` 续行 · `↑/↓` 历史（跨会话持久）· `Tab` 补全（`@路径` / 命令）
- `Esc` 中断模型执行 · `Ctrl-C` 清输入/退出 · `Ctrl-L` 重绘
- `PgUp/PgDn` 翻屏 · 括号粘贴 · 状态栏（模型/工程/token/绑定/策略）

命令：`/model` `/bindings` `/tokens` `/rules` `/dump` `/resume` `/reset`
`/approve` `/reject` `/log` `/snapshot` `/rollback` `/evolve` `/policy`
`/genes` `/bench` `/goal` `/quit`；`@文件` 引用；`!shell` 执行。

## 架构

```
lib/newbee/
├── tui/          # TUI 前端：Key(按键解码) / Line(行编辑) / Screen(双缓冲渲染) / History
├── dee/          # 动态 Elixir 环境（只读内核）
│   ├── evaluator.ex   # 独立 BEAM 节点：eval + 持久 bindings + 双节点冗余
│   ├── evalworker.ex  # 节点内求值 worker
│   ├── kernel.ex      # 主循环：prompt 组装 → LLM → run_elixir → 压缩回填
│   ├── rules.ex       # 沉睡规则（免疫系统）
│   ├── repomap.ex     # 工程结构图
│   └── tools/hotloader.ex  # 工具热载（git 版本化）
├── tools/         # 工具库：Edit(锚点编辑) / Structural(Sourceror) / Fs / Run / Git
├── llm/           # 模型客户端（OpenRouter 多后端适配）+ token 记账
├── codec.ex       # function calling 协议（run_elixir/done/ask）
├── evolution/     # 自我进化：Bench(裁判) / Evolver / JIT / PPT / Progress / Metrics / Gene / Snapshot / Policy
├── bus.ex         # 事件总线（全系统一条总线）
├── event_log.ex   # 事件溯源日志
├── session.ex     # 会话挂起/恢复（transcript + bindings 快照）
└── memory.ex      # 全局记忆（自动脱敏）
```

## 测试

```bash
mix test          # 全量（含 evaluator 多节点测试，约 2.5 分钟）
mix test test/newbee/tools/edittest_test.exs   # 锚点编辑契约
```

## 状态

M1-M4 功能已实现：DEE 求值器（崩溃隔离/绑定持久/env 过滤）、双轨编辑、
RepoMap、工具热载、会话挂起/恢复、事件溯源、沉睡规则、JIT 三级、PPT
Best-of-N、进度验证器、失败抗体/反事实回放、evolver 后台合成、基因打包、
daemon 常驻。见 [DESIGN.md](DESIGN.md) 路线图。
