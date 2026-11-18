# MT1 / MT2 修复方案（只读评估，不改代码）

边界：不构建、不重启实例、不改 WPS 的 bun 产物。"能修"均指在 a0lite 仓库这层可落地。

## §1 MT2：58891 端口占用静默降级

原文（`dist/client/mac-poll-server.js:337-351`，与 `src/client/mac-poll-server.ts:318-327` 一字对应）：
```js
this.server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') {
        logger_1.log.warn(`[Mac] Port ${this.port} already in use, trying to reuse`);
        this._isRunning = true;
        resolve();          // ← 假成功：本进程没有 server，永远收不到 /result
    } else { reject(err); }
});
this.server.listen(this.port, '127.0.0.1', () => { this._isRunning = true; resolve(); });
```
后果链：`resolve()` → `wpsClient.start()` 认为就绪 → `executeCommand` 把命令塞进单槽位 `pendingCommand`（:442）→ 无人 `/poll` 取走 → 30 s 超时。错误文本没有"端口被占"，与"WPS 没开"完全同形。

修复思路（按推荐度）：
1. **a0 侧串行化（最小、零产物改动）**：`MCPConfig.call_tool` 外层加按 server 名的 `asyncio.Lock`，同一时刻只允许一个会话持有 58891。当前 4/5 的 EADDRINUSE 正是并发造成，串行化直接消因；TIME_WAIT 不阻塞 bind（Node `listen` 默认带 `SO_REUSEADDR`），真正的占用者只可能是还没退出的 bun。
2. **上游 dist 层（彻底）**：`EADDRINUSE` 分支改 `reject(new Error('port 58891 already in use (another MCP session owns it)'))`，一行改动，`call_tool` 秒级拿到 `ConnectionError`。
3. **`wps-mcp.sh` 预检（无效）**：`flatpak/wps-mcp-config.json` 与 a0 实际配置都**绕过**该入口直接跑 `bun dist/index.js`，脚本里加探测不会被调用。

**判断：能修。** 源码在 `build/build-Wps/files/wps-skills/wps-office-mcp/src/client/mac-poll-server.ts`（解包产物，非 git 源）。manifest 的源是上游 pinned tarball（`org.agentzero.AgentZero.Wps.yml:60-64`），`dist/` 来自本地预构建 `wps-office-mcp-deps.tar.gz`（:78-86）。patch 落点在 **`scripts/build-wps-deps.sh`**：`bun run build` 之后、`tar -czf` 之前对 `dist/client/mac-poll-server.js` 做文本替换，并更新 manifest 的 `ff53b592…` checksum——不重编译，只重打包 5 MB。

## §2 MT1：每次 `call_tool` 重启子进程，缓存必然丢失

原文（`helpers/mcp_handler.py:1347-1381`，`_execute_with_session`）：
```python
temp_stack = AsyncExitStack()
try:
    stdio, write = await self._create_stdio_transport(temp_stack)   # ← 每操作新建 bun 进程
    session = await temp_stack.enter_async_context(
        ClientSession(stdio, write, read_timeout_seconds=timedelta(seconds=read_timeout_seconds)))
    await session.initialize()                                     # ← 每次完整握手
    result = await coro_func(session); has_result = True           # ← 一次工具调用
except Exception as e:
    excs = getattr(e, "exceptions", None); original_exception = excs[0] if excs else e
await asyncio.wait_for(temp_stack.aclose(), timeout=MCP_SESSION_CLEANUP_TIMEOUT_SECONDS)
```
方法注释原话："Manages the lifecycle of an MCP session **for a single operation**"。缓存 Map 活在 bun 进程里，进程死缓存死。

复用会话的风险，按严重度：**① 并发丢命令（高）**——WPS 侧 `pendingCommand` 单槽位无保护（`mac-poll-server.js:442`），后请求覆盖前请求，前者 Promise 永不 settle，串行化可消除；**② 超时半关闭（中）**——外层超时取消可能留下半关闭 session，需"失败即丢弃重建"；**③ WPS 重启后陈旧连接与句柄累积（低）**——命令仍走 30 s 超时不会永久挂住，长生命周期 AsyncExitStack 常驻。

结论：**能修，但不要先动会话**。收益（省 0.3–0.5 s 启动 + 避免每次重走 switchApp 的 8–39 s）很大，但必须与串行化同批落地，否则只是把"缓存失效"换成"并发丢命令"。

最小改法（推荐顺序）：
1. **a0 侧缓存**（今天可做，风险近零）：`flatpak/a0flatpak/` 新增 `mcp_cache.py`，patch `MCPConfig.call_tool`，把 `cache_data`/`get_cached_data`/`list_cache`/`clear_cache` 拦在本地 `dict`，不转发 MCP。语义等价——数据本来就在同一 agent 会话内流转。
2. **串行化**：同一处 patch 外层加 `asyncio.Lock`（即 §1 方案 1）；**复用会话暂不做**，等前两步跑稳且有 `plugin_guard` 式重建逻辑后再评估。

不改的话，用户可读说明：*"每个 WPS 工具调用都是一次独立 MCP 会话。缓存类工具只能在同一进程内传数据，而 a0 每次调用都重启该进程，所以写入后立刻读取会得到「缓存键不存在」。请把中间数据留在对话里或写文件。"*

## §3 无 WPS 环境下的 250 个工具去向

| 结局 | 数量 | 说明 |
| --- | ---: | --- |
| **成功**（0.0 s，结构化返回） | **5** | `list_cache`、`clear_cache`、`cache_data`、`get_cached_data`、`ppt_set_active_target{clear}`；其中两个缓存工具写入即丢（MT1），跨调用仍有效的只有 **3** |
| **30 s 后 `isError:true`**（可读拒绝） | **≈93** | 走桥且不在 `COMMAND_APP_MAP`：`ping`、`get_app_info`、`wire_check`、`save`、`convert_to_pdf`、`add_chart` |
| **69 s 后 `isError:true`**（可读拒绝） | **≈151** | 走桥且在 `COMMAND_APP_MAP`，先跑 switchApp：`get_active_document`、`open_*`、`create_presentation`、`get_sheet_list` |
| **30 s 后 `isError:false`**（语义缺陷） | **1** | `wps_check_connection` |

合计 250。93/151 按实测 8:13 的 30 s/69 s 比例外推，非逐一调用所得。没有单独的"结构化未连接"档：除 5 个外，其余 245 个都要等满 30 s 或 69 s 才拿到失败信息。因此 **快速可用 = 5/250 = 2%**，**协议可达 = 250/250 = 100%**。**装了 WPS 后的成功率是 [推断]，未实测**：乐观 60–80%，受 MT10 的 8 对重复工具、MT2 端口竞争、每次重走 switchApp 三者拖累。

## §4 能修 vs 只能上报

| 缺陷 | 归属层 | 能否在 a0lite 修 |
| --- | --- | --- |
| MT2 端口静默降级 | 上游 bun 产物 + a0 会话调度 | **能**：串行化（立即）＋ `build-wps-deps.sh` patch dist（随下次构建） |
| MT1 缓存跨调用失效 | a0 的 `mcp_handler.py`（上游 agent-zero 文件） | **能**：`a0flatpak` 层 patch `call_tool`，四个缓存工具本地化 |
| MT3 `check_connection` isError=false / MT9 stderr 不落盘 / MT8 schema 生成器 | 上游 `mcp-server.js:128` / a0 可观测性 / 上游生成器 | **能**（同 dist patch、改 `mcp_handler` 落盘、改生成脚本），但 MT3 不建议在 a0 侧改判定，会掩盖上游语义 |
| MT4 schema 不校验 / MT5 参数语义冲突 / MT10 重复工具 / MT11 静默跳过重名 | 上游 tool-registry 与注册表 | **只能上报**：需引入 zod 或按业务判断去重，a0 侧替它选错更糟 |

## §5 与 M1 同一个根：生命周期不匹配

M1 是 `purge_namespace("plugins")` 后模块换新、补丁留在旧对象，`apply()` 用 `except ImportError: pass` 静默失败；修法是请求前自愈守卫（`a0flatpak.ensure()`）。三者同形：**M1 的补丁被插件重载丢弃、MT1 的缓存被每次新建会话丢弃、MT2 的端口由每个新 bun 反复抢而无人真正拥有**。共享根因是资源想活的时间 > 拥有者实际活的时间，且失效没有任何信号——三者都用了"假装成功"的降级（`pass` / 空 Map / `resolve()`）。

因此可共用一个 `ensure()` 守卫，挂三个钩子：`ensure_patch()`（M1，`browser.py:89-129` 的 `_a0flatpak_patched` 可提为通用装饰器）、`ensure_session()`（MT1，仅在启用复用会话时必需）、`ensure_port()`（MT2，启动后探一次 `/status`，拿不到就明确报错）。纪律相同：**降级必须留痕**，照抄 `browser.py` 里 `prepare_playwright_cache` 往 `warnings` 追加说明的做法。

## §6 已实现（源码树，待构建）

**一个新增文件**：`flatpak/a0flatpak/mcp_cache.py`（415 行，`python3 -m py_compile` 通过）。MT9 也在此文件内用 patch 完成，因此**没有改 `mcp_handler.py`**——`a0flatpak/__init__.py` 的既有原则是"不碰框架文件，上游更新保持可合并"。

- 拦截点真实签名：`MCPConfig.call_tool(self, tool_name: str, input_data: dict[str, Any]) -> CallToolResult`（`helpers/mcp_handler.py:1260`）。`tool_name` 形如 `wps_office.wps_cache_data`，先按第一个 `.` 拆成 server 与 tool。
- 四个工具在**本进程**应答，不转发 MCP；返回文本逐字照抄 server（已用 stub 逐条比对通过）：
  - `cache_data` → `{"success":true,"key":K,"message":"数据已缓存，可在其他应用中通过 wps_get_cached_data 获取","cacheSize":N}`
  - `get_cached_data` 命中 → `{"success":true,"key":K,"data":D,"appType":A,"cachedAt":"…Z"}`；未命中 → `{"success":false,"error":"缓存键 \"K\" 不存在","availableKeys":[…]}`，`isError:true`
  - `list_cache` → `{"success":true,"count":N,"caches":[{"key","appType","cachedAt","ageMs"}]}`
  - `clear_cache` → `{"success":true,"message":"缓存 \"K\" 已清除"}` / `"缓存 \"K\" 不存在"` / `"已清除所有缓存，共 N 条"`
- 缓存上限：**100 条**、单条 **1 MiB**。超限返回可读错误（`缓存条目过多…` / `缓存条目过大…`），覆盖已有键不受条数上限阻挡。
- 锁键：**`server_name`，注册表挂在事件循环对象上**（`loop._a0flatpak_mcp_locks`），同一 server 串行、不同 server 并行；不用 `id(loop)` 做键，因为 CPython 会复用 id，新循环会拿到绑定死循环的旧锁。排队上限 **默认 600 s**，可用 `A0_MCP_LOCK_TIMEOUT` 覆盖（每次调用重读，非法或非正值回退默认并写一行 stderr）；超时返回中文 `{"error":"MCP_BUSY","message":"另一个 WPS MCP 调用仍在运行，已排队等待 600 秒仍未轮到本次调用；请稍后重试，或增大环境变量 A0_MCP_LOCK_TIMEOUT…","retryable":true,"timeoutSeconds":600}` + `isError:true`。捕获到 `EADDRINUSE`/`already in use`/`58891` 时返回 `{"error":"MCP_PORT_IN_USE","message":"port 58891 already in use: …"}`。
- 幂等标记放在函数上（`call_tool.__a0flatpak_mcp__`）而非类上，`health()` 因此能发现"patch 被后来者覆盖"。
- MT9：`MCPClientLocal._create_stdio_transport` 预先塞入 `_TeeLog`，原 `TemporaryFile` 行为不变，同时追加到 `$A0_BASE_DIR/usr/logs/mcp-<server>.log`（`get_log()` 的 `seek`/`read` 仍读临时文件；磁盘写失败只吞 `OSError`）。

**已用 stub 验证**：3 并发同 server 峰值并发 1（0.2 s/次 × 3 = 0.60 s）；2 并发不同 server 并行；跨 3 个独立事件循环各调一次无陈旧锁；`A0_MCP_LOCK_TIMEOUT` 的 600/900/`abc`/`-5` 四种取值分别得到 600/900/600/600 且坏值有 stderr 告警；`MCP_BUSY`、`MCP_PORT_IN_USE`、条目/大小上限、tee 双写与 close 后抛 `ValueError` 均符合预期。

**构建后按序验证**：
1. `flatpak run --command=sh org.agentzero.AgentZero -c "cd /app/share/agent-zero && PYTHONPATH=/app/share/agent-zero:/app/share/flatpak /var/data/agent-zero/venv/bin/python -c 'import a0flatpak; a0flatpak.apply(); from a0flatpak import mcp_cache; print(mcp_cache.health())'"` → 期望 `True`。
2. 同一会话内先 `wps_office.wps_cache_data {key:"p",data:{v:1}}` 再 `wps_office.wps_get_cached_data {key:"p"}` → 期望第二次 `success:true`（修复前是"缓存键不存在"）。
3. `ls $A0_BASE_DIR/usr/logs/mcp-wps_office.log` → 期望存在且非空（MT9 生效）。
