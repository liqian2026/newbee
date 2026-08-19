# NEWBEE.md

## 项目说明
（由 newbee /init 生成，可编辑——本文件会被注入会话 prompt，§5.4）

## 工程结构
▸ Mix.Tasks.Newbee — 启动 newbee CLI。
    use Mix.Task
    def run/1
  @ lib/mix/tasks/newbee.ex
▸ Mix.Tasks.Newbee.Bench — 跑公开基准任务集（真实 LLM）。
    use Mix.Task
    def run/1
  @ lib/mix/tasks/newbee/bench.ex
▸ Mix.Tasks.Newbee.Daemon — 启动常驻 daemon：环境在终端关闭后依然存活、记忆、进化。
    use Mix.Task
    def run/1
  @ lib/mix/tasks/newbee/daemon.ex
▸ Mix.Tasks.Newbee.Doctor — 检查工具链、配置、目录结构，输出体检报告。
    use Mix.Task
    def run/1
  @ lib/mix/tasks/newbee/doctor.ex
▸ Mix.Tasks.Newbee.Tui — 启动 newbee TUI：`mix newbee.tui`（需在真实终端，raw 模式由 bin/newbee 预设）
    use Mix.Task
    def run/1
  @ lib/mix/tasks/newbee/tui.ex
▸ Newbee.Agents.Explorer — 临时探索/测试子代理 (DESIGN §3.8) ⭐：独立 evaluator + 独立 kernel，
    def run/2
    def read/1
    defp run_in_worktree/3
    defp extract_findings/1
    defp extract_findings/1
    defp extract_findings/1
    defp extract_findings/1
    defp summary_of/1
    defp summary_of/1
    defp summary_of/1
    defp summary_of/1
    defp write_result/2
    defp worktree_path/1
    defp gen_id/0
  @ lib/newbee/agents/explorer.ex
▸ Newbee.Application
    use Application
    def start/2
  @ lib/newbee/application.ex
▸ Newbee.Bus — 事件总线 (DESIGN §4.6) ⭐：全系统一条总线，两域。
    use GenServer
    def start_link/1
    def subscribe/0
    def unsubscribe/0
    def emit/2
    def emit_sync/2
    def subscribers/0
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_cast/2
    def handle_info/2
    def handle_info/2
  @ lib/newbee/bus.ex
▸ Newbee.CLI — M1 极简 CLI（codex 式单列流式，DESIGN §5.1）。
    def start/0
    defp printer/1
    defp buffer_and_print_md/2
    defp flush_buffer/1
    defp flush_buffer/1
    defp loop/2
    def resume/1
    defp resume_kernel/2
    defp print_metas/1
    defp run_submit/2
    defp session_id/1
  @ lib/newbee/cli.ex
▸ Newbee.Codec.FallbackParser — 降级通道 (DESIGN §4.2)：模型偶发在文本里输出 ```elixir 代码块时，
    def extract/1
    def extract/1
    defp do_extract/1
    def has_block?/1
    def has_block?/1
    def correction_reminder/0
  @ lib/newbee/codec/fallback_parser.ex
▸ Newbee.Commands — CLI/TUI 共用的命令处理 (DESIGN §5.3)。命令对当前 kernel pid 操作；
    def commands/0
    def handle/2
    def run_shell/1
    def expand_at_files/1
    def resolve/1
    defp run_command/2
    defp run/3
    defp run/3
    defp run/3
    defp run/3
    defp run/3
    defp run/3
    defp run/3
    defp run/3
    defp run/3
  @ lib/newbee/commands.ex
▸ Newbee.Cwd — 启动时工作目录解析：优先 NEWBEE_CWD 环境变量（bin/newbee 脚本注入），否则 File.cwd!()
    def apply!/0
  @ lib/newbee/cwd.ex
▸ Newbee.Daemon — 常驻 daemon (DESIGN §3.8) ⭐：环境是常驻生命体，TUI 只是探视窗。
    use GenServer
    def start_link/1
    def evolve_now/0
    def init/1
    def handle_cast/2
    def handle_info/2
    def handle_info/2
    def handle_info/2
    defp run_evolver_cycle/0
    def start/0
  @ lib/newbee/daemon.ex
▸ Newbee.DEE.Evaluator — 求值器 (DESIGN §3.3/§3.4)：模型代码运行在**独立 BEAM 节点**（:peer 启动，同机分布式），
    use GenServer
    defstruct: mode, peer, node, worker, standby, standby_boot, restarts, boot_error, last_boot_attempt
    def start_link/1
    def start/1
    def eval/3
    def interrupt/1
    def bindings_summary/2
    def reset/1
    def dump_bindings/1
    def restore_bindings/2
    def info/1
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
  @ lib/newbee/dee/evaluator.ex
▸ Newbee.DEE.EvalWorker — 求值工人：持有持久 binding、执行 cell、捕获 stdout。
    use GenServer
    defstruct: binding, count
    def active_pid/1
    def clear_active/2
    def register_active/2
    def start_link/1
    def start/1
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def run_cell/5
    defp register_remote_active/3
    defp register_remote_active/3
  @ lib/newbee/dee/evalworker.ex
▸ Newbee.DEE.Kernel — 主循环 (DESIGN §4.1)：组装 prompt → LLM → run_elixir → 压缩回填 → 循环，
    use GenServer
    defstruct: messages, client, evaluator, render, client_fun, usage, steps, session, progress, goal, auto_antibodies, error_sigs, advisor, advisor_client
    def start_link/1
    def submit/2
    def set_goal/3
    def clear_goal/1
    def goal/1
    def usage/1
    def interrupt/1
    def compact/1
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
  @ lib/newbee/dee/kernel.ex
▸ Newbee.DEE.RepoMap — 工程结构图 (DESIGN §3.6)：注入紧凑的模块/函数签名大纲而非整文件，
    def build/1
    defp fingerprint/1
    defp read_cache/1
    defp write_cache/2
    defp cache_id/0
    defp elixir_map/1
    defp summarize_file/1
    defp extract_module/1
    defp extract_module/1
    defp walk_body/1
    defp block_to_list/1
    defp block_to_list/1
    defp sig/2
    defp sig/2
    defp sig/2
  @ lib/newbee/dee/repomap.ex
▸ Newbee.DEE.Result — 结果压缩 (DESIGN §4.3)：回填给模型的输出默认做头尾截断，
    def compress/2
    def render/1
    def render/1
    def repair_hint/1
    def repair_hint/1
    def sanitize/1
    def sanitize/1
  @ lib/newbee/dee/result.ex
▸ Newbee.DEE.Rules — 沉睡规则 (DESIGN §4.5) ⭐：环境的免疫系统。
    use GenServer
    defstruct: rules
    def start_link/1
    def add/4
    def check/2
    def list/0
    def remove/1
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    defp seed_jspace/1
    defp persist/1
    defp load/0
  @ lib/newbee/dee/rules.ex
▸ Newbee.DEE.Tools — 工具注册表 (DESIGN §7 dee/tools.ex) ⭐：集中登记环境内全部工具
    def builtin/0
    def hot_modules/0
    def list/0
    def describe/1
    defp summary/1
    def prompt_section/0
  @ lib/newbee/dee/tools.ex
▸ Newbee.DEE.Tools.HotLoader — 工具热载 (DESIGN §3.5) ⭐：工具不写进主应用源码，放
    def global_dir/0
    def project_dir/0
    def tool_files/0
    def publish/3
    def remove/1
    defp current_node/0
    def load_into_node/1
    def load_into_node/1
    def load_into_node/1
    defp validate_name!/1
    defp validate_source/1
    defp ensure_git_repo/0
    defp write_file/2
    defp git_commit/2
  @ lib/newbee/dee/tools/hotloader.ex
▸ Newbee.Diff — 行级 diff（简化版，DESIGN §5.1 内联 diff 渲染的底座）。
    def lines/2
    def stats/2
    def empty?/2
    defp common_prefix/2
    defp common_prefix/2
    defp common_suffix/2
  @ lib/newbee/diff.ex
▸ Newbee.EventLog — 事件溯源日志 (DESIGN §6.5) ⭐：订阅总线，把 durable 事件追加到
    use GenServer
    def start_link/1
    def read/2
    def query/1
    def size/0
    def init/1
    def handle_info/2
    def handle_info/2
    defp encodable/1
    defp encodable/1
    defp encodable/1
    defp encodable/1
    defp trim/0
  @ lib/newbee/event_log.ex
▸ Newbee.Evolution.Bench — 进化裁判 (DESIGN §6.3) ⭐：失败抗体 + 反事实回放。
    def add_antibody/4
    def antibodies/0
    def replay/1
    defp score_default/2
    defp run_antibody/3
    defp parse_min/1
    defp parse_min/1
    defp parse_min/1
    def tasks/0
    def run_tasks/1
  @ lib/newbee/evolution/bench.ex
▸ Newbee.Evolution.Evolver — 专职 evolver (DESIGN §3.8/§6.6) ⭐：worker 留线索 → evolver 离线合成 →
    def hint/2
    def take_hints/0
    def run_once/1
    defp do_run/1
    defp route/2
    defp route/2
    def synthesize/4
    defp parse_proposals/1
    def publish/2
    defp publish_rule/1
    defp publish_rule/1
    defp publish_tools/2
    def rank_tool_candidates/2
    defp publish_tool/1
    defp publish_tool/1
  @ lib/newbee/evolution/evolver.ex
▸ Newbee.Evolution.Gene — 基因库 (DESIGN §6.2 L3 / M5 bundle) ⭐：进化产出的 L3 工具以 bundle 打包
    def export/2
    def import/1
    def list/0
    defp tool_sources/0
    defp rule_sources/0
    defp prompt_sources/0
    defp extract_module_name/1
  @ lib/newbee/evolution/gene.ex
▸ Newbee.Evolution.JIT — 认知的 JIT 编译 (DESIGN §6.2) ⭐：教训分三级，热的路径升级、失效降级：
    use GenServer
    defstruct: items
    def start_link/1
    def learn/2
    def hit/2
    def fail/1
    def promote_to_tool/2
    def list/0
    def init/1
    defp bump/2
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
  @ lib/newbee/evolution/jit.ex
▸ Newbee.Evolution.Metrics — 指标采集 (DESIGN §6.1)：订阅事件总线，采集每个 turn 的
    use GenServer
    defstruct: turns, tokens_in, tokens_out, cache_read_tokens, cache_write_tokens, tool_calls, errors, rule_hits, dones, asks, latencies, per_model, approvals, rejections
    def start_link/1
    def summary/0
    def init/1
    def handle_info/2
    def handle_info/2
    def handle_call/3
    defp ingest/3
    defp ingest/3
    defp ingest/3
    defp ingest/3
    defp ingest/3
    defp ingest/3
    defp ingest/3
  @ lib/newbee/evolution/metrics.ex
▸ Newbee.Evolution.Policy — 进化策略档位 (DESIGN §6.6)：控制 evolver 的激进程度。
    def levels/0
    def get/0
    def set/1
    def set/1
  @ lib/newbee/evolution/policy.ex
▸ Newbee.Evolution.PPT — 概率枢轴锦标赛 (Probabilistic Pivot Tournament, LLM-as-a-Verifier 论文)。
    def select/4
    defp ring_order/1
    defp score_ring/8
    defp score_tournament/8
    defp pair_combinations/1
    defp compare_pair/8
    defp pair_logprob_expectation/2
    defp find_tag/3
    defp expect_at/3
    defp scale_symbols/1
    defp pair_sample/2
    defp parse_score/3
    defp parse_digits/1
    defp token_at/2
    defp do_token_at/4
  @ lib/newbee/evolution/ppt.ex
▸ Newbee.Evolution.PriceTags — 价签系统 (DESIGN §9.11) ⭐：每个工具携带实测价签（调用次数、成功率、
    use GenServer
    defstruct: stats
    def start_link/1
    def summary/0
    def init/1
    def handle_info/2
    def handle_info/2
    def handle_info/2
    def handle_info/2
    def handle_call/3
    defp summarize/1
    def prompt_section/0
    defp load/0
    defp persist/1
  @ lib/newbee/evolution/price_tags.ex
▸ Newbee.Evolution.Progress — 进度验证器 (LLM-as-a-Verifier 落地, DESIGN 新 §6.7)。
    def scales/0
    def token_to_value/2
    def value_to_token/2
    def scale_size/1
    def score/4
    def track/4
    def stalled?/2
    def render_scores/1
    defp crit_score/9
    defp ask_score/8
    defp logprob_expectation/2
    defp token_at/2
    defp do_token_at/4
    defp do_token_at/4
    defp sample_score/2
  @ lib/newbee/evolution/progress.ex
▸ Newbee.Evolution.Snapshot — 环境快照与回滚 (DESIGN §8 审计+回滚)：`/snapshot` 与 `/rollback` 的底座。
    def create/1
    def list/0
    def restore/1
    defp copy_dir/2
    defp restore_dir/2
    defp git_head/0
    defp git_dirty?/0
    defp audit/2
  @ lib/newbee/evolution/snapshot.ex
▸ Newbee.Goal — 自主目标驱动（/goal 的同步版）：逐轮 submit 直到 done / ask / 轮数上限。
    def run/3
    def continue/2
    defp do_run/4
    defp do_run/4
  @ lib/newbee/goal.ex
▸ Newbee.History — 会话恢复时的历史回放渲染：把 transcript 消息（发给 LLM 的结构化 JSON）
    def render_lines/1
    defp msg_lines/1
    defp msg_lines/1
    defp msg_lines/1
    defp msg_lines/1
    defp reasoning_lines/1
    defp reasoning_lines/1
    defp reasoning_lines/1
    defp content_lines/1
    defp content_lines/1
    defp content_lines/1
    defp tool_call_lines/1
    defp decode_args/1
    defp decode_args/1
    defp result_lines/1
  @ lib/newbee/history.ex
▸ Newbee.Host — 宿主契约 (DESIGN §3.4) ⭐：求值器节点不持有任何凭证、不直连 provider、
    def main_node/0
    def on_main?/0
    def emit/2
    def call/3
    def safe_config/0
    defp redact_config/1
    defp redact_config/1
    defp redact_key/1
    defp redact_key/1
    defp redact_key/1
  @ lib/newbee/host.ex
▸ Newbee.LLM.Client — OpenRouter 流式客户端 (DESIGN §4)。SSE 流式 + tool_calls 增量聚合。
    defstruct: model, api_key, base_url, reasoning_effort
    def new/1
    def stream_chat/4
    defp stream_chat_request/4
    defp await_stream_chat/3
    def complete/3
    defp maybe_put_body/3
    defp maybe_put_body/3
    defp complete_req/2
    defp complete_req/2
    defp do_request/4
    def prewarm/1
    defp consume_sse/3
    defp maybe_put/3
    defp maybe_put/3
  @ lib/newbee/llm/client.ex
▸ Newbee.LLM.Config — 模型配置 (model.json)。schema 学习 prime-agent 的 models.json：
    def roles/0
    def load/0
    def client_for/1
    def set_default_model/1
    def describe/0
    defp resolve_path/0
    defp parse/1
    defp default/0
    defp expand_env/1
    defp expand_env/1
    defp expand_env/1
    defp prime_key/1
  @ lib/newbee/llm/config.ex
▸ Newbee.Markdown — 轻量 Markdown → ANSI 渲染器（无依赖，纯函数）。
    def render/1
    def md?/1
    defp render_blocks/3
    defp render_blocks/3
    defp render_blocks/3
    defp heading/2
    defp list_line/3
    defp task_line/3
    defp quote_line/1
    defp take_table/1
    defp take_table/1
    defp rowish?/1
    defp sep?/1
    defp render_table/1
    defp parse_row/1
  @ lib/newbee/markdown.ex
▸ Newbee.Memory — 全局记忆 (DESIGN §6.4.3)：按 topic 索引的持久化记忆条目。
    def read/1
    def write/2
    def delete/1
    def topics/0
    defp redact/1
    defp sanitize_topic/1
  @ lib/newbee/memory.ex
▸ Newbee.Permissions — 权限档位 (DESIGN §8)：`lenient`（默认，放行+审计）/ `ask`（危险操作询问用户）/
    def levels/0
    def get/0
    def set/1
    def set/1
    def risky?/1
    def check/1
  @ lib/newbee/permissions.ex
▸ Newbee — 统一寻址读取 (DESIGN §3.2)：`Newbee.read/1` 通吃文件、目录、URL 与内部 scheme。
    def read/1
    def read/1
    defp read_path/1
    defp sensitive_path?/1
    defp read_skill/1
    defp read_agent/1
    defp read_conflict/1
    defp read_conflict/1
    defp read_rules/0
    defp read_memory/1
    defp read_bindings/0
    defp read_events/1
    defp read_url/1
    defp read_tool/1
  @ lib/newbee/reader.ex
▸ Newbee.Session — 会话持久化 (DESIGN §5.3/§3.8)：transcript JSONL 追加写 + 制品目录
    defstruct: id, dir, transcript
    def current_id/0
    def set_current/1
    def set_current/1
    def open/1
    def append/2
    def rewrite/2
    def messages/1
    def system_prompt/1
    def save_system_prompt/2
    def save_bindings/2
    def load_bindings/1
    def list_with_meta/1
    def meta/1
    def title/1
  @ lib/newbee/session.ex
▸ Newbee.Staging — 编辑暂存区（/approve 流程，DESIGN §5.3）：模型写文件先进暂存，
    use GenServer
    def start_link/1
    def stage/3
    def approve/1
    def reject/1
    def list/0
    def render/0
    def init/1
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    def handle_call/3
    defp try_approve_all/1
  @ lib/newbee/staging.ex
▸ Newbee.Tools.BestTool
    def run/0
  @ lib/newbee/tools/besttool.ex
▸ Newbee.Tools.Edit — 哈希锚点编辑 (DESIGN §3.2 文本轨) ⭐：
    def show/2
    defp show_line/3
    def patch/1
    defp parse_sections/1
    defp parse_line/2
    defp parse_line/2
    defp parse_header/1
    defp put_op/2
    defp put_in_ops/2
    defp parse_anchor_pair/1
    defp parse_single_anchor/1
    defp parse_op/2
    defp parse_op/2
    defp prepare_section/1
    defp resolve_op/2
  @ lib/newbee/tools/edit.ex
▸ Newbee.Tools.Fs — 文件系统工具 (DESIGN §3.2 代码 IO)：模型在 DEE 里调用的读写 API。
    def read/1
    def read!/1
    def write/2
    def write!/2
    def append!/2
    def rm/1
    def rm_rf/1
    defp emit_diff/3
    def guard_path!/1
    def exists?/1
    def ls/1
    def tree/1
    def size/1
  @ lib/newbee/tools/fs.ex
▸ Newbee.Tools.Http — HTTP 工具 (DESIGN §3.2 工具库)：GET/POST 封装，超时 + 响应截断。
    def get/2
    def post/3
    defp request/4
  @ lib/newbee/tools/http.ex
▸ Newbee.Tools.Introspect — 内省工具 (DESIGN §3.2 内省)：模块导出、beam chunk、类型信息。
    def exports/1
    def moduledoc/1
    def beam_info/1
  @ lib/newbee/tools/introspect.ex
▸ Newbee.Tools.Json — JSON 处理工具 (DESIGN §3.2 工具库)：解码/编码/美化/路径提取。
    def decode/1
    def encode/2
    def get!/2
    def get/2
  @ lib/newbee/tools/json.ex
▸ Newbee.Tools.JSpace — J-Space 工作区台账工具：把模型的内层工作区外部化为持久 ledger
    def root/0
    def ledger_path/1
    def current_session/0
    def exists?/1
    def read/1
    def note/2
    def seam/1
    def ship/3
    def resume/1
    def clear/1
    defp initial_ledger/0
    defp count_marked/2
    defp apply_fields/3
    defp apply_fields/3
    defp replace_line/3
  @ lib/newbee/tools/jspace.ex
▸ Newbee.Tools.Run — 命令执行工具 (DESIGN §3.2)：超时 + 输出上限，结果返回 exit code 与输出。
    def sh/2
    defp gate/1
    defp do_sh/2
    def mix_compile/1
    def mix_test/2
    def mix_format/1
    defp truncate/1
    defp truncate/1
  @ lib/newbee/tools/run.ex
▸ Newbee.Tools.Scaffold — 工程脚手架工具 (DESIGN §3.2 工程)：`mix new` / `mix deps.get` 等。
    def new_project/1
    def deps_get/0
    def compile/0
    def test/1
  @ lib/newbee/tools/scaffold.ex
▸ Newbee.Tools.Search — 搜索工具 (DESIGN M3 工具集)：内容 grep 与文件名查找。
    def grep/3
    def find/2
  @ lib/newbee/tools/search.ex
▸ Newbee.TUI — codex 式单列流式 TUI (DESIGN §5.1/§5.2)：全屏 ANSI 渲染。
    defstruct: lines, line_ed, kernel, client, busy, submit_pid, submit_kind, pending_inputs, picker, screen, page, streaming, stream_kind, render_pending, tool_blocks, last_block_id, show_reasoning, tool_open, usage, pane, out, awaiting_permission, text_buffer, last_paint
    def start/0
    defp pump/1
    defp reader_loop/4
    defp reader_loop/4
    defp loop/2
    defp handle_key/3
    defp submit/2
    defp submit_text/3
    defp enqueue_input/2
    defp submit_now/3
    defp maybe_start_next/1
    defp maybe_start_next/1
    defp handle_picker_key/2
    defp handle_picker_key/2
  @ lib/newbee/tui.ex
▸ Newbee.TUI.Cards — 工具块/命令卡片渲染（TUI 与 CLI 共用）：┌─ 标题 ─ 代码预览 ─ └─ 状态徽章 · 智能摘要 ─。
    def tool_header/2
    def tool_preview/1
    def tool_preview/1
    def tool_footer/1
    def error_line/1
    def diff_card/3
    defp numbered/1
    defp render_diff_line/2
    defp gutter/2
    def shell_header/1
    def shell_footer/1
    def smart_summary/2
    def smart_summary/2
    def smart_summary/2
    defp first_line/1
  @ lib/newbee/tui/cards.ex

## 常用命令
- 测试: mix test
- 编译: mix compile
- 格式化: mix format
