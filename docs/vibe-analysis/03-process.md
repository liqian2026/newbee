# Vibe Coding 改进 — 完整过程文档（最终版）

## 工作分支
`explore/vibe-coding-analysis`（worktree: `/home/alanx/data/git/newbee-explore`）

## 统计
- **22 个 commits**
- **12 个文件变更**
- **+2445 行新增，-63 行删除**

## 第一性原理分析

从"vibe coding 时程序员的不可约减痛点"出发：

1. **看不见** — AI 工作过程不可见 → Mission Control 面板
2. **等得焦虑** — 不知进度和状态 → 操作指示器 + 自动 tab 切换
3. **审查困难** — 散落的 diff → Impact Analysis + Diff 汇总
4. **控不住** — 无法中途干预 → Steering 转向模式
5. **上下文丢失** — @ 文件引用解决上下文注入

核心洞察：vibe coding 的本质矛盾是**信任 vs 效率**。
解决方案不是让 UI 更花哨，而是让程序员能**快速建立信任**。

## 已实现的功能

### Mission Control 面板（4 个 tab）
| Tab | 功能 | 数据源 |
|-----|------|--------|
| 📁 文件 | 变更文件列表+增删行数 | git diff --numstat |
| 📋 步骤 | tool call 时间线 | WebSocket tool_start/result |
| 🔀 Diff | 影响分析+unified diff | git diff + 模块依赖图 |
| 📊 概览 | session 状态+bindings | session.state RPC |

### 核心交互改进
- **Steering**: AI 忙时发送按钮变"转向"，点击中断+重定向
- **@ 文件补全**: 输入 @ 触发文件路径自动补全
- **命令面板**: Ctrl+K 打开，24 个命令模糊搜索
- **文件路径可点击**: 对话中的 lib/xxx.ex 可点击查看 diff
- **操作指示器**: topbar 显示当前执行的操作

### 后端新增 RPC (8 个)
- `git.diffStat` / `git.diff` — 文件变更数据
- `git.impact` — 变更影响分析（模块依赖图）
- `project.test` — 运行项目测试
- `git.commit` — 提交变更
- `env.health` — 环境健康（规则/抗体）
- `files.search` — @ 补全的文件搜索
- `session.bindings` — DEE bindings 列表

### 核心层改进
- `repair_hint` 增强：MatchError/UndefinedFunctionError/Timeout 的具体修复建议

### 其他
- 全局键盘快捷键体系
- WebSocket 断连/重连通知
- 分页加载历史消息（>50 条时）
- 欢迎卡片（新用户引导）
- 自动 MC tab 切换（busy→steps, idle→files）

### Bug 修复
- MC 步骤时间线在历史恢复时被污染

## 技术决策

### 为什么用 git diff 做文件追踪？
git 是 ground truth。解析 tool call 太脆弱。

### 为什么做 Impact Analysis？
信任不是通过"看见"建立的，是通过"验证"建立的。
影响分析回答了"这个改动安全吗？"

### 为什么增强 repair_hint？
数据分析发现 387 个 tool_error 中 41% 是 CompileError/SyntaxError，
35 个 MatchError 主要因为 Run.sh 返回 map 而 AI 用 tuple 解构。
具体的修复建议可以减少 retry 循环。

## 数据驱动的发现

分析主 repo 的 9653 条事件日志：
- 3037 次 tool_start, 387 次 tool_error (12.7%)
- 错误分布: CompileError(61) > SyntaxError(36) > MatchError(35) > UndefinedFunctionError(28) > Timeout(26)
- 最大 session 有 394 条消息/479KB

这些数据直接驱动了 repair_hint 增强和分页加载的实现。

## 测试验证
- `mix compile` ✓ 0 errors
- 15+ 单元测试全部通过
- `node --check app.js` ✓ JS 语法正确
