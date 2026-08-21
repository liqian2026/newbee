# Vibe Coding 改进 — 最终过程文档

## 工作分支
`explore/vibe-coding-analysis`（worktree: `/home/alanx/data/git/newbee-explore`）

## 交付物总结

### 1. 第一性原理分析
📄 `docs/vibe-analysis/01-first-principles.md`

从"程序员打开 AI 编程工具"这个第一性场景出发，识别出 5 个不可约减的痛点：
- 看不见（AI 工作过程不可见）
- 等得焦虑（不知进度和成本）
- 审查困难（散落的 diff）
- 控不住（无法中途干预）
- 上下文丢失（长对话后遗忘）

### 2. 功能设计
📄 `docs/vibe-analysis/02-design.md`

设计了 Mission Control 面板作为核心解决方案。

### 3. 实现的功能

#### 3.1 Mission Control 面板（4 个 tab）
- **📁 文件变更追踪器**: 实时显示 AI 修改的文件，带增删行数
  - 数据源: `git diff --numstat` + 未跟踪文件列表
  - WebSocket `file_diff` 事件驱动自动刷新（600ms 防抖）
  - 点击文件可跳转到 diff 视图
- **📋 执行步骤时间线**: AI 每个 tool call 的记录
  - 状态指示（运行中⏳/成功✓/失败✗）
  - 耗时显示
  - 可展开查看代码
  - 自动保留最近 200 步
- **🔀 Diff 汇总**: 全量或单文件 unified diff
  - 语法着色（绿=新增，红=删除，紫=hunk header）
  - 支持新文件的 synthetic diff
- **📊 会话概览**: 关键指标一览
  - 模型、状态、轮数/步数、bindings、token 使用、缓存命中率、自治档位

#### 3.2 Steering（转向模式）
- AI 工作时，发送按钮变为橙色"转向"按钮
- 点击后先中断当前 turn，然后立即发送新指令
- 区别于排队模式——真正实现了 mid-flight redirect

#### 3.3 命令面板（Command Palette）
- Ctrl+K / Ctrl+P 快捷键打开
- 24 个内置命令，模糊搜索
- 键盘导航（↑↓ 选择，Enter 执行）
- 输入 "/" 时自动触发
- 无参数命令选中后直接发送

### 4. 后端新增 RPC
- `git.diffStat` → `%{files: [%{path, added, deleted, status}]}`
- `git.diff` (可选 path) → `%{diff: "unified diff text"}`

### 5. 测试
- `test/newbee/web_api_git_test.exs` — 4 个测试全部通过
- `mix compile` — 无错误
- `node --check app.js` — JS 语法正确

## 代码量
- 8 个文件变更
- +1052 行新增，-1 行删除
- 6 个 commits

## 第一性原理的核心洞察

vibe coding 的本质矛盾是 **信任 vs 效率**：
- 程序员想放手让 AI 干活（效率）
- 但又需要知道 AI 在干什么（信任）

Mission Control 面板解决的不是"AI 不够聪明"的问题，
而是"AI 工作过程对程序员不透明"的问题。

这和 newbee 的核心设计理念一致：
> "知识住环境不住 prompt" → "状态住面板不住对话流"

对话流是 AI 的输出通道，Mission Control 是程序员的感知通道。
两者分离，各司其职。
