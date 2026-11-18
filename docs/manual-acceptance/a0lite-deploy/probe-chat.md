# 聊天链路验收（probe-chat）

执行时间：2026-11-17 23:48 — 2026-11-18 00:20（Asia/Shanghai）
宿主：7940HS / kunweiz / Manjaro / XFCE / X11 `DISPLAY=:0.0`
对象：`org.agentzero.AgentZero`（user 安装，Flatpak），`http://127.0.0.1:5080`

## 1. 环境与前置

- 实例：`flatpak run --user`，进程 `venv/bin/python ... run_ui.py --port=5080 --host=127.0.0.1`；`/api/health` = `HTTP 200`。
- `flatpak ps` 只有本应用一个实例；5080 / 11434 / 18080 均在听。原始输出：`~/a0-shots/evidence/01-instance.txt`。
- override（未 reset）：
  ```ini
  [Environment]
  ALLOWED_ORIGINS=http://127.0.0.1:5080
  ```
- `/api/health` 的 `{"gitinfo": null, "error": ".../data/agent-zero"}` 不是服务故障：`error` 是 `Repo()` 对非 git 目录抛出的 `InvalidGitRepositoryError` 文本；handler 本身 200。依据见 `api/health.py:21-24`、`helpers/git.py:371-389`。
- `ALLOWED_ORIGINS` 生效：带 `Origin: http://127.0.0.1:5080` 的 `GET /api/csrf_token` 返回 `{"ok": true, ...}`；带 `Origin: http://localhost:5080` 被拒并回显白名单 `http://127.0.0.1:5080`。不带 `Origin`/`Referer` 的 curl 会被拒（`Origin None ... Currently allowed origins: `），这是 `csrf_token.py:57-61` 在 origin 为空时提前返回 `allowed_origins=""` 的提示缺陷，不是白名单丢失；浏览器同源请求会带 `Referer`，实际可用。
- 备份：`~/a0-local-backup/probe-chat-20261117-234916/`（`conf/` 全量、`presets.yaml.bak`、`env.bak`）。运行日志：`~/a0-local-backup/run-probe-chat-20261117-234927.log`、`run-probe-chat-20261118-000508.log`。
- 重启次数：**2 次**（23:49 注册 provider 后；00:05 清除卡死运行态）。其余配置改动靠 presets 文件签名热加载，未再重启。
- 未改仓库源码；未改 Flatpak 安装树；`conf/` 与 `usr/plugins/_model_config/presets.yaml` 改动前均备份。

### 1.1 provider 最终配置（`conf/model_providers.yaml`）

**UI 无法新增 provider**：设置页的 Provider 是只读下拉，选项来自 YAML（`helpers/providers.py`），没有“Add provider”入口。实际路径：改 YAML → 重启一次 → UI 下拉出现 `KW92 ZProxy`。

```yaml
chat:
  kw92:
    name: KW92 ZProxy
    litellm_provider: openai
    api_key_mode: none
    models_list:
      endpoint_url: "/v1/models"
      default_base: "http://127.0.0.1:18080"
    kwargs:
      a0_api_mode: chat
      api_base: "http://127.0.0.1:18080/v1"
      api_key: "sk-local"
      max_tokens: 384000
```

`api_key` 直接写在 provider kwargs，避免依赖 `usr/.env`；`api_key_mode: none` 让设置页不强制 key。

### 1.2 预设最终配置（`usr/plugins/_model_config/presets.yaml`）

```yaml
- name: Default
  chat:
    provider: kw92
    name: mistral/deepseek-v4-1-flash-1017
    api_base: http://127.0.0.1:18080/v1
    ctx_length: 1000000
    ctx_history: 0.7
    vision: false
    kwargs:
      max_tokens: 384000
  utility:
    provider: kw92
    name: mistral/deepseek-v4-1-flash-1017
    api_base: http://127.0.0.1:18080/v1
    ctx_length: 1000000
    kwargs:
      max_tokens: 384000
```

预设通过 UI 预设编辑器核对：Provider 显示 `KW92 ZProxy`，Model 显示 `mistral/deepseek-v4-1-flash-1017`，Context window `1000000`（DOM 值）。截图：`~/a0-shots/20-settings-models.png`、`21c-preset-editor-provider.png`。

### 1.3 框架侧解析验证

```text
model_name: openai/mistral/deepseek-v4-1-flash-1017
kwargs: {'max_tokens': 384000, 'api_base': 'http://127.0.0.1:18080/v1', 'a0_api_mode': 'chat', 'api_key': '<sk-local>'}
result_type: tuple
result: ('收到', '')
```

原始输出：`~/a0-shots/evidence/02b-model-call.txt`；`ProviderManager.reload()` 输出见 `02-provider-manager.txt`（`kw92` 在 `chat` 选项里，`litellm_provider=openai`）。斜杠规则正确：最终 `openai/mistral/deepseek-v4-1-flash-1017`。

## 2. 用例

### 2.1 实例状态（步骤 1）

目的：确认无需盲目重启。
操作/命令：`flatpak ps`、`ss -ltnp`、`curl /api/health`、`curl /api/csrf_token`。
原始输出：见 `evidence/01-instance.txt`。关键行：
```text
HTTP/1.1 200 OK
{"gitinfo": null, "error": ".../data/agent-zero"}
```
带 Origin 时：`{"ok": true, "token": "<redacted>", "runtime_id": "f00a826adfd5a144"}`。
期望：health 200，csrf 在浏览器等价条件下可取。
实际：均满足；无 Origin 的裸 curl 被拒是预期分支。
结论：**通过**。

### 2.2 UI 发送（步骤 3，干净实例，新会话）

目的：从真实输入框发送并拿到回答。
操作：Chrome（`/usr/bin/google-chrome`，独立 profile `~/a0-shots/chrome-profile`，CDP 9333）打开首页；CDP `Input.dispatchMouseEvent` 聚焦 `#chat-input`，`Input.insertText` 填入中文；`Input.dispatchKeyEvent` 发送 Enter（xdotool `key Return` 在该 Chrome 上未触发 contenteditable 的 keydown，改用 CDP 键事件；截图与 DOM 均取自真实页面）。
输入：`用一句话回答：你好。`
原始输出：右侧用户气泡出现，状态 `A0: Calling LLM...`；2 秒后回答：
```text
你好！很高兴见到你，有什么我可以帮忙的吗？
```
截图：`~/a0-shots/01-typing.png`、`02-sent.png`、`03-answered.png`。
耗时：**3.28 s**（Enter → 回答 DOM 出现，`t11.txt`）。
期望：非空中文回答，无错误。
实际：满足；`running=false`，`progress=Waiting for input`。
结论：**通过**。

第二次（标题问题）与多轮（步骤 5）在同一实例、新会话：
- `用简体中文回答：这个界面的标题是什么？请只回答一句话。` → **`这个界面的标题是 Agent Zero。`**，3.06 s。
- `我刚才问的是什么？` → **`你刚才问的是：这个界面的标题是什么？（要求用简体中文、只回答一句话）`**，3.07 s；正确引用上一轮。
截图：`04-multiturn-typing.png`、`05-multiturn-answered.png`。
结论：**通过**。

> 注：重启前的首轮曾耗时约 20.4 s，且响应后 `context.running` 卡在 true，第二条消息只能进队列（见问题 2）。重启后 4 轮均正常复位。

### 2.3 HTTP 端到端（步骤 4）

目的：不依赖浏览器验证 `POST /api/api_message`。
token：`create_auth_token()` 现算（16 字符，未落报告）；原始沙盒命令需先 `import a0flatpak; a0flatpak.apply()`，否则 `A0_BASE_DIR` 未被应用、会尝试写只读的 `/app/share/agent-zero/usr/.env` 并抛 `OSError: [Errno 30] Read-only file system`。
请求：
```sh
curl -sS -m 120 http://127.0.0.1:5080/api/api_message \
  -H 'Content-Type: application/json' -H "X-API-Key: $TOKEN" \
  -d '{"message":"只回答两个字：收到"}'
```
原始响应（`evidence/04b-http-api-message.txt`）：
```json
{"context_id": "bMbvxhzZ", "response": "\u6536\u5230"}
```
HTTP=200，38.59 s。
期望：200、response 含「收到」。
实际：满足。
结论：**通过**（首次调用耗时 38.6 s；重启前同一请求 240 s 超时、0 字节，见问题 2）。

### 2.4 多轮上下文（步骤 5）

同一 `context_id` 追加：
```json
{"context_id":"bMbvxhzZ","response":"\u6211\u521a\u624d\u8bf4\u4e86\u4ec0\u4e48\uff1f\u53ea\u56de\u7b54\u6211\u8bf4\u7684\u5185\u5bb9\u3002"}
```
第一次问法（`我刚才说了什么？`）被模型复述成当前问题，**未引用上一轮**；改用更明确的问法后返回 `{"context_id":"bMbvxhzZ","response":"收到"}`（5.08 s）。`usr/chats/bMbvxhzZ/chat.json` 日志含两条 user 与两条 response，历史未丢。
原始输出：`evidence/04c-http-multiturn.txt`、`04d-http-multiturn2.txt`。
结论：**通过（模型首次回答错误，历史保留；第二次正确引用）**。

### 2.5 失败与边界（步骤 6）

#### A. 不存在的模型名

操作：预设 `chat.name` 改为 `nope`（相当于 `kw92/nope`），新建会话发送 `请回答：模型测试。`。
实际 UI（`11-badmodel-error.png`）：
```text
A0: Calling LLM...   END
WRN  Critical error occurred, retrying...
litellm.exceptions.BadRequestError: litellm.BadRequestError: OpenAIException - Unknown model: nope
Traceback (most recent call last): ...
FileNotFoundError: File 'fw.msg_output_limit.md' not found ...
```
随后状态 `Waiting for input`，界面展示折叠的原始 Python traceback。
期望：可读错误提示。
实际：有错误提示（WRN）但主体是 traceback，且被二次 `FileNotFoundError` 污染。
结论：**受限/失败（错误文案不可读）**。

#### B. 输出上限（max_tokens=16）

操作：预设 `chat.kwargs.max_tokens=16`，新会话发送 `请用大约300字介绍杭州的历史与风景。`
实际：服务端日志出现被截断的 JSON：`{"thoughts":["用户要求用大约300字介绍杭州的历史与风景`；UI 停在 `A0: Calling LLM...` 超过 60 s（`13-maxtok-error.png`），无截断提示、无错误提示。
期望：可见截断或限额说明。
实际：无提示、长时间无响应；触发错误处理时又落到 `fw.msg_output_limit.md` 缺失。
结论：**失败**。

#### C. 黑洞 api_base

操作：预设 `chat.api_base` 改为 `http://127.0.0.1:9/v1`，新会话发送 `请回答：测试黑地址。`（未停服务，随后立即改回）。
实际 UI（`16-blackhole-error2.png`）：
```text
WRN  Critical error occurred, retrying...
litellm.exceptions.InternalServerError: ... OpenAIException - Connection error.
ConnectionRefusedError: [Errno 111] Connect call failed ('127.0.0.1', 9)
...
A0: File 'fw.msg_output_limit.md' not found in any of the provided directories.
```
日志证据：`evidence/06b-blackhole-log.txt`。
期望：可读的“端点不可达”。
实际：原始 traceback + 缺失 prompt 的二次错误。
结论：**失败（错误呈现）**。

#### D. 超过 2000 字的输入（UI）

操作：新会话粘贴 2160 个汉字（重复段落），不提交前检查输入框。
实际：输入框完整保留 2160 字，发送按钮可用，**无前端长度限制**；发送成功后用户气泡显示完整内容，约 30 s 后回答：
```text
收到完整输入 ✅
这是一段用于测试输入长度的中文段落，重复多次发送。系统已完整接收并处理了整段内容，没有截断。
...
```
截图：`17-longinput-typed.png`、`18-longinput-sent.png`。
结论：**通过**。

### 2.6 设置页与预设编辑器

- 重启前：设置弹窗只有标题 `Settings ×`，body 为空；Chrome 日志反复出现
  `Alpine Expression Error: Cannot read properties of null (reading 'appendChild')` 与
  `Alpine Warning: Cannot find x-teleport element for selector: "#welcome-channels"`。
  证据：`~/a0-shots/05-settings-after-origins.png`（其他 worker 同一现象）、`~/a0-local-backup/cdp-settings.out`。
- 重启后：同一入口正常加载（bdHTML 399 KB），Models 页显示 `Default / KW92 ZProxy / mistral/deepseek-v4-1-flash-1017`，预设编辑器可打开并显示 Provider/Model/Context window。
  证据：`19-settings-populated.png`、`20-settings-models.png`、`21c-preset-editor-provider.png`。
结论：**间歇性失败，重启后恢复；根因未定**（与卡死运行态同现）。

## 3. 发现的问题（按严重度）

1. **高｜错误处理链依赖不存在的 prompt 文件，任何异常都被二次异常覆盖。**
   `extensions/python/_functions/agent/Agent/hist_add_warning/end/_90_stop_unusable_response_loop.py:27` 调 `read_prompt("fw.msg_output_limit.md")`，运行树里找不到该文件（`/app/share/agent-zero/prompts/fw.msg_output_limit.md` 存在，但解析目录未命中），抛 `FileNotFoundError`。
   证据：坏模型、黑洞端点、max_tokens=16 三条路径都命中；日志 `run-probe-chat-20261117-234927.log:74,164,183` 与 `run-probe-chat-20261118-000508.log:67,164,183`；截图 `11-badmodel-error.png`、`16-blackhole-error2.png`。

2. **高｜流式收尾在 Python 3.14 + anyio 下崩溃，运行态卡死并阻塞后续消息。**
   日志：`AttributeError: 'TaskGroup' object has no attribute '_exceptions'`、`AttributeError: '_TaskStub' object has no attribute '_must_cancel'`、`StopAsyncIteration`（`run-...234927.log:39-48,79-80,136-138`）。
   现象：重启前首轮回答已显示，但 `context.running` 持续 true，第二条消息进入 `Queued Messages (1)`，“Send now”无效；点击 Stop 后才解除，并弹出 `Critical error occurred, retrying...`。截图 `05-queued.png`、`06-queue-stuck.png`、`07-critical-error.png`。
   重启前 `/api/api_message` 240 s 超时 0 字节（`evidence/04-http-api-message-1.txt` 为空）；重启后同请求 38.6 s 成功。

3. **中｜模型/端点错误直接把原始 Python traceback 展示在聊天区。**
   用户看到的是 `litellm...`、`File ".../aiohttp/connector.py"`、`Traceback` 等内部路径，而不是“模型不存在/端点不可达”。截图 `11-badmodel-error.png`、`16-blackhole-error2.png`。

4. **中｜Settings 弹窗间歇性空白。**
   Alpine `x-teleport` 目标 `#welcome-channels` 缺失导致组件树渲染中断；重启后恢复。截图 `05-settings-after-origins.png` 对比 `19-settings-populated.png`；控制台原文 `cdp-settings.out`。

5. **中｜`/api/api_message` 的 context 语义与 test-matrix 命令不符。**
   handler 对不存在的 `context_id` 返回 404 `Context not found`（`api/api_message.py:83-85`）。matrix C15 的 `probe-chat-1`、C16 的 `probe-chat-mem`、C22 的 `probe-long` 都未先创建，按原文执行必然 404。本次 C15 改为省略 `context_id` 创建会话后通过；C22 按原文得到 `HTTP=404 {"error":"Context not found"}`（`evidence/14-c22-long-resp.txt`）。

6. **低｜max_tokens 过小时无“被截断”提示。**
   UI 长时间停在 `Calling LLM...`；只能从服务端日志看到半截 JSON。与问题 1/2 同根因。

7. **低｜聊天会触发 Ollama 嵌入模型。**
   `Searching memories...` 期间 `qwen3-embedding:4b-q4_K_M` 被加载（3.4 GB，`ollama ps` 可见）。本轮约束要求不触发 Ollama 本地模型，属应用自身行为，需在验收环境说明。

8. **低｜`/api/health` 的 `error` 字段易误判。**
   内容只是 data 目录不是 git 仓库；健康检查实际 200。

## 4. 未完成 / 未覆盖项（含原因）

- **未完成：C22 的 HTTP 路径**（已存在 context + 10 万字）——按 matrix 原文 404；原因：命令引用了未创建的 `context_id`，且时间预算不允许多跑一轮 10 万字。等价能力（UI 2160 字）已通过。
- max_tokens=16 未在重启后的干净实例重复（重启前证据完整：截断日志 + 卡死截图）。
- Utility 模型单独失败、Vision 槽位、图片/附件消息、Socket.IO `state_push` 直达、并发两会话、CSRF 仅 Referer 场景。
- 未测“改 provider YAML 不重启”的热加载（`ProviderManager` 有缓存，文档明确需重启）。
- 浏览器控制台只收了 Chrome stderr（`~/a0-shots/chrome-probe-chat.log`）与 CDP 抽样，不是完整 DevTools 会话。

## 5. 用例表（对照 test-matrix C14–C22）

| CASE | 名称 | 结论 | 证据 |
|---|---|---|---|
| C14 | kw92 端点直验 | **通过**：200，`stop`，`1+1 等于 2。`，completion_tokens=9 | `evidence/08-c14-chat.json` |
| C15 | `/api/api_message` 一次回答 | **通过（有前提）**：省略不存在的 context_id 后 200，`收到`，38.6 s | `evidence/04b-http-api-message.txt`；按 matrix 原文则 404 |
| C16 | 多轮上下文 | **通过（模型首次复述错误）**：同 context 保留历史，明确问法返回 `收到` | `04c/04d-http-multiturn*.txt`；`usr/chats/bMbvxhzZ/chat.json` |
| C17 | `max_tokens=384000` 被接受 | **通过**：200，`stop`，completion_tokens=2，`OK` | `evidence/09-c17-maxtok.json` |
| C18 | 错误模型名可读（端点级） | **通过**：404，`{"error":{"message":"Unknown model: no-such-model-xyz"}}` | `evidence/10-c18-badmodel.txt` |
| C19 | 空消息 | **通过**：400 `{"error":"Message is required"}`，随后 health 200 | `evidence/11-c19-empty.txt` |
| C20 | 缺 `X-API-Key` | **通过**：401 `API key required` | `evidence/12-c20-nokey.txt` |
| C21 | 浏览器等价路径 | **通过**：`message_async` 回执 `Message received.`，轮询得到 `收到`，`ASYNC_OK`；首次轮询窗口内未出，补轮询 2 s 后出现 | `evidence/13-c21-async.log`、`asy-poll2.json` |
| C22 | 超长消息不崩 | **受限/失败（按原文）**：404 Context not found；等价能力（UI 2160 字）通过 | `evidence/14-c22-long-resp.txt`、`17/18-longinput*.png` |

UI 主路径不在 C14–C22 的脚本编号内（matrix 的 C 类没有“人工点击发送”用例），本次单独记录于 2.2，截图 `01/02/03`、`04/05`。

## 6. 本轮已知的环境缺陷（会污染聊天验收）

以下三条不是聊天链路本身的设计，但会改变界面表现；本次实测中命中的位置已标注。

1. **设置/项目模态框空白。** 根因：`webui` 一次性 seed 导致版本错配 + Alpine `x-teleport` 崩溃（日志原文 `Cannot find x-teleport element for selector: "#welcome-channels"` / `appendChild of null`）。本次在重启前命中（`05-settings-after-origins.png`），重启后恢复（`19-settings-populated.png`）。**该项空白期间无法通过 UI 配置模型，属于该缺陷导致，不是聊天链路问题。**
2. **宿主 Chrome 在沙盒内的路径是 `/run/host/root/opt/google/chrome/google-chrome`**（旧版未找到，已修）。本轮聊天验收使用宿主 Chrome + CDP，不经过沙盒浏览器，因此未命中；若后续用 Agent 的浏览器工具，要按新路径验证。
3. **`/api/csrf_token` 无 Origin/Referer 时返回 `ok:false`。** 同源浏览器请求带 `Referer`，所以浏览器侧可用；裸 curl 会看到 `Origin None not allowed ... Currently allowed origins: `。这是提示文案的短路分支（`csrf_token.py:57-61`），不是白名单丢失。**本轮所有 CSRF 失败均为裸 curl 未带 Origin，不是聊天链路问题。**

## 7. 现场清理

- Chrome 使用独立 profile `~/a0-shots/chrome-profile`，验收结束关闭该实例；未触碰其他 worker 的 Chrome（`.cache/a0-shots-chrome*`）。
- 临时脚本在 `~/a0-shots/`（`cdp-*.mjs`、`enter.mjs`、`click-at.mjs`）与 `/tmp/S-CHAT-ASYNC.sh`、`/tmp/poll-async2.sh`。
- 配置最终态：provider `kw92` 指向 18080，预设 Default 指向 kw92，`max_tokens=384000`，`api_base` 已从黑洞地址改回。
