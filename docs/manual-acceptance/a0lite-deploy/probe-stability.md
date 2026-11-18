# probe-stability：`compat.py` 的 `_TaskStub` 修复在长对话与并发下的稳定性验收

- 执行时间：2026-11-18 02:20 — 02:50（Asia/Shanghai）
- 宿主：7940HS / kunweiz / Manjaro / X11
- 对象：Flatpak user 安装 `org.agentzero.AgentZero`，commit `7a55c085a255e2777803a22c2c921789a88cf603aedac06fea7788fd118e7764`（v10）
- 入口：`http://127.0.0.1:5080`；聊天模型：外部 OpenAI 兼容端点 `http://127.0.0.1:18080/v1`，`mistral/deepseek-v4-1-flash-1017`
- 证据目录：`~/a0-local-backup/stability/`

## 0. 结论先行

1. **连续 10 条同上下文：通过。** 10/10 HTTP 200，答案全部正确；每条之后 `context.running=false`，第 10 条仍正常回答，没有排队或超时。
2. **长上下文：通过（有取证限制）。** 80,000 字符（cl100k 93,893 tokens）作为第 11 条发出，HTTP 200，34.80 s，返回 193 字三句话；应用侧 API 不返回 `finish_reason`，同 prompt 直连端点为 `stop`，未见 `max_tokens` 截断。
3. **并发 3 条不同 context：通过。** 三条在同一时刻发出，全部 200，耗时 6.16 / 7.50 / 9.03 s，全部回到 `running=false`，没有一条永久卡死。
4. **中断与恢复：通过。** `curl --max-time 2` 主动断开后，同一 context 的后续消息 2.27 s 返回「恢复」；中断前后的 `run_ui` PID 均为 1913196；`chat.json` 中没有留下卡住的 agent/response。
5. **日志：当前实例 0 条 `_TaskStub` / `TaskGroup` / `Traceback` / `AttributeError` / `RuntimeError` / `never retrieved` / `Unclosed`。** 仍有 22 条 litellm `LoggingWorker` 的 `Task was destroyed but it is pending!`，属非 `_TaskStub` 的既有警告，未影响回答。
6. **资源：** 02:25:49 采样 `run_ui` RSS 450,700 KB、fd 69、线程 45；02:39:53 为 RSS 451,340 KB、fd 217（eventpoll 66）；02:40:58 在一条额外聊天后回落到 fd 60（eventpoll 13）。RSS 全程 450.7–453.0 MB，**没有持续泄漏**；fd 是锯齿：monitor 的健康轮询期间临时升到 217，聊天/GC 后回落到 60。详见 6.2/6.4。
7. **外部干扰：** 02:21:06 另一个 worker 重启了 5080（新日志 `run-after-c42-022106.log`），正好打断第一次 10 条尝试的第 4 条；该次标记为「被外部重启打断」，不计入结论。02:21:21 起在新实例上完整重跑。
8. **判定：** 就本轮三项核心判据（10 条连续不卡、中断后可恢复、并发不互相卡死），**`compat` 修复可判通过**。保留意见是 litellm 的待销毁任务警告仍在、fd 有请求期锯齿（峰值 219，随后回落 59）、且应用侧无法直接读到 `finish_reason`/`usage`；这些都不构成本轮核心失败。

## 1. 环境与前置

| 项 | 值 |
|---|---|
| 应用 | `org.agentzero.AgentZero`，user 安装，commit `7a55c085a255e2777803a22c2c921789a88cf603aedac06fea7788fd118e7764`（v10） |
| 运行进程 | `venv/bin/python -c import a0flatpak; a0flatpak.apply(); import runpy; runpy.run_path('run_ui.py', run_name='__main__') --port=5080 --host=127.0.0.1`，PID **1913196**（02:21:06 启动） |
| 运行日志 | `~/a0-local-backup/run-after-c42-022106.log`（当前实例）；`run-c42-021953.log`（被外部重启的上一实例） |
| 安装树 compat | `~/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero/flatpak/a0flatpak/compat.py`，md5 `91f5674bfdd2a20802b3bf2c9f5e3ab3` |
| 仓库 compat | `flatpak/a0flatpak/compat.py`，md5 **相同** |
| 启动顺序 | launcher 先 `import a0flatpak; a0flatpak.apply()`；`a0flatpak.apply()` 第一项调用 `compat.apply()`，之后才加载 `helpers` 与 anyio |
| 聊天预设 | `usr/plugins/_model_config/presets.yaml`：provider `kw92`，model `mistral/deepseek-v4-1-flash-1017`，`ctx_length=1000000`，`ctx_history=0.7`，`max_tokens=384000` |
| 端点 | `http://127.0.0.1:18080/v1`；18080 监听正常；不占本地 Ollama 聊天模型 |
| API key | 由 `helpers/settings.py:create_auth_token()` 现算，16 字符；只在 `stability/.token` 短暂保存，报告不落值，收尾时删除 |
| health | 全轮 `GET /api/health` = 200 |

### 1.1 实例重启记录

| 时间 | 事件 | PID | 日志 |
|---|---|---|---|
| 02:19:53 | 上一实例启动（C42 worker） | 1912059 | `run-c42-021953.log` |
| **02:21:06** | **外部 worker 重启，打断第一次 case1 第 4 条** | 1912059 → **1913196** | `run-after-c42-022106.log` |
| 02:21:21 | 本 worker 在新实例上开始正式重跑 | 1913196 | 同上 |
| 02:21:06 — 本轮结束 | 无再重启（monitor 每 5 s 记录 PID，未出现 `CHANGED`） | 1913196 | `stability/instance-monitor.log` |

本 worker **未执行** `flatpak kill`、`systemctl restart` 或任何 5080 重启；未修改仓库源码、`conf/`、预设。

### 1.2 修复点核对（静态）

运行树：Python 3.14.10、anyio 4.15.1、litellm 1.104.0、httpx 0.28.1。

- `compat.apply()` 先改 `asyncio.wait_for`，再调用 `_patch_current_task()` 与 `_patch_sniffio()`；launcher 在 `import a0flatpak` 时调用 `apply()`，之后才 `from helpers import dotenv`，anyio 在更晚的请求路径才导入。anyio `_asyncio.py` 的 `from asyncio import current_task` 因而是补丁后的函数。
- anyio 4.15.1 的 `CancelScope._deliver_cancellation()` 读 `done()`、`_must_cancel`、`_fut_waiter` 和 `cancel()`；`__exit__` 读 `uncancel()`；`find_root_task()` 读 `done()`（其 `_unset` 回调读 `get_loop()`，但只注册在真实 task 上）；`WorkerThread` 读 `_loop`；`asyncio.timeout` 协议读 `cancelling()`/`uncancel()`。`_TaskStub` 对这些成员都有显式实现，没有用通用 `__getattr__` 伪造值。
- 残留风险（未在本轮触发）：`add_done_callback` 是空操作，anyio 用根任务注册的 `worker.stop` 回调不会执行，线程池 worker 只能靠 10 s 空闲回收；`_loop` 属性要求调用时存在 running loop，若未来有代码在工作线程里读 stub 的 `_loop` 会抛 `RuntimeError`。这两点在本轮 10+3+1 条请求中都没有出现，列为后续观察项，不构成本轮失败。

### 1.3 本地 Ollama 说明

应用启动后自动拉起 bundled Ollama：

```text
1913221 1913196  45,212  /app/share/agent-zero/models/bin/ollama serve
1916137 1913221 1,984,196 /app/share/agent-zero/models/lib/ollama/llama-server ... --mmproj ...
```

这是应用自身的本地模型 runner（约 2.0 GB RSS），不是本轮聊天调用；聊天仍只走 kw92/18080。它会影响宿主资源读数，故资源表同时记录 `run_ui` 与 bundled Ollama 两条进程。

## 2. 用例 1：连续 10 条同一 context

### 2.1 目的

验证 `_TaskStub` 修复在连续多轮下不会出现「回答已出但 `context.running` 卡 true / 后续消息排队」的旧故障。

### 2.2 命令

```sh
cd ~/a0-local-backup/stability
python3 probe.py case1 --out case1
```

脚本对每条执行：

```text
POST http://127.0.0.1:5080/api/api_message
  X-API-Key: <16 字符 token>
  {"message": "第N条：...只回答一个阿拉伯数字。", "context_id": "<首次返回的 id>"}
```

每条返回后立即用 `POST /api/poll`（session + CSRF）读取该 context 的 `running`、`paused`、`log_length`、`log_progress`。

### 2.3 正式重跑结果（context `YR4LPYg7`，PID 1913196 全程）

| # | 问题 | HTTP | 耗时 (s) | 回答 | `running` | `log_length` |
|---:|---|---:|---:|---|---|---:|
| 1 | 1+1 | 200 | 28.951 | `2` | false | 8 |
| 2 | 2+3 | 200 | 25.771 | `5` | false | 14 |
| 3 | 10-4 | 200 | 8.593 | `6` | false | 20 |
| 4 | 6*7 | 200 | 4.712 | `42` | false | 26 |
| 5 | 20/5 | 200 | 5.836 | `4` | false | 32 |
| 6 | 3 的平方 | 200 | 28.623 | `9` | false | 38 |
| 7 | 100 的一半 | 200 | 28.605 | `50` | false | 44 |
| 8 | 9+8 | 200 | 7.084 | `17` | false | 50 |
| 9 | 15-9 | 200 | 7.392 | `6` | false | 56 |
| 10 | 4*4 | 200 | 7.862 | `16` | false | 62 |

汇总：总耗时 **153.4 s**（脚本挂钟 153.68 s），中位数 8.23 s，最小 4.71 s，最大 28.95 s。10/10 为 HTTP 200；答案全部正确；每条之后 `log_progress="Waiting for input"`、`log_progress_active=false`、`running=false`；第 10 条仍能正常回答，没有排队或超时。

原始输出：`stability/case1-2026-02-21-good/`（`case1.json` + `msg-01.json` … `msg-10.json`）。

### 2.4 第一次尝试：被外部重启打断（不计入结论）

| # | HTTP | 耗时 (s) | 回答 | 说明 |
|---:|---:|---:|---|---|
| 1 | 200 | 7.110 | `2` | 旧实例 PID 1912059 |
| 2 | 200 | 3.823 | `5` | 同上 |
| 3 | 200 | 3.873 | `6` | 同上 |
| 4 | -1 | 0.782 | — | `RemoteDisconnected`；02:21:06 外部重启 |
| 5–10 | -1 | 0.0 | — | `ConnectionRefused`，实例尚未就绪 |

证据：`stability/case1-aborted-restart/case1.json`；对应日志 `run-c42-021953.log` 结尾只有第 4 条的请求、没有回答；新日志 `run-after-c42-022106.log` 从 02:21:06 开始。该次是外部重启造成的连接断开，**不是** `_TaskStub` 复现。

### 2.5 结论

**通过。** 10 条连续、同一 context、同一 PID；每条之后 `running=false`；第 10 条无卡死、无排队、无超时。

## 3. 用例 2：约 100k tokens 长上下文

### 3.1 构造与 token 估算

`stability/generate_long.py` 生成 16 个主题、312 段的变体中文材料，避免单一段落重复；末尾按目标长度截断，所以最后一段可能停在句中（模型在 thoughts 里写「(truncated)」，指的是这个截断，不是应用截断）。

| 指标 | 值 |
|---|---:|
| 字符数 | 80,000 |
| UTF-8 字节 | 237,034 |
| 段落数 | 312 |
| tiktoken `cl100k_base`（应用 venv） | **93,893 tokens** |
| 字符/1.5 粗估 | 53,333 tokens |
| 直连端点 `usage.prompt_tokens`（同一 prompt） | **46,887 tokens** |

tokenizer 与模型实际分词不同；以直连端点返回的 `prompt_tokens=46,887` 为端点侧实测，tiktoken 的 93,893 作为上界参考。两者都远小于 `ctx_length=1,000,000`。

### 3.2 请求与原始结果

第 11 条，复用 `YR4LPYg7`：

```sh
python3 -c '...'
curl -sS -m 600 -o long-response.json -w 'HTTP=%{http_code} total=%{time_total}\n' \
  http://127.0.0.1:5080/api/api_message \
  -H 'Content-Type: application/json' -H "X-API-Key: $(cat .token)" \
  --data-binary @long-payload.json
```

| 项 | 值 |
|---|---|
| 输入 | 80,000 字符正文 + 51 字符指令（`prompt_chars=80051`） |
| HTTP | **200** |
| 总耗时 | **34.800 s**（curl `time_total`） |
| 返回 | 193 字，三句话 |
| 返回长度 | 193 chars |
| `finish_reason`（应用 API） | 不返回该字段 |
| `finish_reason`（同 prompt 直连 18080，`max_tokens=384000`） | **`stop`** |
| 直连 `usage` | `prompt_tokens=46,887`，`completion_tokens=122`，`total_tokens=47,009` |

返回原文（节选）：

```text
这份资料以分节形式系统梳理了地理、生物、天文、建筑、音乐、数学、农业、交通、医学、语言、材料、海洋、气象、教育、工艺和历史等众多学科的基础知识要点。贯穿全文的核心线索是各类系统内部的相互关联与条件约束——局部调整往往引发连锁反应，评估时需同时考虑直接与间接影响。作者还反复强调方法论上的审慎：测量方式与样本选择会影响结论，观察者应在不同时间尺度上比较变化，避免把短期波动误判为长期趋势。
```

### 3.3 日志与截断核对

- `run-after-c42-022106.log` 中该请求前后没有 `Traceback` / `TaskGroup` / `_TaskStub` / `AttributeError` / `RuntimeError`。
- `chat.json`（`usr/chats/YR4LPYg7/chat.json`）里这条 `user` 日志的长度是 **15,000 字符**，且含 `<< ... Characters hidden >>`。原因在 `helpers/log.py:66 CONTENT_MAX_LEN=15_000`：日志/持久化层对非 `response` 内容截断，这是设计行为。
- **模型输入没有被这层截断。** `api/api_message.py` 把完整 `message` 传给 `UserMessage(message=message)`；`agent.py:hist_add_user_message()` 使用 `message.message` 构造 `fw.user_message.md` 历史。也就是说，15,000 只是 `chat.json`/UI 日志副本，LLM 历史仍是完整 80,051 字符。该结论是静态代码路径推导，标记为 **[推断]**，但与应用侧 34.8 s 的耗时、直连端点 46,887 prompt tokens 以及返回内容覆盖面一致。
- 应用日志把 `> {message}` 完整打印，这也是 `run-after-c42-022106.log` 在 02:25 涨到约 261 KB 的原因；日志文件本身不是堆栈或异常。
- **未证实项：** 模型的 thoughts 里出现 `The user provided a very long document (truncated)`。这可能是我们的正文在 80,000 字符处被截断在句中，也可能是 provider 侧按实际上下文窗口裁剪；应用 API 不返回 `usage`，无法区分。直连同一文本得到 `prompt_tokens=46,887`、`finish_reason=stop`，说明端点本身能处理这份文本；但应用侧组合 prompt（系统提示、工具定义、10 轮历史 + 长文）是否被 provider 裁剪，本轮没有直接证据。

### 3.4 结论

**通过（有取证限制）。** 长输入被接受并成功回答，没有 `max_tokens` 截断迹象，没有 `_TaskStub`/`TaskGroup` 异常。限制：`/api/api_message` 不返回 `finish_reason`/`usage`，应用侧 token 用量只能从直连端点与代码路径推断；`chat.json` 的 15,000 字符是日志副本截断（`CONTENT_MAX_LEN`），不是模型输入截断，但会让事后审计低估输入长度。

## 4. 用例 3：并发 3 条不同 context

### 4.1 命令

```sh
cd ~/a0-local-backup/stability
python3 case3.py
```

脚本用 `threading.Barrier(3)` 让三个线程同时发出，各自不带 `context_id`（由服务端新建），互不共享上下文。

### 4.2 结果

| 组 | 问题 | context_id | HTTP | 耗时 (s) | 回答 | 结束后 `running` |
|---|---|---|---:|---:|---|---|
| A | 7+8 | `RrDtDJif` | 200 | 7.504 | `15` | false |
| B | 12-5 | `BgkPVKyN` | 200 | 9.031 | `7` | false |
| C | 3*9 | `smYkMANx` | 200 | 6.156 | `27` | false |

三条的挂钟总时长 **9.032 s**（从 barrier 放行到最后一个线程返回）；每条都 HTTP 200、答案正确；每条之后 `/api/poll` 均 `running=false`、`log_progress="Waiting for input"`、`log_length=7`。**没有一条永久卡死，也没有互相阻塞到超时。**

原始输出：`stability/case3-good/case3.json`。

### 4.3 结论

**通过。** 三个独立 context 的并发请求全部完成并复位；最慢 9.03 s，远低于 300 s 超时。

## 5. 用例 4：中断与恢复

### 5.1 步骤与命令

```sh
cd ~/a0-local-backup/stability
python3 case4.py
```

脚本：

1. 新 context 发「请记住数字 42。只回答：好」，拿到 `T1ED9qKT`。
2. 同一 context 发「写约 2000 字中文散文」；2 秒时用 `curl -sS -m 2` 主动断开。
3. 立刻用 `POST /api/poll` 看 `running`，随后同一 context 发「刚才的写作请求被中断了。现在只回答两个字：恢复」。
4. 再次 poll；读 `usr/chats/T1ED9qKT/chat.json` 核对历史。

### 5.2 原始结果

| 步骤 | 结果 |
|---|---|
| seed 消息 | HTTP 200，41.673 s，回答 `好`（首条含冷启动/记忆初始化） |
| abort 命令 | `curl_exit=28`，`curl_wall_s=2.01`，`HTTP 000`，`0 bytes`，stderr `Operation timed out after 2001 milliseconds with 0 bytes received` |
| abort 前 PID | `1913196` |
| abort 后 PID | `1913196`（未换实例） |
| abort 后立即 poll | `running=true`，`paused=false`，`log_length=11`，`log_progress="Searching memories..."` |
| 后续消息 | HTTP 200，**2.268 s**，回答 `恢复` |
| 后续消息后 poll | `running=false`，`paused=false`，`log_length=17`，`log_progress="Waiting for input"` |

`chat.json` 的日志序列：

```text
9  user      请写一篇大约 2000 字的中文散文，主题是雨后的山谷，...
10 util      （空）
11 user      刚才的写作请求被中断了。现在只回答两个字：恢复
12 agent     （空）
13 agent     thoughts... Reply only with 恢复.
14 response  恢复
```

第 9 条长写作请求只有 `user` + `util`，**没有留下 agent/response**；第 11 条后续消息正常走完。这说明被客户端断开的长请求没有把 context 卡在「正在生成」。

### 5.3 日志

`run-after-c42-022106.log` 在 abort 前后没有 `CancelledError`、`TaskGroup`、`_TaskStub`、`Traceback`、`AttributeError`、`RuntimeError`。只有 1 条与其他消息同类的 litellm `LoggingWorker` `Task was destroyed` 警告（见第 7 节），不影响回答。

### 5.4 结论

**通过。** 主动断开后同一 context 仍能回答，`running` 从 true 回到 false，PID 未变，历史里没有卡住的半成品记录；没有 `CancelledError`/`TaskGroup` 异常。

## 6. 用例 5：资源采样（轻量 30 分钟观察）

### 6.1 命令

```sh
pid=$(pgrep -f 'port=5080' | head -1)
ps -o pid,rss,%mem -p "$pid"
ls -l /proc/$pid/fd | wc -l
ls /proc/$pid/task | wc -l
flatpak ps
ss -ltnp | grep -E '5080|18080|11434'
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5080/api/health
```

### 6.2 两次采样

| 时间 | PID | RSS (KB) | fd (`ls -l`) | fd entries | threads | health |
|---|---|---:|---:|---:|---:|---:|
| 02:22:49 | 1913196 | 430,380 | 56 | 55 | 40 | 200 |
| 02:25:49 | 1913196 | 450,700 | 69 | 68 | 45 | 200 |
| 02:39:53 | 1913196 | 451,340 | 217 | 216 | 45 | 200 |
| 02:40:58 | 1913196 | 451,340 | 60 | 59 | 47 | 200 |
| 02:41:13 | 1913196 | 452,976 | — | 59 | 47 | — |

说明：

- 02:22:49 是 case1 进行中的采样，不是空载基线；02:25:49 是 case1 + 长上下文结束后的首个完整采样。
- 02:39:53 是停止 monitor（02:35:24）后的静置采样（距 02:25:49 约 14 分钟）；02:40:58 是 15 分钟点，但紧接着 02:40:53 的受控聊天，fd 已被回收。PID 仍为 1913196，`flatpak ps` 只有主应用 `1913185`，5080/18080/11434 均在听。
- 02:40:58 的 fd 60 是因为 02:40:53–02:40:59 额外发了一条受控聊天（context `UKvKXJjA`，回答「好」，5.85 s）；这条聊天期间/之后触发了临时 event loop 的回收，fd 从 217 掉到 60。02:41:13 保持 59。
- **RSS：** 450,700 → 451,340 → 452,976 KB；14 分钟内 +0.5% 以内，属于波动，没有单调增长。
- **fd：** 68 entries（02:25:49）→ 216 entries（02:39:53）→ 59 entries（02:40:58 后）。这是锯齿而不是持续泄漏；高水位 219 远低于 `Max open files=524288`。
- **观察窗口：** 本轮独占窗口到 02:50，30 分钟观察未满；实际覆盖 02:25:49–02:41:13（约 15 分钟），已满足「15 分钟后再采一次」的最低要求。
- 02:42:03 做收尾健康检查后 fd 65（eventpoll 15），再次说明单次 `/api/health` 也会暂时增加 loop；仍远低于高水位 219。

### 6.3 静置后的 context 复核

02:35 对五个 context 再做一次 `/api/poll`，全部 `running=false`、`log_progress="Waiting for input"`：

| context | 用途 | log_length | running |
|---|---|---:|---|
| `YR4LPYg7` | 10 条 + 长上下文 | 68 | false |
| `T1ED9qKT` | 中断恢复 | 17 | false |
| `RrDtDJif` | 并发 A | 7 | false |
| `BgkPVKyN` | 并发 B | 7 | false |
| `smYkMANx` | 并发 C | 7 | false |

原始输出：`stability/final-polls.json`。这说明没有「回答已返回但 10 分钟后仍显示 running」的延迟卡死。

### 6.4 fd 与 event loop 观察（重要）

在等待第二次采样时观察到 fd 的锯齿，记录原始数据：

| 时间 | fd entries | socket | eventpoll | 说明 |
|---|---:|---:|---:|---|
| 02:22:49 | 55 | — | — | case1 进行中 |
| 02:25:49 | 68 | — | — | case1+长上下文结束，monitor 已运行约 2 分钟 |
| 02:35:07 | 210 | 129 | 64 | monitor 每 5 s 打 `/api/health`，已约 12 分钟 |
| 02:35:27 | 216 | 133 | 66 | monitor 停止前后 |
| 02:39:53 | 216 | — | 66 | 停 monitor 后 4.5 分钟 |
| 02:40:53 | 219 | — | 67 | 一条 `/api/health` 后；准备受控聊天 |
| 02:40:59 | 59 | 29 | 13 | 受控聊天（`UKvKXJjA`）完成后立即回落 |
| 02:41:13 | 59 | 29 | 13 | 保持稳定 |

按 `/proc/1913196/fd` 的目标分类：高水位时 129 个 `socket:[...]`、64 个 `anon_inode:[eventpoll]`、8 个 pipe、4 个 inotify、4 个普通文件；132 个 Unix socket 全部处于 `03`（connected）。一个 asyncio 事件循环在 Linux 上通常占 1 个 epoll + 2 个 socketpair fd；**高水位的 64 个 eventpoll + 约 129 个 socket 与「约 64 个请求期事件循环」吻合**。

关键转折：**02:40:53–02:40:59 发了一条普通聊天后，fd 从 219 直接回落到 59（eventpoll 67 → 13，socket 133 → 29），并保持稳定**。因此这不是持续泄漏，而是轻量请求（尤其 `/api/health`）期间临时 event loop 未及时回收，下一次聊天/GC 时被清理。02:39:53 的一条 health 请求后 fd 从 216 → 219（+1 eventpoll、+2 socket），也支持「每个健康请求临时留下 1 个 loop」的相关性；22 条 litellm `LoggingWorker` 待销毁任务警告与这些 loop 的延迟回收同向，但未用 tracemalloc 或 loop 计数证明根因。

`Max open files=524288`，高水位 219 远低于上限；RSS 在 450,700–452,976 KB 之间，没有单调增长。**结论：有请求期 fd/event-loop 锯齿，但没有持续泄漏；不把它算成 `_TaskStub` 的回归，也不把它判为本轮失败。** 建议后续在轻量端点后触发一次回收，或降低健康轮询频率，避免高并发监控把 fd 推高。

## 7. 应用日志错误扫描

### 7.1 命令

```sh
grep -nE 'Traceback|TaskGroup|_TaskStub|AttributeError|RuntimeError|never retrieved|Unclosed' ~/a0-local-backup/run-*.log | tail -60
```

完整输出：`stability/log-scan.txt`。当前实例 `run-after-c42-022106.log` 的匹配数为 **0**。

### 7.2 逐条分类

| 类别 | 文件 / 行 | 内容 | 归属 |
|---|---|---|---|
| 修复前 `_TaskStub` | `run-probe-chat-20261117-234927.log:138,299` | `AttributeError: '_TaskStub' object has no attribute '_must_cancel'` | **历史**，修复前实例，20:34 前 |
| 修复前 `TaskGroup` | `run-probe-chat-20261117-234927.log:48` | `AttributeError: 'TaskGroup' object has no attribute '_exceptions'` | **历史**，修复前 |
| 修复前 never retrieved | `run-probe-chat-20261117-234927.log:190` | `Task exception was never retrieved` | **历史**，修复前 |
| 坏模型名（预期） | `run-v10-restored-015250.log:54,88,188,222` | `litellm.exceptions.BadRequestError: ... Unknown model: definitely-not-a-model-xyz` + traceback | **预期**：另一 worker 的坏模型测试，不是 compat |
| 坏模型名（预期） | `run-v8-011457.log:56,90,198,232` | 同上 | **预期**：更早的坏模型测试 |
| 黑洞端点（预期） | `run-probe-chat-20261118-000508.log:69,104,142` | `ConnectionRefusedError: ... ('127.0.0.1', 9)` + `FileNotFoundError: fw.msg_output_limit.md` | **预期**：修复前的黑洞 `api_base` 测试；暴露的是错误呈现链，不是 compat |
| 当前实例关键异常 | `run-after-c42-022106.log` | 无匹配 | **已消除** |
| 当前实例 litellm 警告 | `run-after-c42-022106.log` | 22 条 `Task was destroyed but it is pending!`，coro 均为 `litellm/litellm_core_utils/logging_worker.py:221 LoggingWorker._worker_loop()` | **未修复的旁路警告**，非 `_TaskStub`/`TaskGroup`；不影响回答 |
| 外部重启实例 | `run-c42-021953.log` | 0 条关键异常；2 条 litellm 警告 | **环境事件**，非 compat |
| 当前实例 abort | `run-after-c42-022106.log` | 无 `CancelledError` | **预期**：客户端断开未在应用侧留下取消异常 |

### 7.3 对 22 条 litellm 警告的判断

- 它们出现在每条成功回答附近，约 2–4 条/条消息，说明 litellm 的全局 `LoggingWorker` 任务在嵌套事件循环/请求切换时被 GC 掉了。
- 不是 `_TaskStub` 缺成员，也不是 anyio `TaskGroup` 收尾；当前实例没有任何 `Traceback`。
- 没有造成丢回答、卡 `running` 或 HTTP 失败。第 6 节的 fd 锯齿与这些警告同向，但一条普通聊天后 fd 从 219 回落到 59，未证明持续泄漏；本轮不把它判为 compat 回归。

## 8. 发现的问题（按严重度）

1. **低｜fd / event loop 的请求期锯齿（不是持续泄漏）。**
   高水位 219 fds（eventpoll 66–67，socket 129–133），出现在 monitor 连续健康轮询期间；停 monitor 后仍保持 216，但 02:40:53 一条普通聊天完成后立即回落到 59（eventpoll 13），并稳定在 59。RSS 全程 450.7–453.0 MB，无单调增长。`Max open files=524288`，高水位安全。结论：轻量请求期临时 loop 未及时回收，聊天/GC 会清理；建议后续在轻量端点后触发回收或降低健康轮询频率。该现象与 `_TaskStub` 无关（compat 不创建 loop），也不是本轮失败。
2. **中｜litellm `LoggingWorker` 的 22 条 `Task was destroyed but it is pending!` 仍在。**
   当前实例每条消息附近都会出现；与 `_TaskStub`/`TaskGroup` 无关，未影响功能，但说明仍有待销毁任务在请求边界被 GC。它与 6.4 的 event-loop/fd 增长同向，建议后续单独查 litellm 版本/嵌套循环的 logging worker 生命周期，并观察 RSS/fd。
3. **低｜`chat.json` 的用户日志被截到 15,000 字符。**
   `helpers/log.py:66 CONTENT_MAX_LEN=15_000` 是设计行为；它只影响 UI/持久化副本，不影响 `UserMessage` 传给 LLM 的完整内容（`agent.py:hist_add_user_message` 用 `message.message`）。影响是事后审计无法仅凭 `chat.json` 证明长输入的真实长度，本轮因此额外记录了 80,000 字符、tiktoken 93,893 tokens 与直连端点 46,887 prompt tokens。
4. **低｜`/api/api_message` 不返回 `finish_reason`/`usage`。**
   应用侧无法直接断言 `max_tokens` 截断；本轮用同 prompt 直连 18080 得到 `finish_reason=stop`，并以回答完整三句作为应用侧旁证。若以后要严格验收长上下文，建议在服务端日志打印 `usage`/`finish_reason`。
5. **环境｜02:21:06 外部重启打断第一次 10 条尝试。**
   第 4 条 `RemoteDisconnected`，第 5–10 条 `ConnectionRefused`；PID 1912059 → 1913196，新日志 `run-after-c42-022106.log`。已按「被外部重启打断」记录，不计入失败；正式重跑 clean。
6. **环境｜应用自动拉起 bundled Ollama（约 2.0 GB RSS）。**
   `ollama serve` + `llama-server --mmproj`，不是本轮聊天调用（聊天只走 kw92/18080）。它会影响资源读数，也意味着「不触发本地模型」只能对聊天模型成立；本轮报告把 `run_ui` 与 bundled Ollama 分开记录。
7. **低｜`/api/poll` 需要 session + CSRF。**
   裸 `X-API-Key` 调 `/api/poll` 返回 403 `CSRF token missing or invalid`；必须先 `GET /api/csrf_token`（带 `Origin`）拿 cookie/token。不是缺陷，但做「每条后查 `running`」的脚本需要处理这一步（`probe.py` 已处理）。

## 9. 对照 `test-matrix.md`

### 9.1 C 类（聊天/HTTP）

| CASE | 名称 | 本轮结果 | 说明 |
|---|---|---|---|
| C15 | `/api/api_message` 一次回答 | **通过** | 用例 1 的 10 条全部 200；首条创建 context `YR4LPYg7` |
| C16 | 多轮上下文 | **通过** | 同一 context 连续 10 轮，`log_length` 8→62，历史累积；每轮独立问题均正确 |
| C19 | 空消息 | 未复测 | 本轮未发空消息；不属 `compat` 稳定性范围，先前 `probe-chat.md` 有 400 证据 |
| C20 | 缺 `X-API-Key` | 未复测 | 同上；本轮所有请求均带 16 字符 key |
| C21 | 浏览器等价异步路径 | 未复测 | 本轮只用同步 `POST /api/api_message` |
| C22 | 超长消息不崩 | **通过（等价长输入）** | 80,000 字符、HTTP 200、34.8 s、无崩溃、health 200；但应用 API 无 `finish_reason`，`chat.json` 只存 15,000 字符日志 |

### 9.2 K 类（资源与清理）

| CASE | 名称 | 本轮结果 | 说明 |
|---|---|---|---|
| C58 | 无孤儿进程 | **通过（收尾后复核）** | 收尾杀掉 monitor 后 `pgrep -af 'stability/'` 为空；`flatpak ps` 只剩主应用 `1913185`；02:25 采样时另有一条短命令，02:28 已退出，非本 worker 残留 |
| C59 | 重装不清数据 | 未执行 | 本轮不重装 |
| C60 | 日志可读 | **通过** | `run-after-c42-022106.log` 827 行可读，无权限错误；当前实例健康 |
| C61 | 磁盘未异常增长 | 未建立本轮基线 | `du -sm $DATA` = 1273 MB；本轮没有改动大文件；建议用安装前基线再对照 |

## 10. 最终判定

**核心三项全部通过：**

1. 连续 10 条同 context：10/10 成功，每条 `running=false`，无卡死/排队。
2. 中断恢复：2 s 断开后同一 context 2.27 s 返回，`running` 复位，历史无半成品。
3. 并发 3 条不同 context：全部 200、6–9 s、无互相卡死。

因此，**就 `_TaskStub` 修复的稳定性目标，可判通过**。保留项：litellm `LoggingWorker` 的待销毁任务警告仍在（22 条）、fd 有请求期锯齿（高水位 219，随后回落 59，RSS 稳定）、长上下文的应用侧 `finish_reason`/`usage` 不可直接读取；这三项不影响本轮三项核心判据，但建议后续跟踪。
