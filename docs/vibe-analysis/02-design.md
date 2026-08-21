# Mission Control 面板 — 功能设计

## 概述

在 WebUI 对话流右侧（可折叠）增加一个 "Mission Control" 面板，
给程序员提供 AI 工作过程的实时可见性和控制力。

## 三个核心组件

### 1. 文件变更追踪器 (File Change Tracker)

**数据源**：session 的 tool call 历史中所有写文件操作
**展示**：文件路径 + 增删行数 + 状态（修改/新建）
**交互**：点击可展开 inline diff

实现路径：
- 后端：新增 `session.fileChanges` RPC，从 session 消息中提取文件变更
- 前端：WebSocket 事件中检测 tool_result 包含文件写入时，实时更新面板
- 备选：通过 git diff 获取真实变更（更准确）

**决策**：用 git diff 作为数据源——因为它是 ground truth，不需要解析 tool call。
`git diff --stat HEAD` 给出所有变更文件及增删行数。
`git diff HEAD -- <file>` 给出具体 diff。
对于未跟踪的新文件用 `git ls-files --others --exclude-standard`。

### 2. 执行时间线 (Execution Timeline)

**数据源**：WebSocket 下行的 tool_start / tool_result 事件
**展示**：步骤号 + 工具名 + 标题 + 耗时 + 状态（成功/失败）
**交互**：点击可展开查看完整代码和输出

实现路径：
- 纯前端：在 onEvent 中拦截 tool_start/tool_result，维护一个 steps 数组
- 渲染为可折叠的时间线条目

### 3. Session Diff 汇总 (Session Diff)

**数据源**：git diff
**展示**：unified diff，按文件分组，语法高亮
**交互**：每个文件可折叠/展开，一键复制 diff

实现路径：
- 后端：新增 `session.diff` RPC，执行 `git diff HEAD` 和 `git ls-files --others`
- 前端：模态框或面板内展示

## 技术方案

### 后端新增 RPC

```
POST /api/git.diffStat    → %{files: [%{path, added, deleted, status}]}
POST /api/git.diff        → %{diff: "unified diff text"}
POST /api/git.fileDiff    → %{path: "...", diff: "..."}
```

这些不是 session 级的——是项目级的。任何 session 都可以看到项目当前的变更状态。

### 前端变更

1. **HTML**：在 `<main>` 右侧加 `<aside id="mission-control">`，包含三个 tab
2. **CSS**：面板样式，折叠/展开动画
3. **JS**：
   - `MissionControl` 对象管理面板状态
   - `Timeline` 组件追踪 tool events
   - `FileTracker` 组件轮询或事件驱动更新文件变更
   - `DiffViewer` 组件展示 diff

### 事件流

```
AI 执行 run_elixir → tool_start event → Timeline 添加条目
                    → tool_result event → Timeline 更新条目状态
                                         → FileTracker 刷新（git diff --stat）
用户点击文件 → fileDiff RPC → DiffViewer 展示
用户点击"全量 diff" → diff RPC → DiffViewer 展示
```

## UI 布局

```
┌──────────┬─────────────────────────┬──────────────┐
│ Sidebar  │                         │ Mission      │
│ (会话)   │      对话流              │ Control      │
│          │                         │              │
│          │                         │ ┌──────────┐ │
│          │                         │ │ 📁 文件  │ │
│          │                         │ │ 📋 步骤  │ │
│          │                         │ │ 🔀 Diff  │ │
│          │                         │ └──────────┘ │
│          │                         │              │
│          │                         │  [tab 内容]  │
│          │                         │              │
├──────────┴─────────────────────────┴──────────────┤
│ 输入框                                             │
└────────────────────────────────────────────────────┘
```

## 边界与约束

- 不改后端 evaluator/agent 逻辑 — 纯 UI + RPC 层
- git diff 有性能开销，做防抖（500ms）和缓存
- 面板默认收起，点击展开（不干扰现有用户体验）
- 零依赖：纯原生 JS，与现有 app.js 风格一致
