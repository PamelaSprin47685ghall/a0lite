# long-session-v16：v16 实例上的长会话实测（65/100 轮通过，第 66 轮被实例重建打断）

- 窗口：2026-11-18 06:05:14 — 06:30:14（Asia/Shanghai）
- 目的：在 v16 构建上实测 `compat._TaskStub` 修复后的长会话，100 轮为完整判据。
- **停止原因**：06:30:14 实例第三次被外部重建（v16 → v18）。按交接边界“又有人重启就停下、报告、不硬跑”，B/C 两组未在本实例执行。

## 1. 环境与 context_id

| 项 | 值 |
|---|---|
| 入口 | `http://127.0.0.1:5080`，`GET /api/health` 全窗口 200 |
| 进程 | PID 2094295（06:04 起），`run_ui.py --port=5080 --host=127.0.0.1`（`a0flatpak.apply()` 前置） |
| 运行日志 | `/home/kunweiz/a0-local-backup/run-v16.log`（`~/.var/app/.../data/agent-zero/logs/` 不存在，flatpak 把 stdout/stderr 重定向到 `~/a0-local-backup/`） |
| 构建 | health `commit_hash=058582f-dirty`，`commit_time=2026-11-17T21:50:08Z`（打包仓 HEAD 058582f；任务书写的 `0eda9fe1` 与实测不符） |
| 安装树 compat | `/proc/2094295/root/app/share/agent-zero/flatpak/a0flatpak/compat.py`，md5 `91f5674bfdd2a20802b3bf2c9f5e3ab3` = 仓库文件 |
| 模型 | `kw92 / mistral/deepseek-v4-1-flash-1017`，`ctx_length=1000000`，`max_tokens=384000`，端点 `127.0.0.1:18080/v1` |
| context_id | `probe-long-v16-20261118060514` |
| 请求 | `POST /api/message`，session + `X-CSRF-Token` + `Origin`，body `{"text","context"}`，`curl -m 60` |
| 会话文件 | `~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/chats/probe-long-v16-20261118060514/`（308 KB） |
| 并发干扰 | 本窗口内其他 worker 已停手（peer chat 数据恒为 13676 KB，无新增），耗时可视为本会话自身 |

## 2. A 组：100 轮递增对话

**1–65 轮全部 200 且 `ACK-K` 正确；第 66 轮因实例被 v18 构建取代而中断。**

| 区间 | 成功/轮数 | 耗时区间 | 中位数 |
|---|---|---|---|
| K01–K10 | 10/10 | 3.5–11.1 s | 5.1 |
| K11–K20 | 10/10 | 8.8–19.1 s | 12.5 |
| K21–K30 | 10/10 | 16.6–27.6 s | 20.0 |
| K31–K40 | 10/10 | 22.2–32.3 s | 27.6 |
| K41–K50 | 10/10 | 31.4–34.7 s | 32.6 |
| K51–K60 | 10/10 | 3.1–36.0 s | 32.2 |
| K61–K65 | 5/5 | 32.0–33.9 s | 33.0 |
| **合计** | **65/65** | **3.1–36.0 s** | **26.4** |

- 总耗时 1458.4 s；最慢一轮 **K56 = 36.04 s**；超 60 s 的轮次 **0**；HTTP 非 200 **0**；`ACK-K` 缺失 **0**。
- **第 66 轮失败方式**：`2026-11-18T06:30:14`，`curl` 退出码 **52（Empty reply from server）**，K67–K100 随即 `curl (7) Failed to connect ... after 0 ms`。同一时刻 PID 2094295 消失，PID 2123135 以 `run-v18.log` 启动（06:29:20 起）→ 失败原因是**实例被重建**，不是会话退化。
- 递进特征：中位耗时随历史增长从 5.1 s 升到 33 s 后**在 K41–K65 完全持平（32–33 s）**，没有继续膨胀；K51 的 3.1 s 是历史被裁到 70% 后的短请求。

## 3. B 组：上下文压力召回

**未执行。** 06:05–06:30 之间实例被重建一次，交接边界要求立即停止，故未占用窗口跑 B。

已有替代证据（v15 实例，单轮预演）：一条 5042 字中文（含数字 94827）`POST /api/message` 返回 200、32.4 s、回答 `OK`。这只证明 5000 字单轮可送，**不构成 20 轮 × 5000 字后的召回结论**。

## 4. C 组：三个 context 的隔离

**v16 未执行**；v15 上已用修正题面通过（见 `long-session.md` §4）：三个 context 分别答出自己的名字（阿尔法/贝塔/伽马）与自己的暗号（`SECRET-A-1`/`B-1`/`C-1`），无一个说出别人的名字或暗号，`foreign=[]`。
要点：题面首条消息必须写入可区分内容——框架会在每个新会话自动写入一条 `Hello!` 作为第 1 条消息，问“第 1 条消息是什么”只会得到 `Hello!`。

## 5. D 组：中断与重建（v16 实测）

| 步骤 | 时刻 | 结果 |
|---|---|---|
| 第 50 轮后 `curl --max-time 2` 强断 | 06:21:51 | 退出码 28，2001 ms 收到 0 字节 |
| 同 context 第 51 轮 | 06:22:26 | **200，3.06 s，`ACK-51`** |
| 中断后新 context `probe-recover-062223` | 06:22:23 | **200，32.07 s，`RECOVER-OK`** |
| 之后 K52–K65 | — | 14/14 全 200、`ACK` 正确（32.15 s 附近稳定） |

结论：2 s 强断没有卡死原 context，也没有影响新 context；`asyncio` 的取消路径在长会话中部仍可用。

## 6. E 组：日志检查

- `run-v16.log`（730 行）中 **`_TaskStub` 0 条**；与 `_TaskStub` 相关的 `AttributeError` **0 条**。
- 但**不是“完全干净”**，有 3 条 `AttributeError`，全部来自 WPS MCP 客户端启动阶段：
  `MCPClientBase (wps_office): 'update_tools' operation failed: AttributeError: '_TeeLog' object has no attribute 'fileno'`（第 8、10、12 行）。这与长会话无关，但会让“`AttributeError` 必须为空”的字面判据失败。
- `Traceback` 2 条，均为 litellm `LoggingWorker`：`RuntimeError: cannot reuse already awaited coroutine`（第 83–96 行），1 次事件 2 段栈。
- 对照：修复前 `run-probe-chat-20261117-234927.log` 有 2 条 `AttributeError: '_TaskStub' object has no attribute '_must_cancel'`。

## 7. 资源曲线

| 时刻 | K | RSS MB | fd | threads | health |
|---|---|---|---|---|---|
| 06:05:17 | 0 | 390 | 86 | 33 | 200 |
| 06:10:51 | 20 | 490 | 111 | 57 | 200 |
| 06:16:22 | 40 | 493 | 53 | 51 | 200 |
| 06:22:xx | 60 | 500 | 79 | — | 200 |
| 06:29:55 | 64 | 500 | 73 | 55 | 200 |

- RSS：390 → 500 MB（**+28.2%**，阈值 30%，**未超**）。曲线形状：前 20 轮 +100 MB（解释器预热 + 单个会话上下文 + 模型客户端），K20→K64 仅 +10 MB（0.23 MB/轮），**未见持续泄漏**。
- fd：86 → 111 → 53 → 79，锯齿而非单调；构成以 socket/eventpoll 为主，请求结束即回落。health 全程 200。

## 8. 缺陷

- **L1（外部，非产品缺陷，重复 3 次）**：实例被其他 worker 反复重建——05:46:56 v14→v15、06:00 v15→v16、06:30:14 v16→v18。三次都以 `curl (52) Empty reply` + 随后 `(7) connection refused` 表现，进程 PID 与日志文件同时改变。这是**连接被关闭**，与 D13 的“请求挂住不返回”形态相反。**这是三轮长会话测试共同的唯一失败原因。**
- **L2（v14 判据口径）**：v14 测得 RSS 649 → 882 MB（+35.9%，超 30%），但同窗口有 peer 5000 字/500k 字符级请求，我的会话数据仅 1.6 MB；v16 静默窗口测得 +28.2%，形状显示为预热而非泄漏。建议判据改为“K20 之后每轮斜率”并在静默实例上测。
- **L3（非阻塞，启动期）**：`_TeeLog` 缺 `fileno`，WPS MCP 的 `list_tools`/`update_tools` 在启动时失败 3 条；不影响聊天与长会话。
- **L4（非阻塞）**：litellm `LoggingWorker._worker_loop()` 在 `nest_asyncio` 下被重复 await，`RuntimeError: cannot reuse already awaited coroutine` 出现 1 次（v14、v16 各 1 次），伴随大量 `Task was destroyed but it is pending!`。回答不受影响，但污染日志判据。
- **L5（观测口径）**：客户端 60 s 超时不等于服务端卡死。v14 C 组两次 60 s 超时的消息经 `/api/poll` 证实服务端已完整作答。判定卡死必须同时看 `log_progress` 或服务端日志。
- **L6（测试设计）**：新会话的第 1 条消息由框架写入 `Hello!`，任何“复述第 1 条消息”的题面都会误判为串味。

## 9. D13 是否确认修复

在 v16 实例上，**65 轮连续同 context 对话（0 失败、0 超 60 s、中位耗时在 K41 后持平）+ 第 50 轮 2 s 强断后原 context 3.06 s 恢复、新 context 32.07 s 返回 `RECOVER-OK` + 日志 0 条 `_TaskStub`**，可判 **D13 的修复在 v16 上得到实测支持（65/65）**。但 100 轮判据三次被外部重建打断（v14 79/100、v15 45/100、v16 65/100），**“100/100”这一条至今没有一次完整跑到终点**；在无重建的静默窗口补跑一次即闭环。
