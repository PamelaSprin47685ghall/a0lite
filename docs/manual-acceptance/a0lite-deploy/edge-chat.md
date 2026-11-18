# 聊天 / 消息 API 边界与压力测试（edge-chat）

- 实例：`flatpak run --user org.agentzero.AgentZero`，`127.0.0.1:5080`，服务进程 PID `1995463`
- 安装 commit：`ab3d8e61`（flatpak 元数据）；`/api/health` 的 `gitinfo.commit_hash=058582f-dirty`（仓库 HEAD）
  - 二者不是同一层：`ab3d8e61` 是 ostree 制品指纹；`058582f-dirty` 是源码 HEAD + 工作树有未提交改动。同一构建的两个标识，非版本差异。
- 时间：2026-11-18 05:01–05:15；断言时 `/api/health` 均为 200
- 原始输出：`edge-chat-evidence.tar.gz`（324 个文件，含每条 `.meta` / `.hdr` / `.body` / `.req.json` 与服务端采样；两个超长请求体除外），解包后为 `ev/`

## §1 环境与接口自检

两套契约并存；本工单把二者混写了（见 §4 末尾“工单错误”）。`{"message","context_id"}` 属于后者，不属于 `/api/message`：

| 端点 | 鉴权 | 请求体 | 响应 | 自检 |
| --- | --- | --- | --- | --- |
| `POST /api/message` | session cookie + `X-CSRF-Token` | `{"text","context","message_id"}` | `{"message","context"}` | 200，5.72 s |
| `POST /api/message_async` | 同上 | 同上 | `{"message":"Message received.","context"}` | 200，7 ms（ack） |
| `POST /api/poll` | 同上 | `{"context","log_from"}` | SnapshotV1 | 200，12 ms |
| `POST /api/api_message` | `X-API-Key`（`create_auth_token()` 现算） | `{"message","context_id"}` | `{"context_id","response"}` | 200，35.62 s |

- CSRF：`GET /api/csrf_token` 带 `Origin: http://127.0.0.1:5080` → 200，token 43 字符，写 `session_07effc49035c4c60`。裸 GET（无 Origin）→ 200 `{"ok":false,...}`，不是 401/403。
- 本工单形状的实测：`{"message":"1+1=?","context_id":"edge-literal"}` → 200，6.74 s，返回 `"I'm here and ready…"`，`context=AydPBQMe`（忽略请求的 context，落到最近会话）。字段名不匹配时既不 400，也不报错。
- `/api/api_message` 不带 key → 401 `API key required`；假 key → 401 `Invalid API key`；现算正确 key + 不存在的 `context_id` → 404 `Context not found`；不传 `context_id` → 200 `收到`。
- 正面结论：`X-API-Key` 鉴权链完整（无 key 401 → 假 key 401 → 错 context 404 → 正确 key 200），`/api/api_message` 可作为稳定集成入口；只有需要 UI 同源会话时才用 `/api/message` + CSRF。
- `finish_reason` / `usage`：四个端点都不返回。`/api/poll` 的日志条目只有 `kvps.finished=true`。

## §2 12 条结果

并发均用 `xargs -P N` + 独立 context（第 10 条除外）；命令统一为 `POST /api/message`（除第 11 条另注）。

| # | 用例（命令要点） | 状态 | 耗时 | 关键 body 片段 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | 基线 `{"text":"1+1=?","context":"edge-base"}` | 200 | 5.72 s | `{"message":"**1 + 1 = 2**","context":"edge-base"}` | 通过；无 `finish_reason` |
| 2 | 同 context 三轮，第 1 轮记 7391，第 3 轮问回 | 200×3 | 6.92 / 4.01 / 4.91 s | 第 3 轮 `{"message":"7391"}` | 通过 |
| 3 | 并发 10，10 个不同问题、10 个 context | 10/10 200 | 最大 41.24 s，墙钟 41.30 s | 10 条答案均正确（9/52/3/77/51/54/182/8/172/101） | 通过；健康检查 200，fd +18（<50） |
| 4 | 并发 20，同上 | 20/20 200 | 最大 75.41 s，墙钟 75.49 s | 全部带正确 `message` 与 context | 通过；无 502/超时，健康检查 200 |
| 5 | 超长输入：100,000 / 500,000 字符 | 200 / 200 | 54.62 / 39.61 s | 100k 回述到 `第1219段`；500k 回述约 `6,038 段` 并指出尾部截断 | 通过；均非 413，body 可读 |
| 6 | 空消息 5 变体：`{"text":""}`、`{}`、`{"text":null}`、`{"message":""}`、`{"message":null}` | 200×5 | 7.29–10.55 s | 全部 `"I'm ready — what would you like me to do?"`，`context=AydPBQMe` | 部分通过；无 500，但缺 400 校验（E1） |
| 7 | 坏模型 `{"text":"1+1=?","model":"no-such-model-xyz"}` | 200 | 3.38 s | `{"message":"**1 + 1 = 2**"}` | 通过；`model` 字段被静默忽略 |
| 8 | Unicode/格式：中文、emoji、阿拉伯 RTL、代码块、markdown 表格、纯空白 | 200×6 | 6.14 / 39.52 / 32.83 / 23.96 / 33.23 / 31.41 s | `مرحبا`；`😄🎉😊 OK`；`print("Hello, World!")` 代码块；表格 1–3 平方；空白被回问 | 通过（API 侧）；纯空白未报 400 |
| 9 | `--max-time 2` 中断长文，立刻同 context 发短问题 | 000 / 200 | 2.00 / 28.75 s | 恢复响应同时含 `2+2 等于 4。` 与上一篇 3,700 字散文 | 通过；答案合并见 E4 |
| 10 | 同一 context 并发 5 条（不同算术题） | 5/5 200 | 均 13.83 s | 五条全部返回 `{"message":"51"}` | 部分通过；4 条消息被吞，无冲突错误 |
| 11 | Key 路径：`/api/message` 无 key / 假 key；`/api/api_message` 无 key / 假 key / 真 key | 200 / 200 / 401 / 401 / 200 | 3.14 / 3.31 / 0.0024 / 0.019 / 35.62 s | `API key required`；`Invalid API key`；`{"response":"收到"}` | 通过；两套鉴权互不干扰 |
| 12 | CSRF：无 Origin、错 Origin、无 token、坏 token | 200 / 200 / 403 / 403 | 26.01 / 6.66 / 0.0115 / 0.0019 s | 前两条正常答题；后两条 `CSRF token missing or invalid` | 部分通过；Origin 不参与 CSRF 校验（E3） |

## §3 资源采样（服务进程 `1995463`）

| 采样点 | fd | RSS (KB) | 5080 established |
| --- | --- | --- | --- |
| fast 前 / 后 | 108 / 77 | 547,768 / 559,400 | 0 / 1 |
| 并发 10 前 / 后 | 120 / 138 | 595,488 / 623,884 | 2 / 2 |
| 并发 20 前 / 后 | 142 / 208 | 625,180 / 686,488 | 1 / 2 |
| 同 context 并发 5 后 | 213 | 703,108 | 3 |
| 长输入 100k 后 / 500k 后 | 228 / 291 | 738,584 / 767,752 | 3 / 9 |
| 收尾（05:15:06） | 314 | 823,980 | 3 |

- fd 峰值出现在我这一轮之后，但同实例有其他 worker 在跑（日志出现 `/tmp/long/cookies`、`probe-iso-A-*`、`[B] 第 1 轮` 等非本轮 prompt），因此 fd/RSS 含他人负载；并发 20 的 +66 里有 20 个客户端 socket。
- 结束态：5080 仍 200；`flatpak ps` 在我这一轮始终只有 1 个实例（PID 1995448），但复检时可见其他 worker 反复拉起的新实例（存活 30 s 左右、无 5080 监听、`A0_BASE_DIR=/var/data/agent-zero`）；残留 curl 属于并行 worker 的 long-session 长轮询（`/tmp/long/...`，采样时 4 个、复检 2 个），非本轮遗留，保留不动。

## §4 发现的缺陷

- **E1｜未知字段与空输入都返回 200**：`/api/message` 对 `message`/`context_id` 这类未知字段静默忽略；`text` 缺失、`""`、`null` 也直接进模型，返回 200 + 通用寒暄；不带 `context` 时写进最近使用的会话（本轮为 `AydPBQMe`）。根因：`api/message.py:54,77-79` 无字段白名单/空值校验，与 `api/api_message.py:52` 的 400 行为不一致。定级：低（不影响 UI 正常路径）。
- **E2｜同 context 并发丢消息**：5 条并发全部拿回同一答案 `51`，其余 4 条被单槽 `intervention` 覆盖，无 409、无排队提示。根因：`agent.py:269-286` 复用存活 task，`1097-1114` 单槽干预。
- **E3｜CSRF 不校验 Origin**：错误 `Origin: http://evil.example:9999` + 有效 token → 200。根因：`helpers/api.py:190-201` 只比 token；Origin 白名单仅用于 `api/csrf_token.py`。
- **E4｜中断后答案合并**：2 s 断开的长文任务继续运行，下一条短问题的响应把 3,700 字散文一并带回。根因：任务未取消，intervention 触发重跑后合并输出。
- **E5｜上游流中断需重试**：unicode 阶段 llama-server 返回 `TransferEncodingError`/`Connection reset`，litellm 重试后 HTTP 仍 200；服务日志留有 traceback（`run-v14.log:373-460`）。客户端无感，但日志噪声真实存在。

> **工单错误（不计缺陷）**：本工单把两套契约混写。`{"message","context_id"}` 属于 `/api/api_message`（需 `X-API-Key`），而 `/api/message` 的契约是 `{"text","context","message_id"}`。按工单原样调 `/api/message` 得到的 200 假成功，根因是工单字段写错，不是包的缺陷。

## §5 与既有结论的差异

- 既有：10 条连续 153.4 s（中位 8.23 s）、并发 3 条 6.16/7.50/9.03 s、80k 字符 34.8 s。本轮单条基线 5.72 s、3 轮 4.0–6.9 s，量级相近；并发 10/20 墙钟 41.3/75.5 s，是排队而非失败，未出现既有记录之外的 502。
- 既有称 80k 输入不被 15k 截断；本轮把上界推到 500,000 字符仍 200（未触发 413），且模型回述到全文尾部，证实 `CONTENT_MAX_LEN=15_000` 只截 `chat.json` 日志（`log.logs[].content` 最大 15,000），不截模型输入。
- 既有并发只测了“不同 context 的 3 条”，本轮补上“同 context 5 条”，暴露出答案合并与消息丢失（E2），此前的“并发全部复位”结论不覆盖这一路径。
- 既有 C14–C22 走 `/api/api_message` + `X-API-Key`；本轮确认 `/api/message` 是另一套 `text`/`context` + CSRF 契约。本工单把两套契约混写，按 `message/context_id` 调 `/api/message` 会得到 200 的假成功。
- 与既有结论一致：`finish_reason`/`usage` 仍不可读；响应只有 `message`/`context`（或 `context_id`/`response`）。
- 时延不可与既有数值直接比较：本轮同实例被其他 worker 并发驱动（证据见 §3），所有耗时是共享负载下的上界，不是单实例基线。
