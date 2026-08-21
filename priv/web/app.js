/* newbee WebUI 前端（移植 dsh client/web 会话 shell 语义，无构建依赖原生 JS）。
 * 信道：REST RPC（POST /api/<method>）+ WebSocket 事件下行（/ws?session=）。 */
(() => {
  // ── Markdown 渲染器（零依赖，覆盖 newbee.Markdown 同语法集，输出安全 HTML）──
  // 语法：ATX 标题、围栏代码块、引用、无序/有序/任务列表、水平线、表格、
  // 行内 **bold** *italic* `code` [text](url) ~~del~~。全部经 escapeHtml 防注入。
  function renderMarkdown(text) {
    const lines = String(text || "").split(/\r?\n/);
    const out = [];
    let i = 0;
    let listStack = null; // {type:'ul'|'ol', html:[]}

    const closeList = () => {
      if (listStack) { out.push(`<${listStack.type}>${listStack.html.join("")}</${listStack.type}>`); listStack = null; }
    };

    while (i < lines.length) {
      const line = lines[i];

      // 围栏代码块
      const fence = line.match(/^\s*(`{3})([^\s`]*)\s*$/);
      if (fence) {
        closeList();
        const lang = fence[2] || "";
        const body = [];
        i++;
        while (i < lines.length && !/^\s*`{3}\s*$/.test(lines[i])) { body.push(lines[i]); i++; }
        i++; // 跳过闭合 ```
        out.push(
          `<pre class="md-code"><div class="md-code-head"><span>${escapeHtml(lang || "code")}</span>` +
          `<button class="md-copy" data-code="${escapeHtml(body.join("\n")).replace(/"/g, "&quot;")}">复制</button></div>` +
          `<code>${escapeHtml(body.join("\n"))}</code></pre>`
        );
        continue;
      }

      // 表格：当前行含 | 且下一行是分隔行
      if (line.includes("|") && i + 1 < lines.length && /^\s*\|?[\s:\-|]+\|?\s*$/.test(lines[i + 1]) && lines[i + 1].includes("-")) {
        closeList();
        const header = splitRow(line);
        i += 2;
        const rows = [];
        while (i < lines.length && lines[i].includes("|") && lines[i].trim() !== "") { rows.push(splitRow(lines[i])); i++; }
        const th = header.map(c => `<th>${inline(c)}</th>`).join("");
        const trs = rows.map(r => `<tr>${r.map(c => `<td>${inline(c)}</td>`).join("")}</tr>`).join("");
        out.push(`<table class="md-table"><thead><tr>${th}</tr></thead><tbody>${trs}</tbody></table>`);
        continue;
      }

      // 标题
      const h = line.match(/^(\#{1,6})\s+(.*)$/);
      if (h) { closeList(); const lv = h[1].length; out.push(`<h${lv} class="md-h">${inline(h[2])}</h${lv}>`); i++; continue; }

      // 水平线
      if (/^\s*-{3,}\s*$/.test(line)) { closeList(); out.push('<hr class="md-hr" />'); i++; continue; }

      // 引用
      const q = line.match(/^>\s?(.*)$/);
      if (q) { closeList(); out.push(`<blockquote class="md-quote">${inline(q[1])}</blockquote>`); i++; continue; }

      // 任务列表
      const task = line.match(/^(\s*)[-*+]\s+\[([ xX])\]\s+(.*)$/);
      if (task) {
        if (!listStack || listStack.type !== "ul") { closeList(); listStack = { type: "ul", html: [] }; }
        const checked = task[2].toLowerCase() === "x" ? "checked" : "";
        listStack.html.push(`<li class="md-task"><input type="checkbox" disabled ${checked} /> ${inline(task[3])}</li>`);
        i++; continue;
      }

      // 无序列表
      const ul = line.match(/^\s*[-*+]\s+(.*)$/);
      if (ul) {
        if (!listStack || listStack.type !== "ul") { closeList(); listStack = { type: "ul", html: [] }; }
        listStack.html.push(`<li>${inline(ul[1])}</li>`);
        i++; continue;
      }

      // 有序列表
      const ol = line.match(/^\s*(\d+)[.)]\s+(.*)$/);
      if (ol) {
        if (!listStack || listStack.type !== "ol") { closeList(); listStack = { type: "ol", html: [] }; }
        listStack.html.push(`<li>${inline(ol[2])}</li>`);
        i++; continue;
      }

      // 空行
      if (line.trim() === "") { closeList(); i++; continue; }

      // 普通段落
      closeList();
      out.push(`<p class="md-p">${inline(line)}</p>`);
      i++;
    }
    closeList();
    return out.join("\n");
  }

  function splitRow(line) {
    return line.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map(c => c.trim());
  }

  // 行内渲染：**bold** *italic* `code` [text](url) ~~del~~，先转义再标记
  function inline(text) {
    let t = escapeHtml(text);
    t = t.replace(/`([^`\n]+)`/g, '<code class="md-inline">$1</code>');
    t = t.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    t = t.replace(/\*([^*\s][^*]*)\*/g, "<em>$1</em>");
    t = t.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
    t = t.replace(/\[([^\]\n]*)\]\(([^)\n]*)\)/g, '<a class="md-link" href="$2" target="_blank" rel="noopener">$1</a>');
    return t;
  }

  const $ = (id) => document.getElementById(id);
const transcript = $("transcript");
const flow = $("flow");
  const input = $("input");
  // ── 主题（黑/白切换，持久 localStorage，默认跟随系统）──
  function applyTheme(t, persist) {
    document.documentElement.setAttribute("data-theme", t);
    const btn = $("theme-toggle");
    if (btn) { btn.textContent = t === "light" ? "☾" : "☀"; btn.title = t === "light" ? "切换到暗色" : "切换到亮色"; }
    if (persist) localStorage.setItem("newbee.theme", t);
  }
  function initTheme() {
    const saved = localStorage.getItem("newbee.theme");
    const sys = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    applyTheme(saved || sys, false);
  }

  const state = {
    sid: localStorage.getItem("newbee.sid") || null,
    ws: null,
    busy: false,
    currentAssistant: null,   // 流式 assistant 行
    currentReasoning: null,   // 流式 reasoning disclosure 元素
    currentTool: null,        // 进行中的 tool 卡片
    timing: { llmMs: 0, toolMs: 0, llmStart: null, toolStart: null,
              ftSum: 0, ftCount: 0, ftRecorded: false, outTok: 0 },
  };

  // ── RPC ──
  let rpcSeq = 0;
  async function rpc(method, payload) {
    const rpcId = `web-${Date.now()}-${rpcSeq++}`;
    const res = await fetch(`/api/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rpcId, method, payload }),
    });
    const body = await res.json();
    if (body.result && "ok" in body.result) return body.result.ok;
    const err = body.result && body.result.error;
    throw new Error(err ? err.message : `rpc ${method} failed`);
  }

  // ── WebSocket ──
  // 防重复连接：同一时间只保留一条活跃连接。重连定时器可取消，
  // 且 onclose 只在“这条 ws 仍是当前连接”时才排重连——避免 resume()
  // 主动 close 旧连接后，旧 onclose 又排一个 connect() 造成多连接并存、
  // 同一事件被多条连接各推一份而在前端重复渲染。
  let reconnectTimer = 0;
  function connect() {
    if (!state.sid) return;
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = 0; }
    if (state.ws) {
      // 让旧连接的 onclose 失效，避免它再排重连
      state.ws.onclose = null;
      try { state.ws.close(); } catch (e) {}
      state.ws = null;
    }
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const boundSid = state.sid;          // 本连接绑定的会话（闭包固定，防切换后旧帧串入）
    const ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(state.sid)}`);
    state.ws = ws;
    ws.onmessage = (e) => {
      if (ws !== state.ws) return; // 过期连接的事件直接丢
      const frame = JSON.parse(e.data);
      if (frame.type === "event") {
        // 多会话并存：只渲染当前会话的事件；frame.sessionId 由后端 socket 下行携带
        if (frame.sessionId && frame.sessionId !== state.sid) return;
        if (boundSid !== state.sid) return; // 连接建立后用户已切到别的会话
        onEvent(frame.kind, frame.payload || {});
      }
      else if (frame.type === "system") pushEvoEvent(frame.topic, frame.payload);
    };
    ws.onclose = () => {
      if (ws !== state.ws) return; // 过期连接不重连
      if (state.ws === ws) state.ws = null;
      reconnectTimer = setTimeout(connect, 1500);
    };
  }

  // 耗时统计（对齐 TUI）：LLM 段 / 工具段 / 首 token / 速率
  function trackTiming(kind, p) {
    const t = state.timing, now = Date.now();
    switch (kind) {
      case "text":
      case "reasoning":
        if (t.llmStart === null) t.llmStart = now;
        if (t.llmStart !== null && !t.ftRecorded) { t.ftSum += now - t.llmStart; t.ftCount++; t.ftRecorded = true; }
        break;
      case "tool_start":
        if (t.llmStart !== null) { t.llmMs += now - t.llmStart; t.llmStart = null; }
        t.toolStart = now; t.ftRecorded = false;
        break;
      case "tool_result":
      case "tool_error":
        if (t.toolStart !== null) { t.toolMs += now - t.toolStart; t.toolStart = null; }
        t.llmStart = now;
        break;
      case "usage":
        const u = p.usage || {};
        t.outTok += u.completion_tokens || 0;
        break;
      case "turn_end":
      case "done": case "ask": case "error": case "interrupted":
        if (t.llmStart !== null) { t.llmMs += now - t.llmStart; t.llmStart = null; }
        if (t.toolStart !== null) { t.toolMs += now - t.toolStart; t.toolStart = null; }
        break;
    }
  }
  function fmtDur(ms) {
    const s = ms / 1000;
    if (ms > 0 && s < 0.05) return "<0.1s";
    if (s < 60) return (Math.round(s * 10) / 10) + "s";
    const w = Math.round(s);
    return Math.floor(w / 60) + "m" + (w % 60) + "s";
  }

  // ── 事件 → 渲染 ──
  function onEvent(kind, p) {
    trackTiming(kind, p);
    switch (kind) {
      case "text": appendStream(p.delta); break;
      case "reasoning": appendReasoning(p.delta); break;
      case "tool_start": toolStart(p); break;
      case "tool_result": toolResult(p.text, true, p.duration_ms); break;
      case "tool_error": toolResult(p.text, false); break;
case "done": finishTurn(); line("done", p.summary, true); break;
      case "ask": finishTurn(); line("ask", p.question); break;
      case "text_end": finishTurn(); break;
      case "error": finishTurn(); line("error", p.message); break;
      case "interrupted": finishTurn(); line("notice", "已中断"); break;
      case "permission_ask": showPermission(p.preview); break;
      case "usage": setUsage(p.usage); break;
      case "compacted": line("notice", `历史已压缩 ${p.count} 条`); break;
      case "model_switched": $("model-label").textContent = p.model; break;
      case "goal_start": line("notice", `目标开始: ${p.text}`); break;
      case "goal_done": line("notice", `目标达成: ${p.summary || ""}`); break;
      case "goal_cancelled": line("notice", `目标取消 (${p.reason || ""})`); break;
      case "rule_hit":
        (p.hits || []).forEach(h => line("notice", `⚑ 沉睡规则命中 [${h.id}] ${h.injection}`));
        break;
      case "prompt_injection": promptInjection(p); break;
case "advisor_note": line("notice", `◉ advisor: ${p.text}`); break;
case "notice": line("notice", p.text); break;
case "shell_result": shellResult(p); break;
case "file_diff": fileDiff(p); break;
case "turn_long": line("notice", `本轮较长：${p.step || ""} 步`); break;
case "tool_warnings": line("notice", `工具警告: ${(p.warnings || []).join("; ")}`); break;
case "final_check": line("notice", `最终检查: ${p.score ?? ""}`); break;
case "final_check_low": line("notice", `质量分偏低: ${p.score ?? ""}`); break;
case "progress": break;
case "progress_stall": line("notice", "进度停滞，模型在重试"); break;
case "goal_retry": line("notice", `目标重试 (${p.retries || 0})`); break;
case "goal_limit": line("notice", `目标达轮数上限 (${p.max || ""})`); break;
case "goal_round": break;
      case "turn_end": finishTurn(); break;
      default: break;
    }
    scrollBottom();
  }

  function finishTurn() {
    state.busy = false;
    if (state.currentAssistant) {
      state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
      bindCopyButtons(state.currentAssistant);
    }
    archiveReasoning();
    state.currentAssistant = null;
    state.currentTool = null;
    setBusy(false);
    hidePermission();
    clearTurnStatus();
    streamAcc = "";
  }

  function el(cls, text, md) {
    const d = document.createElement("div");
    d.className = `msg ${cls}`;
    if (text) { if (md) d.innerHTML = renderMarkdown(text); else d.textContent = text; }
    flow.appendChild(d);
    return d;
  }

  function line(kind, text, md) {
    el(`msg-${kind}`, text || "", md);
    scrollBottom();
  }

  function promptInjection(p) {
    const d = document.createElement("details");
    d.className = "msg msg-prompt-injection";

    const summary = document.createElement("summary");
    const source = p.source || "unknown";
    const role = p.role || "system";
    const timing = p.timing || "next_request";
    summary.textContent = `Prompt 注入 · ${source} · ${role} · ${timing}`;
    d.appendChild(summary);

    const meta = document.createElement("div");
    meta.className = "prompt-injection-meta";
    meta.textContent = `原因: ${p.reason || "未说明"}`;
    d.appendChild(meta);

    if (p.trigger) {
      const trigger = document.createElement("pre");
      trigger.className = "prompt-injection-trigger";
      trigger.textContent = `触发内容:\n${p.trigger}`;
      d.appendChild(trigger);
    }

    if (Array.isArray(p.rules) && p.rules.length) {
      const rules = document.createElement("pre");
      rules.className = "prompt-injection-rules";
      rules.textContent = "规则:\n" + p.rules.map(r =>
        `[${r.id}] scope=${r.scope || "all"} source=${r.source || "unknown"}\n/${r.pattern || ""}/`
      ).join("\n");
      d.appendChild(rules);
    }

    const content = document.createElement("pre");
    content.className = "prompt-injection-content";
    content.textContent = `实际注入 (${role}):\n${p.content || ""}`;
    d.appendChild(content);
    flow.appendChild(d);
  }


  let streamAcc = "";
  let streamRaf = 0;
  function appendStream(delta) {
    // 文本到来时归档 reasoning（去 running，下次 reasoning 开新块）
    archiveReasoning();
    if (!state.currentAssistant) {
      state.busy = true; setBusy(true);
      clearTurnStatus();
      state.currentAssistant = el("msg-assistant", "");
    }
    streamAcc += delta || "";
    state.currentAssistant.dataset.raw = streamAcc;
    if (!streamRaf) {
      streamRaf = requestAnimationFrame(() => {
        streamRaf = 0;
        if (state.currentAssistant) {
          state.currentAssistant.innerHTML = renderMarkdown(streamAcc);
          bindCopyButtons(state.currentAssistant);
          scrollBottom();
        }
      });
    }
  }

  // reasoning 渲染对齐 dsh ReasoningRow：默认折叠的 disclosure。
  // 标题行 ▸/▾ Think + 摘要；流式时摘要跟随最新一行，完成后收敛到首行；点击展开全文。
  function firstLine(t) { const i = t.indexOf("\n"); return i === -1 ? t : t.slice(0, i); }
  function latestLine(t) { const v = t.replace(/\s+$/, ""); const i = v.lastIndexOf("\n"); return i === -1 ? v : v.slice(i + 1); }
  // Think 块：自包含 disclosure。数据存在元素 dataset 上（thinkText 全文、open 0/1），
  // 每个块独立展开/收缩，互不影响；归档后留在页面原位。
  function renderReasoningBody(el) {
    const text = el.dataset.thinkText || "";
    const open = el.dataset.open === "1";
    const running = el.classList.contains("running");
    el.innerHTML = "";
    const head = document.createElement("div");
    head.className = "think-head";
    const trimmed = text.replace(/\s+$/, "");
    const summary = trimmed === "" ? "…" : (running ? latestLine(trimmed) : firstLine(trimmed));
    head.innerHTML = `<span class="think-chev">${open ? "▾" : "▸"}</span><span class="think-title">Think</span><span class="think-sep"></span><span class="think-summary">${escapeHtml(summary)}</span>`;
    head.addEventListener("click", () => {
      el.dataset.open = open ? "0" : "1";
      renderReasoningBody(el);
      if (!open) scrollBottom();
    });
    el.appendChild(head);
    if (open && trimmed !== "") {
      const body = document.createElement("div");
      body.className = "think-body";
      body.textContent = text;
      el.appendChild(body);
    }
  }
  let reasoningRaf = 0;
  function appendReasoning(delta) {
    if (!state.currentReasoning) {
      state.currentReasoning = el("msg-reasoning running", "");
      state.currentReasoning.dataset.thinkText = "";
      state.currentReasoning.dataset.open = "0";
      state.currentAssistant = null;
    }
    state.currentReasoning.dataset.thinkText += delta || "";
    if (!reasoningRaf) {
      reasoningRaf = requestAnimationFrame(() => {
        reasoningRaf = 0;
        if (state.currentReasoning) {
          renderReasoningBody(state.currentReasoning);
          scrollBottom();
        }
      });
    }
  }
  function archiveReasoning() {
    const r = state.currentReasoning;
    if (!r) return;
    r.classList.remove("running");
    r.dataset.open = "0";
    renderReasoningBody(r);
    state.currentReasoning = null;
  }

  function toolStart(p) {
    // 工具开始时归档当前 reasoning 块（去 running，下次 reasoning 开新块）
    archiveReasoning();
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>${escapeHtml(p.name || "tool")}</b> <span class="diffstat">${escapeHtml(p.title || "")}</span><span class="tool-dur"></span>`;
    const code = document.createElement("div");
    code.className = "tool-code hidden";
    code.textContent = (p.code || "").split("\n").slice(0, 12).join("\n");
    const result = document.createElement("div");
    result.className = "tool-result hidden";
    card.append(head, code, result);
    // 默认折叠，点 head 展开 code + result
    head.style.cursor = "pointer";
    head.addEventListener("click", () => {
      const open = code.classList.contains("hidden");
      code.classList.toggle("hidden", !open);
      result.classList.toggle("hidden", !open);
      head.querySelector(".tool-chev")?.remove();
      if (!open) return;
      const chev = document.createElement("span");
      chev.className = "tool-chev";
      chev.textContent = " ▾";
      chev.style.color = "var(--nb-label-caption)";
      head.appendChild(chev);
    });
    flow.appendChild(card);
    card.dataset.startedAt = Date.now();
    state.currentTool = result;
    state.currentToolCard = card;
    state.currentAssistant = null;
  }

  function toolResult(text, ok, durationMs) {
    if (!state.currentTool) return;
    state.currentTool.classList.add(ok ? "ok" : "err");
    state.currentTool.textContent = (text || "").split("\n").slice(0, 30).join("\n");
    stampDuration(state.currentToolCard, durationMs);
    state.currentTool = null;
    state.currentToolCard = null;
  }
  // 工具用时（对齐 TUI ⏱ format_duration）：<60s → X.Xs，否则 Xm Y.Ys
  function formatDur(ms) {
    const secs = ms / 1000;
    if (ms > 0 && secs < 0.05) return "<0.1s";
    if (secs < 60) return (Math.round(secs * 10) / 10) + "s";
    const m = Math.floor(secs / 60);
    const s = Math.round((secs - m * 60) * 10) / 10;
    return m + "m " + s + "s";
  }
  function stampDuration(card, durationMs) {
    const slot = card && card.querySelector(".tool-dur");
    if (!slot) return;
    let ms = durationMs;
    if (ms == null && card.dataset.startedAt) ms = Date.now() - Number(card.dataset.startedAt);
    if (ms == null) return;
    slot.textContent = " ⏱ " + formatDur(ms);
  }

  function shellResult(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    head.innerHTML = `<b>$</b> ${escapeHtml(p.cmd || "")}`;
    const out = document.createElement("div");
    out.className = "tool-result " + (p.exit === 0 ? "ok" : "err");
    out.textContent = (p.output || "").split("\n").slice(0, 40).join("\n");
    card.append(head, out);
    flow.appendChild(card);
    state.currentAssistant = null;
  }
  // dsh 文件 diff 卡片：+/- 行内联着色
  function fileDiff(p) {
    const card = document.createElement("div");
    card.className = "msg msg-tool";
    const head = document.createElement("div");
    head.className = "tool-head";
    const st = p.stats || {};
    head.innerHTML = `<b>✎</b> ${escapeHtml(p.path || "")} <span class="diffstat">+${st.added ?? 0} −${st.removed ?? 0}</span>`;
    const body = document.createElement("div");
    body.className = "tool-code";
    (p.diff || []).slice(0, 60).forEach((ln) => {
      const row = document.createElement("div");
      const t = typeof ln === "string" ? ln : (ln.text || "");
      if (t.startsWith("+")) row.style.color = "var(--nb-green)";
      else if (t.startsWith("-")) row.style.color = "var(--nb-red)";
      row.textContent = t;
      body.appendChild(row);
    });
    card.append(head, body);
    flow.appendChild(card);
    state.currentAssistant = null;
  }



  function showPermission(preview) {
    $("perm-preview").textContent = preview || "";
    $("permission-bar").classList.remove("hidden");
  }
  function hidePermission() { $("permission-bar").classList.add("hidden"); }

  function permission(ok) {
    if (state.ws && state.ws.readyState === 1) {
      state.ws.send(JSON.stringify({ type: "permission", ok }));
    } else {
      rpc("respond", { sessionId: state.sid, permission: ok }).catch(() => {});
    }
    hidePermission();
  }

  // ── 会话管理 ──
  // 搜索关键字（"" 表示不过滤）；state.allSessions 缓存最近一次 session.list 响应
  let sessionFilter = "";

  async function loadSessions() {
    const list = await rpc("session.list", {});
    state.allSessions = list.sessions || [];
    renderSessionList();
  }

  function renderSessionList() {
    const box = $("session-list");
    box.innerHTML = "";
    const kw = sessionFilter.trim().toLowerCase();
    const all = state.allSessions || [];
    // 过滤：关键字命中 title/id；空会话（0 条消息且非当前）不显示
    const items = all.filter((s) => {
      if (kw && !String(s.title || "").toLowerCase().includes(kw) && !String(s.id).toLowerCase().includes(kw)) return false;
      if ((s.messages || 0) === 0 && s.id !== state.sid) return false;
      return true;
    });
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "session-empty";
      empty.textContent = kw ? "没有匹配「" + kw + "」的会话" : "暂无会话";
      box.appendChild(empty);
      return;
    }
    items.forEach((s) => {
      const item = document.createElement("div");
      item.className = "session-item" + (s.id === state.sid ? " active" : "");
      const title = String(s.title || s.id).replace(/\s+/g, " ").trim().slice(0, 40) || "(未命名)";
      const stCls = s.busy ? "busy" : (s.running ? "online" : "offline");
      item.innerHTML = `<span class="t"><span class="sess-dot ${stCls}"></span>${escapeHtml(title)}</span><span class="meta">${escapeHtml(s.when_str || "")} · ${s.messages || 0} 条</span>`;
      item.dataset.sid = s.id;
      item.onclick = (e) => {
        if (e.target.classList.contains("menu-btn")) return; // 点 ⋯ 不切换会话
        resume(s.id);
      };
      // ⋯ 菜单钮
      const btn = document.createElement("button");
      btn.className = "menu-btn";
      btn.textContent = "⋯";
      btn.title = "更多操作";
      btn.onclick = (e) => { e.stopPropagation(); openSessionMenu(e, s); };
      item.appendChild(btn);
      box.appendChild(item);
    });
  }

  // 轻量刷新会话运行状态：只更新已渲染列表项的状态点，不重建 DOM（避免闪烁）。
  // 会新增/删除的会话（如另一个 tab 新建）不处理，由 loadSessions 全量刷新负责。
  function refreshSessionStatus() {
    const box = $("session-list");
    if (!box || box.children.length === 0) return;
    rpc("session.list", {}).then((list) => {
      const all = list.sessions || [];
      const byId = {};
      all.forEach((s) => { byId[s.id] = s; });
      box.querySelectorAll(".session-item").forEach((item) => {
        const s = byId[item.dataset.sid];
        if (!s) return;
        const dot = item.querySelector(".sess-dot");
        if (!dot) return;
        const cls = s.busy ? "busy" : (s.running ? "online" : "offline");
        if (dot.className !== "sess-dot " + cls) dot.className = "sess-dot " + cls;
      });
    }).catch(() => {});
  }

  // ── 会话右键菜单（重命名 / 删除）──
  let menuSession = null;
  function openSessionMenu(e, s) {
    menuSession = s;
    const menu = $("session-menu");
    menu.classList.remove("hidden");
    const rect = e.currentTarget.getBoundingClientRect();
    const mw = 150, mh = 80;
    let x = rect.right + 4, y = rect.top;
    if (x + mw > window.innerWidth) x = rect.left - mw - 4;
    if (y + mh > window.innerHeight) y = window.innerHeight - mh - 8;
    menu.style.left = x + "px";
    menu.style.top = y + "px";
  }
  function closeSessionMenu() {
    $("session-menu").classList.add("hidden");
    menuSession = null;
  }
  document.addEventListener("click", (e) => {
    if (!e.target.closest("#session-menu") && !e.target.classList.contains("menu-btn")) closeSessionMenu();
  });

  $("session-menu").addEventListener("click", async (e) => {
    const act = e.target.dataset.act;
    if (!act || !menuSession) return;
    const s = menuSession;
    closeSessionMenu();
    if (act === "rename") {
      const t = prompt("重命名会话：", s.title || s.id);
      if (t === null) return;
      const title = t.trim();
      if (!title) return;
      try {
        await rpc("session.rename", { sessionId: s.id, title });
        if (s.id === state.sid) $("session-title").textContent = title;
        await loadSessions();
      } catch (err) { line("error", "重命名失败: " + err.message); }
    } else if (act === "delete") {
      const title = String(s.title || s.id).slice(0, 40);
      confirmDialog("删除会话「" + title + "」？此操作不可恢复。", async () => {
        try {
          await rpc("session.delete", { sessionId: s.id });
          if (s.id === state.sid) {
            state.sid = null;
            localStorage.removeItem("newbee.sid");
            await newSession();
          }
          await loadSessions();
        } catch (err) { line("error", "删除失败: " + err.message); }
      });
    }
  });

  // ── 确认弹窗 ──
  let confirmCb = null;
  function confirmDialog(text, cb) {
    $("confirm-body").textContent = text;
    $("confirm-modal").classList.remove("hidden");
    confirmCb = cb;
  }
  $("confirm-ok").onclick = () => {
    $("confirm-modal").classList.add("hidden");
    if (confirmCb) { const cb = confirmCb; confirmCb = null; cb(); }
  };
  $("confirm-cancel").onclick = () => {
    $("confirm-modal").classList.add("hidden");
    confirmCb = null;
  };

  // ── 顶栏标题双击重命名 ──
  function attachTitleRename(el) {
    el.addEventListener("dblclick", () => {
      if (!state.sid) return;
      const cur = el.textContent;
      const inp = document.createElement("input");
      inp.className = "session-title-input";
      inp.value = cur;
      inp.maxLength = 60;
      const finish = async (commit) => {
        const v = inp.value.trim();
        const span = document.createElement("span");
        span.id = "session-title";
        span.className = "session-title";
        span.title = "双击重命名";
        span.textContent = commit && v ? v : cur;
        inp.replaceWith(span);
        attachTitleRename(span);
        if (commit && v && v !== cur) {
          try {
            await rpc("session.rename", { sessionId: state.sid, title: v });
            await loadSessions();
          } catch (err) { line("error", "重命名失败: " + err.message); }
        }
      };
      inp.addEventListener("keydown", (e) => {
        if (e.key === "Enter") { e.preventDefault(); finish(true); }
        else if (e.key === "Escape") { e.preventDefault(); finish(false); }
      });
      inp.addEventListener("blur", () => finish(true));
      el.replaceWith(inp);
      inp.focus();
      inp.select();
    });
  }
  attachTitleRename($("session-title"));

  // ── 侧栏折叠 ──
  function applySidebar(collapsed, persist) {
    document.getElementById("app").classList.toggle("sidebar-collapsed", collapsed);
    $("sidebar-expand").classList.toggle("hidden", !collapsed);
    const tog = $("sidebar-toggle");
    if (tog) tog.textContent = collapsed ? "⟩" : "⟨";
    if (persist) localStorage.setItem("newbee.sidebar", collapsed ? "1" : "0");
  }
  function initSidebar() {
    applySidebar(localStorage.getItem("newbee.sidebar") === "1", false);
  }
  const sidebarToggleBtn = $("sidebar-toggle");
  if (sidebarToggleBtn) sidebarToggleBtn.onclick = () => applySidebar(true, true);
  const sidebarExpandBtn = $("sidebar-expand");
  if (sidebarExpandBtn) sidebarExpandBtn.onclick = () => applySidebar(false, true);

  // ── 会话搜索 ──
  const searchInput = $("session-search");
  if (searchInput) searchInput.addEventListener("input", (e) => {
    sessionFilter = e.target.value || "";
    renderSessionList();
  });

  async function resume(sid) {
    state.sid = sid;
    localStorage.setItem("newbee.sid", sid);
    flow.innerHTML = "";
    await rpc("session.resume", { sessionId: sid });
    const [hist, sessionState] = await Promise.all([
      rpc("session.history", { sessionId: sid }),
      rpc("session.state", { sessionId: sid }),
    ]);
    renderHistory(hist.messages || []);
    const curModel = sessionState.model || "";
    const curProvider = sessionState.provider || "";
    $("model-label").textContent = (curProvider && curModel) ? curProvider + "/" + curModel : (curModel || "(no model)");
    connect();
    loadSessions();
    const firstUser = (hist.messages || []).find(m => m && m.role === "user");
    const title = firstUser ? String(firstUser.content || "").replace(/\s+/g, " ").trim().slice(0, 48) : sid;
    $("session-title").textContent = title || sid;
  }

  async function newSession() {
    const created = await rpc("session.create", {});
    await resume(created.sessionId);
  }

  function renderHistory(msgs) {
    msgs.forEach((m) => {
      if (!m) return;
      if (m.role === "user") line("user", m.content);
      else if (m.role === "assistant") {
        if (m.reasoning) {
          const d = el("msg-reasoning", "");
          d.dataset.thinkText = m.reasoning;
          d.dataset.open = "0";
          renderReasoningBody(d);
        }

        if (m.content) { const d = el("msg-assistant", m.content, true); bindCopyButtons(d); }
        (m.toolCalls || []).forEach((tc) => toolStart({ name: tc.name, title: tc.title, code: tc.code }));
      } else if (m.role === "tool") {
        const ok = !(m.content || "").startsWith("✗");
        toolResult(m.content, ok);
      }
    });
    scrollBottom();
  }

  // ── 发送 ──
  async function send() {
    const text = input.value.trim();
    if (!text || !state.sid) return;
    input.value = "";
    autoGrow();
    line("user", text);
    state.busy = true; setBusy(true);
    try {
      if (state.ws && state.ws.readyState === 1) {
        state.ws.send(JSON.stringify({ type: "prompt", text }));
      } else {
        await rpc("session.prompt", { sessionId: state.sid, text });
      }
    } catch (e) {
      line("error", e.message);
      state.busy = false; setBusy(false);
    }
  }

  function interrupt() {
    if (state.ws && state.ws.readyState === 1) {
      state.ws.send(JSON.stringify({ type: "interrupt" }));
    } else if (state.sid) {
      rpc("session.cancel", { sessionId: state.sid }).catch(() => {});
    }
  }

  // ── 模型 ──
  async function openModels() {
    const data = await rpc("llm.models", { sessionId: state.sid });
    const providers = data.providers || [];
    const current = data.current || {};
    const curProvider = current.provider || "";
    const curModel = current.model || "";

    const pbox = $("model-providers");
    const mbox = $("model-options");
    pbox.innerHTML = "";
    mbox.innerHTML = "";

    // 待确认的选择（确定按钮点击时生效）
    let pending = { provider: curProvider, model: curModel };

    providers.forEach((p) => {
      if (!p || !p.name || !(p.models || []).length) return;
      const po = document.createElement("div");
      po.className = "model-provider" + (p.name === curProvider ? " current" : "");
      po.textContent = p.name;
      po.onclick = () => {
        pbox.querySelectorAll(".model-provider").forEach((x) => x.classList.remove("current"));
        po.classList.add("current");
        renderModels(p);
      };
      pbox.appendChild(po);
    });

    function renderModels(p) {
      mbox.innerHTML = "";
      (p.models || []).forEach((m) => {
        const o = document.createElement("div");
        const isSel = (p.name === pending.provider) && (m === pending.model);
        o.className = "model-opt" + (isSel ? " current" : "");
        o.textContent = m;
        o.onclick = () => {
          mbox.querySelectorAll(".model-opt").forEach((x) => x.classList.remove("current"));
          o.classList.add("current");
          pending = { provider: p.name, model: m };
        };
        mbox.appendChild(o);
      });
    }

    const def = providers.find((p) => p.name === curProvider) || providers[0];
    if (def) renderModels(def);

    // 确定：应用待选
    $("model-confirm").onclick = async () => {
      if (!pending.provider || !pending.model) return;
      try {
        await rpc("session.selectModel", { sessionId: state.sid, provider: pending.provider, model: pending.model });
        $("model-label").textContent = pending.provider + "/" + pending.model;
        $("model-modal").classList.add("hidden");
      } catch (e) {
        line("error", "切模型失败: " + e.message);
      }
    };

    $("model-modal").classList.remove("hidden");
  }



  // ── utils ──
  function setBusy(b) {
    $("status-dot").className = `dot ${b ? "busy" : "idle"}`;
    $("interrupt").classList.toggle("hidden", !b);
    $("send").disabled = b && false;  // 允许排队发送
    if (b) showTurnStatus(); else clearTurnStatus();
  }
  // dsh turn 状态行：shimmer 文字，turn 进行中显示
  let turnStatusEl = null;
  function showTurnStatus() {
    if (turnStatusEl) return;
    turnStatusEl = document.createElement("div");
    turnStatusEl.className = "msg turn-status";
    turnStatusEl.textContent = "正在思考…";
    flow.appendChild(turnStatusEl);
    scrollBottom();
  }
  function clearTurnStatus() {
    if (turnStatusEl) { turnStatusEl.remove(); turnStatusEl = null; }
  }
  function setUsage(u) {
    if (!u) return;
    const t = u.total_tokens || u["total_tokens"];
    if (t) $("usage-label").textContent = `${(t / 1000).toFixed(1)}k tok`;
  }
  function scrollBottom() {
    transcript.scrollTop = transcript.scrollHeight;
    $("to-bottom").classList.remove("show");
  }
  function autoGrow() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 160) + "px"; }
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // 代码块复制按钮（dsh MarkdownText codeLabels: copy/copied）
  function bindCopyButtons(root) {
    root.querySelectorAll(".md-copy").forEach((btn) => {
      if (btn.dataset.bound) return;
      btn.dataset.bound = "1";
      btn.onclick = () => {
        navigator.clipboard.writeText(btn.dataset.code || "").then(() => {
          btn.textContent = "已复制";
          setTimeout(() => (btn.textContent = "复制"), 1500);
        });
      };
    });
  }

  // ── 绑定 ──
  // 主题切换
  $("theme-toggle").onclick = () => {
    const cur = document.documentElement.getAttribute("data-theme") || "dark";
    applyTheme(cur === "light" ? "dark" : "light", true);
  };

  $("send").onclick = send;
  $("interrupt").onclick = interrupt;
  $("new-session").onclick = newSession;
  $("perm-yes").onclick = () => permission(true);
  $("perm-no").onclick = () => permission(false);
  $("model-label").onclick = openModels;
  $("model-cancel").onclick = () => $("model-modal").classList.add("hidden");
  // model-confirm 的 onclick 在 openModels 里动态绑定（每次打开重新捕获 pending）
  input.addEventListener("input", autoGrow);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
  });
  // 回到底部：滚动远离底部时浮现（dsh to-bottom 悬浮钮）
  transcript.addEventListener("scroll", () => {
    const far = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight > 200;
    $("to-bottom").classList.toggle("show", far);
  });
  $("to-bottom").onclick = () => scrollBottom();

  // ── 状态栏（对齐 dsh StatsLine）：轮询 session.state，拼 左统计 | 右状态 ──
  let statsTimer = null;
  function startStats() {
    if (statsTimer) clearInterval(statsTimer);
    refreshStats();
    statsTimer = setInterval(() => {
      refreshStats();
      refreshSessionStatus();
    }, 2000);
  }
  async function refreshStats() {
    if (!state.sid) return;
    try {
      const st = await rpc("session.state", { sessionId: state.sid });
      renderStats(st);
    } catch (e) { /* 忽略轮询错误 */ }
  }
  function fmtTok(n) {
    if (n == null || isNaN(n)) return "0";
    const sc = (v) => v >= 100 ? String(Math.round(v)) : (Math.round(v * 10) / 10).toString();
    if (n < 1000) return String(n);
    if (n < 1e6) return sc(n / 1000) + "K";
    return sc(n / 1e6) + "M";
  }
  function renderStats(st) {
    // 同步左侧模型名（provider/model）；轮询每 2s 自愈一次
    if (st && st.model) {
      const m = (st.provider && st.provider !== "default") ? st.provider + "/" + st.model : st.model;
      const el = $("model-label");
      if (el && el.textContent !== m) el.textContent = m;
    }
    const u = st.usage || {};
    const cacheRead = u.cache_read_tokens || u.cached_tokens
      || (u.prompt_tokens_details && u.prompt_tokens_details.cached_tokens) || 0;
    const inTok = (u.uncached_prompt_tokens || u.prompt_tokens || 0) + (u.cache_write_tokens || 0);
    const outTok = u.completion_tokens || u.output_tokens || 0;
    const cacheHit = inTok > 0 ? Math.round(cacheRead / inTok * 100) : null;
    const left = ["newbee"];
    const turns = st.turns || 0, steps = st.steps || 0;
    if (turns > 0 || steps > 0) left.push(`${turns} 轮 · ${steps} 步`);
    // LLM/工具耗时（dsh: LLM Xs · 工具 Ys）
    const tm = state.timing;
    const llmMs = tm.llmMs + (tm.llmStart !== null ? Date.now() - tm.llmStart : 0);
    const toolMs = tm.toolMs + (tm.toolStart !== null ? Date.now() - tm.toolStart : 0);
    if (llmMs > 0 || toolMs > 0) left.push(`LLM ${fmtDur(llmMs)} · 工具 ${fmtDur(toolMs)}`);
    // 首 token · 速率（dsh: 首 token Zs · T tok/s）
    const spd = [];
    if (tm.ftCount > 0) spd.push(`首 token ${fmtDur(tm.ftSum / tm.ftCount)}`);
    if (llmMs > 0 && tm.outTok > 0) spd.push(`${(tm.outTok / (llmMs / 1000)).toFixed(1)} tok/s`);
    if (spd.length) left.push(spd.join(" · "));
    if (cacheHit !== null) left.push(`缓存 ${cacheHit}%`);
    if (inTok > 0 || outTok > 0) left.push(`入 ${fmtTok(inTok)} · 出 ${fmtTok(outTok)}`);
    $("stats-left").innerHTML = left.join(" | ");
    const stTxt = st.busy ? '<span class="st-busy">● 运行中</span>' : '<span class="st-ok">● 空闲</span>';
    $("stats-right").innerHTML = `${stTxt} bind:${st.bindings || 0} ${escapeHtml(st.policy || "")}`;
  }

  // ── 进化面板（最左，默认收起）──
  function initEvolution() {
    applyEvo(localStorage.getItem("newbee.evo") === "1", false);
    const expandBtn = $("evo-expand");
    if (expandBtn) expandBtn.onclick = () => applyEvo(true, true);
    const collapseBtn = $("evo-collapse");
    if (collapseBtn) collapseBtn.onclick = () => applyEvo(false, true);
    const refreshBtn = $("evo-refresh");
    if (refreshBtn) refreshBtn.onclick = () => refreshEvolution();
    refreshEvolution();
    // 每 10s 轮询状态；事件经 WS 实时增量（onEvent 里的 evo_* 分支）
    setInterval(refreshEvoStatus, 10_000);
  }

  function applyEvo(open, persist) {
    document.getElementById("app").classList.toggle("evo-open", open);
    const expandBtn = $("evo-expand");
    if (expandBtn) expandBtn.style.display = open ? "none" : "flex";
    if (persist) localStorage.setItem("newbee.evo", open ? "1" : "0");
    if (open) flushEvoBuffer();
  }

  async function refreshEvolution() {
    await Promise.all([refreshEvoStatus(), refreshEvoFeed()]);
  }

  async function refreshEvoStatus() {
    try {
      const st = await rpc("evolution.status", {});
      const setV = (id, v) => { const el = $(id); if (el) el.textContent = v == null ? "-" : String(v); };
      setV("evo-autonomy", st.autonomy);
      const cs = st.coordinator || {};
      if (typeof cs === "object") {
        setV("evo-revision", cs.active_revision != null ? "r" + cs.active_revision : "-");
        setV("evo-changes", cs.changes != null ? cs.changes : "-");
      } else {
        setV("evo-revision", "-");
        setV("evo-changes", "-");
      }
      const kb = (st.event_log_bytes || 0) / 1024;
      setV("evo-events-size", kb >= 1024 ? (kb / 1024).toFixed(1) + " MB" : Math.round(kb) + " KB");
    } catch (e) { /* 忽略轮询错误 */ }
  }

  async function refreshEvoFeed() {
    try {
      const feed = await rpc("evolution.feed", { n: 80 });
      renderEvoFeed(feed.events || []);
    } catch (e) { /* 忽略 */ }
  }

  function renderEvoFeed(events) {
    const box = $("evo-feed");
    if (!box) return;
    box.innerHTML = "";
    if (events.length === 0) {
      const d = document.createElement("div");
      d.className = "evo-empty";
      d.textContent = "暂无进化事件";
      box.appendChild(d);
      return;
    }
    events.forEach((ev) => box.appendChild(evoEventEl(ev)));
  }

  function evoEventEl(ev) {
    const d = document.createElement("div");
    const kind = ev.topic || "event";
    d.className = "evo-event kind-" + evoKindClass(kind);
    const time = (ev.at || "").replace("T", " ").slice(5, 19);
    const body = evoEventSummary(kind, ev.event);
    d.innerHTML = `<span class="evo-kind">${escapeHtml(kind)}</span><span class="evo-time">${escapeHtml(time)}</span><div class="evo-body">${escapeHtml(body)}</div>`;
    return d;
  }

  function evoKindClass(kind) {
    if (/reject|error|fail|degraded/.test(kind)) return "rejected";
    if (/activated|published|switched|created|advanced/.test(kind)) return "activated";
    return "info";
  }

  function evoEventSummary(kind, payload) {
    if (payload == null) return "";
    if (typeof payload === "string") return payload.slice(0, 200);
    try {
      // 对齐 Adapter 日志：列出关键字段
      const p = payload;
      switch (kind) {
        case "evolution_published":
          return `发布 ${p.release_id || p.plugin_id || "?"} · ${p.kind || ""}`;
        case "evolution_rejected":
          return `拒绝 ${p.release_id || p.plugin_id || "?"}: ${p.reason || ""}`;
        case "release_observation":
          return `${p.release_id || "?"} · ${p.model || ""} · ${p.success ? "✓" : "✗"} ${p.tokens || 0}tok ${p.latency_ms || 0}ms`;
        case "change_activated":
          return `激活 ${p.change_id || p.revision || "?"}`;
        case "change_rejected":
          return `拒绝 ${p.change_id || "?"}: ${p.reason || ""}`;
        case "change_rolled_back":
          return `回滚 ${p.change_id || "?"}: ${p.reason || ""}`;
        case "revision_advanced":
          return `推进至 r${p.revision || "?"}`;
        case "revision_degraded":
          return `r${p.revision || "?"} 退化: ${p.reason || ""}`;
        case "snapshot_created":
          return `快照 ${p.snapshot_id || p.generation || "?"}`;
        case "snapshot_restored":
          return `恢复快照 ${p.snapshot_id || p.generation || "?"}`;
        case "generation_switched":
          return `切换 gen → r${p.revision || "?"}`;
        case "generation_switch_failed":
          return `切换失败 r${p.revision || "?"}: ${p.reason || ""}`;
        case "audit":
          // audit 可能是 tuple 数组 ["audit","dangerous_code",[...],"none"]
          if (Array.isArray(p)) {
            const kind = p[1] || "";
            const arg1 = Array.isArray(p[2]) ? p[2].join(",") : String(p[2] || "");
            const arg2 = String(p[3] || "");
            return (kind + " " + arg1 + " " + arg2).trim();
          }
          return `${p.action || p.kind || ""} ${p.who || ""} ${Array.isArray(p.paths) ? p.paths.join(",") : (p.what || "")}`.trim();
        default:
          return JSON.stringify(payload).slice(0, 200);
      }
    } catch (e) {
      return String(payload).slice(0, 200);
    }
  }

  // 实时接收进化事件（从 WS 下行）。先入内存缓冲，面板展开时 flush；
  // 缓冲满则截断。这样即使面板收起，事件也不丢。
  let evoBuffer = [];
  function pushEvoEvent(topic, payload) {
    evoBuffer.unshift({ topic, event: payload, at: new Date().toISOString() });
    if (evoBuffer.length > 200) evoBuffer.length = 200;
    flushEvoBuffer();
  }
  function flushEvoBuffer() {
    const box = $("evo-feed");
    if (!box || !document.getElementById("app").classList.contains("evo-open")) return;
    if (evoBuffer.length === 0) return;
    const empty = box.querySelector(".evo-empty");
    if (empty) empty.remove();
    evoBuffer.forEach((ev) => box.prepend(evoEventEl(ev)));
    evoBuffer = [];
    while (box.children.length > 100) box.removeChild(box.lastChild);
  }

  // ── 启动 ──
  (async () => {
    initTheme();
    initSidebar();
    initEvolution();
    const host = await rpc("host.describe", {});
    $("model-label").textContent = host.model || "(no model)";
    if (!state.sid) {
      await newSession();
    } else {
      await resume(state.sid);
    }
    loadSessions();
    startStats();
  })().catch((e) => line("error", `启动失败: ${e.message}`));
})();
