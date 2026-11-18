# long-session：v14 实例上的长会话实测（1–79 轮通过，第 80 轮被实例重建打断）

- 窗口：2026-11-18 05:09:27 — 05:46:56（Asia/Shanghai）
- 目的：实测 `compat._TaskStub` 修复后，同一 `context_id` 连续 100 轮对话不退化。
- 说明：本文件记录 **v14 实例**上的证据。v16 上的完整 100 轮见 `long-session-v16.md`。

## 1. 环境与 context_id

| 项 | 值 |
|---|---|
| 入口 | `http://127.0.0.1:5080`，`GET /api/health` 全窗口 200 |
| 进程 | PID 1995463，`venv/bin/python -c import a0flatpak; a0flatpak.apply(); ... run_ui.py --port=5080` |
| 运行日志 | `/home/kunweiz/a0-local-backup/run-v14.log`（启动 04:50；`~/.var/app/.../data/agent-zero/logs/` 不存在） |
| 构建 | health `commit_hash=058582f-dirty`，`commit_time=2026-11-17T20:31:57Z`（打包仓 HEAD 058582f，任务书写作 ab3d8e61） |
| 安装树 compat | `/proc/1995463/root/app/share/agent-zero/flatpak/a0flatpak/compat.py`，md5 `91f5674bfdd2a20802b3bf2c9f5e3ab3`，与 `flatpak/a0flatpak/compat.py` **逐字节相同** |
| 模型 | `kw92 / mistral/deepseek-v4-1-flash-1017`，`ctx_length=1000000`，`max_tokens=384000`，端点 `127.0.0.1:18080/v1` |
| context_id | `probe-long-20261118050927` |
| 请求 | `POST /api/message`，session cookie + `X-CSRF-Token` + `Origin`，body `{"text","context"}`，`curl -m 60` |
| 会话文件 | `~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/chats/probe-long-20261118050927/` |
| 并发干扰 | 同窗口另有 peer probe 请求 15 条（5000 字压力文本 2 条、1200 字散文 1 条、3 条 `ok`、3 条回忆问句，其余为 `What is 11 minus 2?` 类短问），peer chat 数据 13.7 MB 对 我的 1.6 MB |

## 2. A 组：100 轮递增对话（同 context_id）

**在 v14 实例上 1–79 轮全部通过，第 80 轮因实例被 v16 构建取代而中断。**

| 区间 | 成功/轮数 | 耗时区间 | 中位数 |
|---|---|---|---|
| K01–K10 | 10/10 | 5.9–34.8 s | 19.7 |
| K11–K20 | 10/10 | 10.7–38.0 s | 15.0 |
| K21–K30 | 10/10 | 15.8–39.1 s | 24.8 |
| K31–K40 | 10/10 | 23.9–38.6 s | 30.7 |
| K41–K50 | 10/10 | 26.8–36.7 s | 32.4 |
| K51–K60 | 10/10 | 8.3–32.5 s | 30.8 |
| K61–K70 | 10/10 | 30.1–35.8 s | 32.7 |
| K71–K79 | 9/9 | 28.3–33.2 s | 31.6 |
| **合计** | **79/79** | **5.9–39.1 s** | **31.2** |

- 总耗时 2189.5 s；最慢一轮 K21 39.09 s；超 60 s 的轮次 **0**；HTTP 非 200 **0**；`ACK-K` 缺失 **0**。
- **第 80 轮的确切失败方式**：`2026-11-18T05:46:56`，`curl` 退出码 **52（Empty reply from server）**，27.65 s 后连接被对端关闭，无 HTTP 状态码；随后 K81–K100 全部 `curl (7) Failed to connect ... after 0 ms`。同一秒 `run_ui.py` PID 1995463 消失、新 PID 2074861 以日志 `run-v15.log` 启动 → 失败原因是**实例被外部重建**，不是会话退化。
- 递进特征：中位耗时 K01–10 19.7 s → K31 之后稳定在 30–33 s，**没有随轮次单调上升**；K51 为 8.3 s（历史被裁到 70% 后的一次短请求）。

## 3. B 组：上下文压力召回

**v14 未执行**（第 80 轮被实例重建打断，未进入 B 组）。v16 上执行结果见 `long-session-v16.md`。

## 4. C 组：三个 context 的隔离

v14 上首次尝试在 05:10–05:18 进行（`probe-iso-A/B/C-051046`），暴露两个问题，结论不可用：

1. **设计缺陷**：问题“这个会话收到的第 1 条消息是什么”被三个 context 一致回答 `Hello!`——框架在每个新会话先写入一条 greeting 作为第 1 条消息，测试题因此无效。
2. **peer 并发下 60 s 客户端超时 2 次**（A 第 2 轮、B 第 3 轮）。查 `/api/poll`：`log_progress="Waiting for input"`，两条消息在服务端都已完成并写入 `OK` → **客户端超时不等于服务端卡死**。

修正题面后（第 1 条消息写“我的名字是阿尔法/贝塔/伽马”）在 v15 实例上通过：三个 context 各自答出自己的名字与自己的暗号，无一个说出别人的名字。v16 上重新实测，见 `long-session-v16.md`。

## 5. D 组：中断与重建

| 步骤 | 时刻 | 结果 |
|---|---|---|
| 第 50 轮后 `curl --max-time 2` 强断 | 05:31:08 | 退出码 28，2001 ms 收到 0 字节，请求被切断 |
| 同 context 第 51 轮 | 05:31:46 | 200，8.31 s，`ACK-51`；K52/K53 25.6/28.4 s，均为 200 |
| 中断后新 context `probe-recover-*` | 05:31:38 | 200，29.08 s，回答 `RECOVER-OK` |
| 之后 K54–K79 | — | 26/26 全 200 且 `ACK` 正确 |

结论：2 s 强断既没有卡死原 context，也没有影响新 context；服务在中断后继续正常。

## 6. E 组：日志检查

- `run-v14.log` 全文件：`_TaskStub` **0** 条，`AttributeError` **0** 条（v14 窗口内同样为 0）。
- 对照：修复前的 `run-probe-chat-20261117-234927.log` 有 **2** 条 `AttributeError: '_TaskStub' object has no attribute '_must_cancel'`（第 138、299 行）——这就是 D13 的原始签名。
- 存在 `Traceback` 字样，**全部**不属于 D13：
  1. peer 负向测试 `download_work_dir_file` → `Exception: File /etc/shadow not found`、`File .../nope-xyz.txt not found`（预期错误路径）；
  2. litellm `LoggingWorker`：`Task exception was never retrieved` + `RuntimeError: cannot reuse already awaited coroutine`，1 次，出现在请求收尾阶段，回答仍正常返回（见 L3）。

## 7. 资源曲线（每 20 轮 + 心跳）

| 时刻 | K | RSS MB | fd | health | 我的 chat 数据 KB | peer chat 数据 KB |
|---|---|---|---|---|---|---|
| 05:09:27 | 0 | 649 | 255 | 200 / 0.25 s | 1304 | 13676 |
| 05:16:12 | 20 | 820 | 341 | 200 / 0.02 s | 1356 | 13676 |
| 05:25:36 | 40 | 866 | 359 | 200 / 0.04 s | 1432 | 13676 |
| 05:35:xx | 60 | 881 | 383 | 200 / 0.01 s | 1500 | 13676 |
| 05:45:52 | 77 | 882 | 65 | 200 | 1560 | 13676 |

- RSS：649 → 882 MB（**+35.9%**，阈值 30%），但其中 649→820 段与 peer 的 5000 字/500k 字符上下文同时发生；我的全部会话数据仅 1.6 MB，K23→K77 期间 RSS 仅 +55 MB 且 05:37 后基本持平（883→882）。判据数值不达标，归因见 L2。
- fd：255 → 383（请求期锯齿，构成 237 socket + 112 eventpoll），peer 负载结束后回落到 **65**，无单调泄漏。health 全程 200。

## 8. 缺陷

- **L1（外部，非产品缺陷）**：测试窗口内实例被重建两次——05:46:56 v14→v15（打断 A 组第 80 轮）、06:02:33 v15→v16（打断 v16 首轮 A 组第 46 轮）。两次都以 `curl (52) Empty reply` + 随后 `(7) connection refused` 表现，与 D13 的“卡死不返回”不同：**连接是被关闭的，不是挂住的**。
- **L2（判据口径）**：RSS 相对启动值 +35.9%，超 30% 阈值。归因证据：我的会话数据 1.6 MB / peer 13.7 MB；K23→K77 期间 RSS 仅 +55 MB 且后段持平。建议判据改为“稳态斜率”并在静默实例上测。
- **L3（非阻塞）**：litellm `LoggingWorker._worker_loop()` 在 `nest_asyncio` 下被重复 await，产生 `RuntimeError: cannot reuse already awaited coroutine` 1 次；伴随大量既有的 `Task was destroyed but it is pending!`。不影响回答，但会污染日志判据。
- **L4（非阻塞）**：并发高峰时 `GET /api/csrf_token` 偶发 >20 s 无响应（首次拉 token 超时 1 次），随后恢复；事件循环在长请求下仍有秒级饥饿。
- **L5（观测口径）**：客户端 60 s 超时不等于服务端卡死；C 组两次超时的消息在服务端均已完整作答（`/api/poll` 可见 `OK`）。判定卡死必须同时看 `log_progress` 或服务端日志。

## 9. D13 是否确认修复

在 v14 实例上，**79 轮连续同 context 对话（0 失败、0 超 60 s）+ 2 s 强断后原 context 与新 context 都立即恢复 + 日志 0 条 `_TaskStub`/`AttributeError`**，与修复前 `_must_cancel` 报错的签名形成对照，可判 **D13 在 v14 上已被实测支持（79/79）**；100 轮的最终确认因实例被外部重建而顺延到 v16（见 `long-session-v16.md`）。
