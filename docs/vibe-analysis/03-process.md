# Vibe Coding 改进 — 过程文档

## 时间线

### 阶段 1: 探索与理解（30 分钟）
1. 创建 worktree `explore/vibe-coding-analysis`
2. 通读 DESIGN.md — 理解 newbee 的核心设计理念
3. 审查 WebUI 前端代码（app.js 1319 行 + index.html + style.css）
4. 审查 WebUI 后端 API（api.ex 426 行）
5. 分析 WebSocket 事件流（onEvent 的所有分支）
6. 分析命令系统（commands.ex 24 个命令）

### 阶段 2: 第一性原理分析（20 分钟）
产出: `docs/vibe-analysis/01-first-principles.md`

核心推导链：
```
程序员 vibe coding → 不可约减的 5 个痛点
→ 按频率×痛感排序
→ 识别 newbee 的差异化优势（DEE + EventBus + WebSocket）
→ 推导出 "Mission Control" 面板设计
```

5 个痛点（按严重度排序）：
1. **看不见** — AI 改文件时程序员是盲的
2. **等得焦虑** — 长任务不知进度和状态
3. **审查困难** — 散落的 diff 难以集中审查
4. **控不住** — 无法中途干预方向
5. **上下文丢失** — 长对话后 AI 忘记约束

### 阶段 3: 设计（15 分钟）
产出: `docs/vibe-analysis/02-design.md`

Mission Control 面板设计：
- **文件变更追踪器**: git diff --numstat 数据源，WebSocket 事件驱动刷新
- **执行步骤时间线**: tool_start/tool_result 事件拦截，可折叠
- **Session Diff 汇总**: git diff 全量/单文件展示

命令面板设计：
- Ctrl+K/Ctrl+P 快捷键打开
- 24 个内置命令，模糊搜索
- 输入 "/" 时自动触发

### 阶段 4: 实现（45 分钟）

**后端 (api.ex)**:
- 新增 `git.diffStat` RPC: 解析 `git diff --numstat` + 未跟踪文件
- 新增 `git.diff` RPC: 支持全量 diff 和单文件 diff，包括新文件的 synthetic diff
- 辅助函数: `git_cmd/1`, `parse_numstat/1`, `count_file_lines/1`, `new_file_diff/1`

**前端 HTML (index.html)**:
- Mission Control 面板（3 个 tab、折叠/展开按钮）
- 命令面板 modal

**前端 CSS (style.css)**:
- 97 行 MC 样式 + 命令面板样式
- 动画（pulse for running steps, slide for panel）
- 响应式（窄屏全覆盖）

**前端 JS (app.js)**:
- Mission Control: `MC` 状态对象 + 12 个函数
- 事件 hooks: `mcToolStart`, `mcToolResult`, `mcOnFileChange`
- 防抖刷新（600-800ms）
- 命令面板: `CMD_LIST` + `initCmdPalette` + 键盘导航

### 阶段 5: 测试（10 分钟）
- `mix compile` ✓ 无错误
- `mix test test/newbee/web_api_git_test.exs` ✓ 4/4 通过
- `mix test test/newbee/difftest_test.exs` ✓ 4/4 通过
- `node --check app.js` ✓ JS 语法正确

## 提交历史

```
ff57081 feat(web): command palette (Ctrl+K) + fix HTML structure
9f8c023 feat(web): hook file_diff event to Mission Control file tracker
9adcfbe feat(web): Mission Control panel - file tracker + step timeline + diff viewer
```

## 技术决策记录

### 为什么用 git diff 而不是解析 tool call？
**决策**: git diff 是 ground truth。tool call 解析需要跟踪 Fs.write/Edit.patch 等
多个工具的参数格式，脆弱且容易遗漏。git diff 直接给出真实文件系统状态。

### 为什么步骤时间线在前端而不是后端？
**决策**: 步骤信息已经在 WebSocket 事件中（tool_start/tool_result），
前端只需拦截并维护数组。后端不需要改动。步骤是 session 级的临时状态，
不需要持久化。

### 为什么命令面板在前端过滤而不是后端？
**决策**: 命令列表是静态的（24 个），不需要 RPC 调用。
前端过滤延迟为零。

## 后续方向

### 短期（1-2 天）
- [ ] **Steering**: AI 工作时插入新指令（队列机制已有，需要 UI 暴露）
- [ ] **Token 实时消耗图表**: WebSocket usage 事件驱动
- [ ] **文件变更自动刷新**: 定期轮询 git diff（目前只在 file_diff 事件时刷新）

### 中期（1 周）
- [ ] **inline diff 渲染**: Mission Control 的 Diff tab 中语法高亮
- [ ] **步骤搜索/过滤**: 按状态/类型筛选执行步骤
- [ ] **多 session 概览**: 并列显示多个会话的活跃状态

### 长期（2 周+）
- [ ] **AI 工作树可视化**: 从 EventLog 构建任务执行 DAG
- [ ] **时间轴回放**: 从 EventLog 重建整个 session 的执行过程
- [ ] **智能提醒**: 当 AI 修改了用户标记为"重要"的文件时发出警告
