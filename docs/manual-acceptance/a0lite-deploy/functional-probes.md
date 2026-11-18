# Agent Zero 功能探针清单（可复制执行）

对象：Flatpak 打包的 Agent Zero（`org.agentzero.AgentZero`，branch `master`，user 安装）。
上游代码：`/home/kunweiz/Desktop/agent-zero` @ `ba9b67d`。
打包层：`/home/kunweiz/Desktop/a0lite/flatpak/a0flatpak/*.py`。

本文只给探针，不改代码、不部署、不构建。作者已在目标机上实测过标注「已实测」的条目（2026-11-17）。

---

## 0. 角色 → 端点 → 模型

| 角色 | 端点 | 模型 / 资源 | 由谁调用 |
|---|---|---|---|
| 聊天、推理、工具调用 | `http://127.0.0.1:18080/v1`（OpenAI Chat Completions 兼容，无鉴权） | `mistral/deepseek-v4-1-flash-1017`（kw92 ZProxy） | Agent Zero 的 `chat_model` 槽位 |
| 语音合成（TTS） | `http://127.0.0.1:11434/v1/audio/speech` | `lfm3-omni:2b-q4_K_M` | `a0flatpak/speech.py` 打补丁后的 `_kokoro_tts` runtime |
| 语音识别（STT） | `http://127.0.0.1:11434/v1/audio/transcriptions` | `lfm3-omni:2b-q4_K_M` | `a0flatpak/speech.py` 打补丁后的 `_whisper_stt` runtime |
| OCR / 图片与扫描件 | `http://127.0.0.1:11434/api/chat`（多模态 images） | `xiaomi-ocr`（默认，可由 `A0_OCR_MODEL` 覆盖） | `a0flatpak/ocr.py`、`a0flatpak/parsers.py` |
| 嵌入 / 向量 | `http://127.0.0.1:11434/api/embed` | `qwen3-embedding:4b-q4_K_M`（预期 2560 维） | `a0flatpak/embeddings.py` 替换后的 `models.get_embedding_model` |
| 浏览器 | 宿主 Chrome（CDP，由 `nodriver` 驱动） | `/opt/google/chrome/google-chrome` | `a0flatpak/browser.py` → `stealth_browser` → `plugins/_browser` |
| 桌面 | Xpra HTML5（`127.0.0.1:14500+`） | `/app/bin/xpra` + 宿主 `:0` 或内置 Xvfb | `a0flatpak/desktop.py` → `plugins/_desktop` |
| WPS Office | stdio JSON-RPC | `org.agentzero.AgentZero.Wps` 里的 Bun + `wps-office-mcp` | MCP 客户端（`mcpServers` 配置） |

**不能混用的边界**：kw92 的 zproxy 只承载聊天；TTS/STT/OCR/嵌入都必须走 Ollama `127.0.0.1:11434`。`a0flatpak` 里没有任何一处把语音或嵌入指向 18080。

---

## 1. 通用运行形态与包装

### 1.1 身份与变量

```sh
# 从任意机器 ssh 进目标机，再降权到 kunweiz（若 ssh 用户已是 kunweiz，可省 sudo）
ssh <user>@<target> 'sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/kunweiz bash -s' <<'OUTER'
set -eu
echo "whoami=$(whoami) home=$HOME runtime=$XDG_RUNTIME_DIR"
flatpak info --user org.agentzero.AgentZero | sed -n '1,8p'
OUTER
```

已实测：`id -u kunweiz` = 1000，`/run/user/1000` 存在，`flatpak info --user` 可读。

### 1.2 沙盒入口（`--command` 已被证实可用）

manifest 里 `command: agent-zero`，`flatpak run --command=` 会覆盖它：

```sh
# 已实测：返回 shell，HOME 与宿主一致，PWD 继承调用目录
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
echo "HOME=$HOME PWD=$PWD"
ls -d /app/share/agent-zero /app/share/python-deps /app/bin/uv
INNER
```

### 1.3 沙盒内跑框架 Python 的固定前置（复制这一段到每个探针）

```sh
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero || exit 1
export GIT_PYTHON_REFRESH=quiet          # 沙盒无 git，不设则 GitPython 抛 ImportError
export A0_BASE_DIR="$B"                  # 让 usr/、conf/、plugins/ 解析到可写树
export PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
PY="$B/venv/bin/python"
```

`GIT_PYTHON_REFRESH=quiet` 不是可选：实测漏掉会直接 `ImportError: Bad git executable`（`helpers/git.py` → `git` 包在导入时刷新）。

### 1.4 只读 vs 写状态的分界

| 探针 | 是否写状态 |
|---|---|
| `/api/health`、`GET /api/csrf_token`、`POST /api/poll`、`POST /api/history_get` | 只读 |
| `POST /api/message`、`POST /api/message_async`、`POST /api/api_message` | **写**：新建/推进 chat，落盘日志与会话 |
| `models.get_embedding_model(...).embed_query(...)` | 只读（只在 Ollama 侧加载模型） |
| `Memory.insert_text(...)` | **写**：`usr/memory/<subdir>/` 下索引文件 |
| `synthesize_sentences` / `transcribe` | 只读（不落盘；除非你把 WAV 写文件） |
| `ImageParser` / `PdfParser.parse()` | 只读（临时文件由解析器自建自删） |
| 浏览器 `open(data:text/html,...)` | 只读页面，但会起 Chrome 进程；若配置了持久 profile 会写 profile 目录 |
| `ensure_system_desktop()` | **写**：`usr/plugins/_desktop/sessions/*.json`、启动 xpra 进程 |
| WPS MCP `initialize` / `tools/list` | 只读（握手与列工具，不触发文档操作） |

---

## 2. 聊天

### 2.1 传输形式的结论

- 浏览器发消息**不走 WebSocket**：`webui/index.js:152,163` → `POST /api/message_async`。
- WebSocket（Socket.IO，命名空间 `/ws`）只做状态同步：`api/ws_webui.py` → 扩展点 `webui_ws_event`，唯一实现只认 `state_request`（`extensions/python/webui_ws_event/_10_state_sync.py:24`）。
- 因此「一次 HTTP 请求拿到模型回答」要走 `POST /api/api_message`（同步，需 `X-API-KEY`）或 `POST /api/message`（同步，需 session + CSRF）。
- `POST /api/message_async` 只回执 `{"message":"Message received.","context":"..."}`，回答要靠 Socket.IO 的 `state_push` 或轮询 `/api/poll`。

### 2.2 端点表

| 方法 | 路径 | 鉴权 | 请求体 | 响应 |
|---|---|---|---|---|
| POST | `/api/api_message` | 仅 `X-API-KEY`（`requires_auth=False`、`requires_csrf=False`） | `{"message":"...","context_id":"可选","attachments":[{"filename","base64"}]}` | `{"context_id":"...","response":"<最终回答>"}` |
| POST | `/api/message` | session + CSRF | JSON `{"text","context","message_id"}` 或 multipart 同名字段 + `attachments` 文件 | `{"message":"<最终回答>","context":"..."}` |
| POST | `/api/message_async` | session + CSRF | 同上 | `{"message":"Message received.","context":"..."}` |
| POST | `/api/poll` | session + CSRF | `{"context","log_from","notifications_from","timezone"}` | `SnapshotV1`（`logs[]`、`log_progress`…） |
| POST | `/api/history_get` | session + CSRF | `{"context":"..."}` | `{"history":"...","tokens":N}` |

### 2.3 目的

在不起浏览器的情况下，让沙盒内的 Agent Zero 完整跑一轮「用户消息 → 模型 → 回答」。

### 2.4 前置条件

- 服务已启动：`flatpak run --user org.agentzero.AgentZero`，`/api/health` 返回 200。
- 已按第 3 节把 kw92 注册为 provider，并把 `chat` 槽位指向它。
- 知道 `mcp_server_token`（`X-API-KEY` 的值）。它由 `helpers/settings.py:851 create_auth_token()` 现算，不落盘，**不要在报告或日志里回显**。

### 2.5 命令 A：现算 API key（只读）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" -c 'from helpers.settings import create_auth_token; print(create_auth_token())' > /tmp/a0_token
echo "token written: $(wc -c < /tmp/a0_token) bytes"
INNER
# token 文件在沙盒私有 /tmp，改为写到宿主可见的目录：
```
已实测：`create_auth_token()` 输出 16 字符；与手工 `base64url(sha256("<persistent_id>:<AUTH_LOGIN>:<AUTH_PASSWORD>"))[:16]` 完全一致。要跨边界取用，把输出重定向到 `$HOME`：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" -c 'from helpers.settings import create_auth_token; print(create_auth_token())' > "$HOME/.a0-probe-token"
INNER
TOKEN=$(cat "$HOME/.a0-probe-token")
test ${#TOKEN} -ge 8 && echo "token ok (${#TOKEN} chars)" || echo "TOKEN MISSING"
```

### 2.6 命令 B：一条 HTTP 拿到回答（**会写状态**）

```sh
: "${A0_AUTH_KEY:=}"          # 若启用了 A0_AUTH_KEY，先 export 它
TOKEN=$(cat "$HOME/.a0-probe-token")

# A0_AUTH_KEY 与 mcp_server_token 是两个不同的值：
#   Authorization: Bearer 过 ASGI 门（a0flatpak/auth.py）
#   X-API-Key            过 handler 门（helpers/api.py requires_api_key）
curl -sS -m 180 -w '\nHTTP=%{http_code}\n' \
  http://127.0.0.1:5080/api/api_message \
  -H 'Content-Type: application/json' \
  ${A0_AUTH_KEY:+-H "Authorization: Bearer $A0_AUTH_KEY"} \
  -H "X-API-Key: $TOKEN" \
  -d '{"message":"只回答两个字：收到","context_id":"probe-chat-1"}'
```

期望输出（关键断言）：

```
{"context_id":"probe-chat-1","response":"收到"}
HTTP=200
```

- `response` 非空，且不是 `"Model not configured."`（后者说明 chat 槽位没配好）。
- `context_id` 与你传入的一致，说明会话被复用而非新建。

### 2.7 命令 C：复刻浏览器路径（**会写状态**，只拿回执）

```sh
: "${A0_AUTH_KEY:=}"
# 1) 拿 session + CSRF
curl -sS -c "$HOME/.a0-cookies" \
  ${A0_AUTH_KEY:+-H "Authorization: Bearer $A0_AUTH_KEY"} \
  http://127.0.0.1:5080/api/csrf_token | tee "$HOME/.a0-csrf.json"
CSRF=$(python3 -c 'import json,sys; print(json.load(open(s.argv[1]))["token"])' "$HOME/.a0-csrf.json")
RID=$(python3 -c 'import json,sys; print(json.load(open(s.argv[1]))["runtime_id"])' "$HOME/.a0-csrf.json")

# 2) 发消息（只回执）
curl -sS -b "$HOME/.a0-cookies" -c "$HOME/.a0-cookies" -m 60 \
  ${A0_AUTH_KEY:+-H "Authorization: Bearer $A0_AUTH_KEY"} \
  -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
  -H "Origin: http://127.0.0.1:5080" \
  -d '{"text":"只回答两个字：收到","context":"probe-chat-2"}' \
  http://127.0.0.1:5080/api/message_async

# 3) 轮询到出现 type=="response" 的日志条目
for i in $(seq 1 60); do
  curl -sS -b "$HOME/.a0-cookies" -m 30 \
    ${A0_AUTH_KEY:+-H "Authorization: Bearer $A0_AUTH_KEY"} \
    -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
    -H "Origin: http://127.0.0.1:5080" \
    -d '{"context":"probe-chat-2","log_from":0,"notifications_from":0}' \
    http://127.0.0.1:5080/api/poll > "$HOME/.a0-poll.json"
  if python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(any(l.get("type")=="response" and (l.get("content") or "").strip() for l in d.get("logs",[])))' "$HOME/.a0-poll.json" | grep -q True; then
    python3 -c 'import json,sys;[print(repr(l["content"][:200])) for l in json.load(open(sys.argv[1]))["logs"] if l.get("type")=="response"]' "$HOME/.a0-poll.json"
    break
  fi
  sleep 2
done
```

断言：至少打印一条非空字符串，内容应包含「收到」。

### 2.8 失败时最可能的三个原因

1. `HTTP=401` / `unauthorized`：设了 `A0_AUTH_KEY` 但请求没带 `Authorization: Bearer`（`a0flatpak/auth.py` 对除 `/api/health`、`/js/manifest.json` 外的所有路径生效）。
2. `HTTP=403 CSRF token missing or invalid`：漏了 `X-CSRF-Token`，或 cookie 文件没带（`session` 与 `csrf_token_<runtime_id>` 必须成对）。
3. `{"message":"Model not configured."}`：`chat` 槽位没指向可用 provider（见第 3 节），或 Ollama/kw92 端点不可达。

---

## 3. 聊天模型：kw92 Mistral DeepSeek v4.1 Flash

### 3.1 目的

让 Agent Zero 的主模型走 `http://127.0.0.1:18080/v1`，模型 `mistral/deepseek-v4-1-flash-1017`；不写任何密钥（该端点 `auth: none`）。

### 3.2 前置条件

- `zproxy` 在听 `127.0.0.1:18080`（`ss -ltnp | grep 18080`）。
- Flatpak 有 `--share=network`，沙盒内同样可达 `127.0.0.1:18080`（已实测：沙盒内 `curl` 到 18080 成功）。
- 不需要任何 key；若某个客户端强制要 key，填任意非空字符串即可（下文用占位符 `no-auth-placeholder`）。

### 3.3 端点直验（宿主，只读）—— **已实测**

```sh
# 注意：该 zproxy 不支持 GET /v1/models，会返回文本 "Use a POST completion endpoint."
# 所以模型清单只作参考，不要把它当健康检查的硬断言。
curl -sS -m 10 -w '\nHTTP=%{http_code}\n' http://127.0.0.1:18080/v1/models

# 真正的连通性断言：一次最小 chat
curl -sS -m 60 -w '\nHTTP=%{http_code}\n' \
  http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mistral/deepseek-v4-1-flash-1017",
       "messages":[{"role":"user","content":"用一句简体中文回答：1+1 等于几？"}],
       "max_tokens":64}'
```

实测输出：

```
{"id":"chatcmpl-...","object":"chat.completion","model":"mistral/deepseek-v4-1-flash-1017",
 "choices":[{"index":0,"message":{"role":"assistant","content":"1+1 等于 2。","refusal":null},
 "finish_reason":"stop",...}],"usage":{"prompt_tokens":17,"completion_tokens":9,...}}
HTTP=200
```

断言：`HTTP=200`、`choices[0].message.content` 非空、内容含「2」、`finish_reason=="stop"`。

中文与 64 token 不截断：

```sh
curl -sS -m 60 http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mistral/deepseek-v4-1-flash-1017",
       "messages":[{"role":"user","content":"用不超过 15 个汉字说：你好。"}],
       "max_tokens":64}' \
| python3 -c '
import json,sys
d=json.load(sys.stdin); c=d["choices"][0]
t=c["message"]["content"]
print("finish:",c["finish_reason"],"chars:",len(t),"cjk:",sum(1 for ch in t if "\u4e00"<=ch<="\u9fff"))
print("content:",t)
assert c["finish_reason"]=="stop", "被截断"
assert sum(1 for ch in t if "\u4e00"<=ch<="\u9fff")>=5, "中文输出异常"
print("ASSERT OK")
'
```

实测：`finish: stop chars: 10 cjk: 8 content: 你好，很高兴认识你。ASSERT OK`。

### 3.4 斜杠规则的确定答案（最容易踩的坑）

`models.py` 的 `LiteLLMChatWrapper.__init__` 把模型名拼成 **`f"{provider}/{model}"`**（`models.py:395`），于是最终交给 LiteLLM 的是：

```
openai/mistral/deepseek-v4-1-flash-1017
```

LiteLLM 1.104.0 的 `get_llm_provider` **只按第一个 `/` 切分**。已在沙盒 venv 实测：

| 输入 | 解析结果 |
|---|---|
| `openai/mistral/deepseek-v4-1-flash-1017` | model=`mistral/deepseek-v4-1-flash-1017`, provider=`openai` ✅ |
| `mistral/deepseek-v4-1-flash-1017`（裸写） | model=`deepseek-v4-1-flash-1017`, provider=`mistral`, api_base 默认 `https://api.mistral.ai/v1` ❌ |

结论：**模型名里的斜杠安全，前提是 provider 条目的 `litellm_provider` 是 `openai`**。框架会自动补 `openai/` 前缀，因此 `name` 字段要写完整的 `mistral/deepseek-v4-1-flash-1017`，**不要**自己再写 `openai/...`，否则会变成 `openai/openai/...` 而被发给 zproxy。

复现该断言（只读）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import importlib.metadata as md, models
from litellm.litellm_core_utils.get_llm_provider_logic import get_llm_provider
print("litellm:", md.version("litellm"))
mc = models.ModelConfig(type=models.ModelType.CHAT, provider="kw92",
                        name="mistral/deepseek-v4-1-flash-1017",
                        api_base="http://127.0.0.1:18080/v1", ctx_length=1000000)
w = models.get_chat_model("kw92", mc.name, model_config=mc, **mc.build_kwargs())
print("wrapper.model_name:", w.model_name)
print("parsed:", get_llm_provider(model=w.model_name))
PY
INNER
```

实测：`wrapper.model_name: openai/mistral/deepseek-v4-1-flash-1017`，`parsed: ('mistral/deepseek-v4-1-flash-1017', 'openai', None, None)`。

### 3.5 在框架里注册 provider（**会写配置**）

可写树是 `$B/conf/model_providers.yaml`，launcher 只在目录**不存在**时 seed（`flatpak/agent-zero.sh` 的 `[ ! -d "$BASE_DIR/$name" ]` 分支），所以这里的修改不会被启动覆盖。已实测该文件存在（334 行），且 `a0flatpak/base_dir.apply()` 把 `files.get_abs_path("conf/...")` 指向它。

在 `chat:` 段下追加一个条目（缩进与 `ollama:` 同级）：

```sh
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cp -a "$B/conf/model_providers.yaml" "$B/conf/model_providers.yaml.bak"
python3 - "$B/conf/model_providers.yaml" <<'PY'
import sys, yaml
path = sys.argv[1]
data = yaml.safe_load(open(path))
data.setdefault("chat", {})["kw92"] = {
    "name": "KW92 ZProxy",
    "litellm_provider": "openai",       # 关键：决定 litellm 前缀是 openai/
    "api_key_mode": "none",             # 让 UI 不强制要 key（provider_requires_api_key 读这里）
    "models_list": {"endpoint_url": "/v1/models",
                    "default_base": "http://127.0.0.1:18080"},
    "kwargs": {"a0_api_mode": "chat",
               "api_base": "http://127.0.0.1:18080/v1"},
}
yaml.safe_dump(data, open(path, "w"), sort_keys=False, allow_unicode=True)
print("kw92 added; chat providers:", len(data["chat"]))
PY
```

字段含义（以 `helpers/providers.py:37 _load_providers` 为准，任意键都会保留）：

| 键 | 作用 |
|---|---|
| `name` | 设置页下拉里显示的名字 |
| `litellm_provider` | 传给 LiteLLM 的 provider 前缀（`openai` 表示 OpenAI 兼容端点） |
| `api_key_mode: none` | `plugins/_model_config/helpers/model_config.py:85 provider_requires_api_key()` 读它，`none/optional/oauth` 都视为不强制 |
| `models_list.endpoint_url` + `default_base` | 模型列表拉取地址；该 zproxy 不支持 GET，会失败，但不影响聊天 |
| `kwargs.api_base` | 实际请求基址，必须带 `/v1` |

注意：`a0flatpak/provider_urls.py` 只改写 `ollama` 与 `lm_studio` 两个 id 的 `api_base`，`kw92` 不会被它碰到。

### 3.6 选到该模型（UI 路径）

1. 打开 `http://127.0.0.1:5080/`。
2. 右上角设置 → **Agent** → 左侧 **Models**（`webui/components/settings/agent/agent-settings.html` 的 `#section-models-summary`，内容是 `plugins/_model_config/webui/models-summary.html`）。
3. 这里选的是**预设（preset）**；点开预设编辑器（`/plugins/_model_config/webui/main.html`），在 **Main Model** 区块把 Provider 选 `KW92 ZProxy`，Model 填 `mistral/deepseek-v4-1-flash-1017`。
4. **Utility Model** 也要指一个可用模型，否则工具调用与摘要会报「utility model not configured」。
5. 保存后当前 chat 立即生效（预设切换走 `_model_config` 的运行时快照），不需要重启应用。**只有**改了 `conf/model_providers.yaml` 才需要重启，因为 `ProviderManager` 把 YAML 缓存在 `model_providers(plugins)` 缓存区。

重启（**会把现有会话的运行时状态清掉**）：

```sh
flatpak kill org.agentzero.AgentZero 2>/dev/null || true
nohup flatpak run --user org.agentzero.AgentZero >"$HOME/.a0-app.log" 2>&1 &
for i in $(seq 1 120); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:5080/api/health)" = 200 ] && break
  sleep 1
done
curl -s -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
```

### 3.7 上下文窗口与输出上限

`ModelConfig` 的字段（`models.py:143`）：`ctx_length`、`limit_requests`、`limit_input`、`limit_output`、`kwargs`。预设里的写法（`plugins/_model_config/mode_presets_fallback.yaml` 是权威示例）：

```yaml
chat:
  provider: kw92
  name: mistral/deepseek-v4-1-flash-1017
  api_base: "http://127.0.0.1:18080/v1"
  ctx_length: 1000000        # 上下文窗口；框架按它裁剪历史（helpers/history.py:236）
  ctx_history: 0.7           # 历史可用比例
  kwargs:
    max_tokens: 384000       # 输出上限，随请求发给服务端
```

两个键的分工要分清：

- `ctx_length` 是**框架自己的预算**，用来决定截断多少历史（`helpers/history.py:236-239`、`649-651`）。它不会发给服务端。
- `kwargs.max_tokens` 是**真正发给服务端的 `max_tokens`**（`helpers/litellm_transport.py:390-419` 原样放进请求）。
- `vision` 槽位才有独立的 `max_tokens` 字段（`model_config.py:32,925`，默认 2000）；主模型不要指望那个字段。

服务端是否接受 384000 —— **已实测接受**：

```sh
curl -sS -m 60 -w '\nHTTP=%{http_code}\n' \
  http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mistral/deepseek-v4-1-flash-1017",
       "messages":[{"role":"user","content":"只回答 OK"}],
       "max_tokens":384000}'
```

实测返回 `HTTP=200`、`content:"OK"`、`finish_reason:"stop"`、`usage.completion_tokens:2`。不要用它去真的生成 38 万 token。

### 3.8 失败时最可能的三个原因

1. 模型名写成 `openai/mistral/...`，最终请求变成 `openai/openai/mistral/...`，服务端 404/400。`name` 只写 `mistral/deepseek-v4-1-flash-1017`。
2. `litellm_provider` 写成 `mistral`：LiteLLM 会把请求发去 `https://api.mistral.ai/v1` 并要 key，本机 zproxy 完全不参与。
3. 改完 `conf/model_providers.yaml` 没重启：`ProviderManager` 的 YAML 有缓存，设置页里看不到 `KW92 ZProxy`。

---

## 4. 嵌入与记忆

### 4.1 目的

用框架自己的 `models.get_embedding_model` 算一次嵌入，断言维度 2560；再触发一次记忆写入与检索。

### 4.2 前置条件

- Ollama 在 `127.0.0.1:11434` 运行，且 `qwen3-embedding:4b-q4_K_M` 已加载（models 扩展的 manifest 路径已确认存在：`models/models/manifests/registry.ollama.ai/library/qwen3-embedding/4b-q4_K_M`）。
- 维度 2560 来自模型本身（Qwen3-Embedding-4B），**不是**框架常量；框架在 `plugins/_memory/helpers/memory.py:214` 用 `len(embedder.embed_query("example"))` 动态建索引。

### 4.3 命令 A：嵌入维度（只读）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
from a0flatpak import embeddings
embeddings.apply()
import models
m = models.get_embedding_model("huggingface", "sentence-transformers/all-mpnet-base-v2")
print("class:", type(m).__name__, "model:", m.model_name)
v = m.embed_query("a0 probe")
print("dimensions:", len(v), "type:", type(v).__name__, "first3:", v[:3])
assert len(v) == 2560, f"expected 2560, got {len(v)}"
print("ASSERT dimensions == 2560 OK")
PY
INNER
```

关键断言：

- `type(m).__name__ == "OllamaEmbeddings"`（`a0flatpak/embeddings.py` 的包装类）。
- `m.model_name == "qwen3-embedding:4b-q4_K_M"`（传入的 `sentence-transformers/...` 被替换为默认嵌入模型）。
- `len(v) == 2560`。
- 若 Ollama 里模型维度被 MRL 截断过，这里会小于 2560 —— 那说明模型不是原版权重。

失败时最可能的三个原因：
1. Ollama 未运行 → `httpx.ConnectError: [Errno 111] Connection refused`（已实测该错误形态）。
2. 模型名不在 Ollama 里 → `/api/embed` 返回 404 或 `model not found`。
3. `A0_EMBEDDING_MODEL` 被环境覆盖成别的模型（默认 `qwen3-embedding:4b-q4_K_M`）。

### 4.4 命令 B：记忆写入（**会写状态**）

写入入口是工具 `memory_save`（`plugins/_memory/tools/memory.py:35 _save`），底层 `Memory.insert_text`（`helpers/memory.py:470`）。它需要 `agent` 来定位 subdir；绕过 agent 的等价写法是 `Memory.get_by_subdir("default")`：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import embeddings, vector_store
embeddings.apply(); vector_store.apply()
from plugins._memory.helpers.memory import Memory, abs_db_dir
async def main():
    db = await Memory.get_by_subdir("default", preload_knowledge=False)
    mid = await db.insert_text("a0 probe memory: the probe token is 42",
                               {"area": Memory.Area.MAIN.value, "source": "probe"})
    print("inserted id:", mid)
    print("db dir:", abs_db_dir("default"))
    hits = await db.search_similarity_threshold("what is the probe token", limit=5, threshold=0.0)
    print("hits:", len(hits))
    for d in hits[:3]:
        print("  -", str(d.page_content)[:120], d.metadata.get("area"))
asyncio.run(main())
PY
INNER
```

期望：打印 `inserted id: <10 位>`，`hits:` ≥ 1，且命中内容含 `42`；`db dir` 指向 `$B/usr/memory/default`。

注意：这条路会真正落盘索引文件（`vector_store.py` 用 numpy pickle，格式标记 `a0flatpak-numpy`，与真 faiss 互不兼容）。

### 4.5 命令 C：记忆检索（只读，前提是已有数据）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import embeddings, vector_store
embeddings.apply(); vector_store.apply()
from plugins._memory.helpers.memory import Memory
async def main():
    db = await Memory.get_by_subdir("default", preload_knowledge=False)
    pairs = await db.search_similarity_threshold_with_scores("probe token", limit=5, threshold=0.0)
    print("count:", len(pairs))
    for doc, score in pairs:
        print(round(float(score), 4), str(doc.page_content)[:100])
asyncio.run(main())
PY
INNER
```

带分数的版本用 `search_similarity_threshold_with_scores`（`helpers/memory.py:373`）；`search_similarity_threshold` 只回 `Document`。

失败时最可能的三个原因：
1. `Memory.get_by_subdir` 里的 `initialize.initialize_agent()` 找不到配置（`A0_BASE_DIR` 指错，或缺 `conf/`）→ `FileNotFoundError`。
2. 嵌入维度与既有索引不一致 → `expected vectors of width 2560, got N`（`vector_store.py:34`）。
3. 索引文件是别的实现写的 → `is not a a0flatpak numpy index`（`vector_store.py:70`）。

---

## 5. 语音

### 5.1 目的

确认 Web UI 的朗读/听写链路，并在沙盒里直接拿到 base64 WAV、再送回识别。

### 5.2 前置条件

- Ollama 在跑；`lfm3-omni:2b-q4_K_M` 已加载（manifest 已确认存在）。
- `a0flatpak.speech.apply()` 已执行（`flatpak/agent-zero.sh` 在启动时 `import a0flatpak; a0flatpak.apply()`）。
- 环境变量可选：`A0_SPEECH_MODEL`（默认 `lfm3-omni:2b-q4_K_M`）、`A0_SPEECH_VOICE`（默认 `female`）、`A0_SPEECH_TIMEOUT`（默认 180s）。

### 5.3 对外 API

| 方法 | 路径 | 请求体 | 成功响应 |
|---|---|---|---|
| POST | `/api/plugins/_kokoro_tts/synthesize` | `{"text":"..."}` | `{"success":true,"audio":"<base64 WAV>","mime_type":"audio/wav"}` |
| POST | `/api/plugins/_kokoro_tts/status` | `{}` | `{plugin,enabled,config,engine,model,package,fallback}` |
| POST | `/api/plugins/_whisper_stt/transcribe` | `{"audio":"<base64>","ctxid":"可选"}` | `{"success":true,"text":"...","language":"..."}` |
| POST | `/api/plugins/_whisper_stt/status` | `{}` | `{plugin,enabled,config,model,package}` |

要点：**全是 POST**；返回 JSON 而不是音频流；`audio` 字段是完整 WAV 的 base64（无 `data:` 前缀）。这两个 handler 继承默认 `requires_auth=True` + `requires_csrf=True`，所以 curl 要带 session + CSRF（同 2.7 的取 token 步骤）。

`synthesize_sentences` 的签名（`a0flatpak/speech.py:87`）与上游一致：

```python
async def synthesize_sentences(sentences: list[str], config: dict | None = None) -> str
```

### 5.4 命令 A：合成并落盘（只读，除你主动写 WAV 外）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio, base64, struct
from a0flatpak import speech
speech.apply()
from plugins._kokoro_tts.helpers import runtime as tts
async def main():
    b64 = await tts.synthesize_sentences(["你好，这是验收探针。"])
    print("b64 chars:", len(b64))
    raw = base64.b64decode(b64)
    print("bytes:", len(raw), "magic:", raw[:4], "wave:", raw[8:12])
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "not a RIFF/WAVE payload"
    # 采样率在 fmt 块：偏移 24 起 4 字节小端
    sr = struct.unpack_from("<I", raw, 24)[0]
    ch = struct.unpack_from("<H", raw, 22)[0]
    bits = struct.unpack_from("<H", raw, 34)[0]
    print("sample_rate:", sr, "channels:", ch, "bits:", bits)
    open("/home/kunweiz/a0-probe/tts.wav", "wb").write(raw)
    print("wrote /home/kunweiz/a0-probe/tts.wav")
asyncio.run(main())
PY
INNER
```

期望断言：

- `raw[:4] == b"RIFF"`、`raw[8:12] == b"WAVE"`。
- `sample_rate` **不得假定 24000**：上游 Kokoro 写死 24000（`_kokoro_tts/helpers/runtime.py:196`），但 Flatpak 走的是 Ollama 的 `/v1/audio/speech`，采样率由服务端决定。把实测值记录下来，不要用 24000 做硬断言。
- `channels`、`bits` 同样以实测为准。
- 文件大小 > 1000 字节（太小说明只有头）。

### 5.5 命令 B：把 WAV 送回识别（往返）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio, base64
from a0flatpak import speech
speech.apply()
from plugins._kokoro_tts.helpers import runtime as tts
from plugins._whisper_stt.helpers import runtime as stt
async def main():
    b64 = await tts.synthesize_sentences(["验收探针 往返测试"])
    res = await stt.transcribe(b64)
    print("keys:", sorted(res.keys()))
    print("text:", repr(res.get("text"))[:160])
    print("language:", res.get("language"))
    assert isinstance(res, dict) and "text" in res, "unexpected transcribe shape"
asyncio.run(main())
PY
INNER
```

期望：`keys` 至少含 `text`、`segments`、`language`（`a0flatpak/speech.py:71-74` 补的默认键）；`text` 非空且包含「验收」或「探针」之一。

不要假设 `text` 逐字等于输入：TTS 可能有韵律改写，STT 也可能把「验收探针」识别成近音词。断言用「非空 + 命中关键词之一」。

### 5.6 失败时最可能的三个原因

1. Ollama 没起 → `ConnectError: [Errno 111] Connection refused`（已实测该错误形态）。
2. `/v1/audio/speech` 或 `/v1/audio/transcriptions` 不被当前 Ollama 构建支持 → 404/405；此时 `_patch_tts` 仍是「成功打补丁」，但请求失败。
3. `lfm3-omni` 的语音能力需要单独的音频 projector/权重；manifest 里只有 `application/vnd.ollama.image.projector`（94MB），若服务端报缺 audio 模块，需要在 models 扩展侧补齐。

---

## 6. OCR / 文档解析

### 6.1 目的

确认上传与解析的真实触发点，并直接在沙盒里用 `ImageParser` / `PdfParser` 解析一张 PNG 与一个最小 PDF。

### 6.2 触发方式的结论

- `plugins/_document_query` **没有 `api/` 目录**，因此没有专属上传/解析路由。
- 上传走核心路由：`POST /api/message` / `POST /api/message_async` 的 multipart 字段 `attachments`，或 `POST /api/upload` 的字段 `file`。落盘 `usr/uploads/<safe_filename>`。
- **上传后不会自动解析**。解析只有在模型决定调用工具 `document_query` 时发生（参数 `document` 为路径/URI，`queries` 为问题列表；省略 `queries` 则只抽取原文）。
- 因此「纯 HTTP 一次调用完成解析」不存在：必须走对话（浏览器或 `/api/message*`），或直接在沙盒里调解析器。

### 6.3 生成探针输入（宿主，只读）

沙盒的 `/tmp` 是私有的，**宿主 `/tmp` 里的文件沙盒看不到**（已实测 `FileNotFoundError`）。要放在 `$HOME` 下：

```sh
mkdir -p "$HOME/a0-probe"
python3 - "$HOME/a0-probe" <<'PY'
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
img = Image.new("RGB", (600, 200), "white")
ImageDraw.Draw(img).text((20, 80), "A0 PROBE 42", fill="black")
img.save(f"{out}/a0_probe.png")

# 手写一个最小 PDF（不依赖 reportlab）
objs = [
 b"<< /Type /Catalog /Pages 2 0 R >>",
 b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
 b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
 b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
 None,  # 4: content stream，稍后填
 b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
stream = b"BT /F1 24 Tf 72 700 Td (A0 PDF PROBE 42) Tj ET"
objs[3] = b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream"
buf = bytearray(b"%PDF-1.4\n"); offs = [0]
for i, o in enumerate(objs, 1):
    offs.append(len(buf)); buf += f"{i} 0 obj\n".encode() + o + b"\nendobj\n"
xref = len(buf)
buf += f"xref\n0 {len(objs)+1}\n".encode() + b"0000000000 65535 f \n"
for off in offs[1:]:
    buf += f"{off:010d} 00000 n \n".encode()
buf += f"trailer\n<< /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
open(f"{out}/a0_probe.pdf","wb").write(buf)
print("png+pdf written to", out)
PY
ls -l "$HOME/a0-probe/"
```

### 6.4 命令 A：解析 PDF（只读）—— **当前版本会失败，见下**

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import ocr, parsers
ocr.apply(); parsers.apply()
from plugins._document_query.helpers.fetch import FetchedDocument
from plugins._document_query.helpers.parsers.pdf import PdfParser
p = "/home/kunweiz/a0-probe/a0_probe.pdf"
doc = FetchedDocument(uri="file://"+p, scheme="file", mimetype="application/pdf",
                      content=open(p,"rb").read(), local_path=p)
text = asyncio.run(PdfParser().parse(doc, {}, timeout=60))
print("len:", len(text), "contains probe:", "A0 PDF PROBE" in text)
PY
INNER
```

**已实测结果（真实缺陷）**：

```
TypeError: _parse_pdf_with_fallback.<locals>.parse() takes 2 positional arguments but 3 were given
```

原因：`a0flatpak/parsers.py:194` 把 `PdfParser._parse_sync` 换成了 `_parse_pdf_with_fallback(original)` 返回的闭包 `parse(document, config)`。赋给类属性后，通过实例调用会额外绑定 `self`，于是 3 个位置参数传给只接收 2 个的函数。`BaseParser.parse()` 走的就是 `self._parse_sync(document, config)`，所以**任何 PDF 解析都会炸**，与文件内容无关。

对照：`ImageParser` 用的是 `lambda self, document, config: ...`（`parsers.py`/`ocr.py`），签名正确，实测能走到 Ollama（返回 `ConnectError`）。

临时规避（不改仓库，只在运行时恢复原方法；**会改内存态，不落盘**）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import ocr
ocr.apply()                      # 只打图片补丁，不调 parsers.apply()
from plugins._document_query.helpers.fetch import FetchedDocument
from plugins._document_query.helpers.parsers.pdf import PdfParser
p = "/home/kunweiz/a0-probe/a0_probe.pdf"
doc = FetchedDocument(uri="file://"+p, scheme="file", mimetype="application/pdf",
                      content=open(p,"rb").read(), local_path=p)
text = asyncio.run(PdfParser().parse(doc, {}, timeout=60))
print("len:", len(text), "contains probe:", "A0 PDF PROBE" in text)
PY
INNER
```

期望：`contains probe: True`（数字 PDF 走 `PyMuPDFLoader` 文本抽取）。若仍失败，说明 `langchain_community` 的 PyMuPDF 依赖在沙盒里缺失。

### 6.5 命令 B：解析 PNG（只读，需要 Ollama + OCR 模型）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import ocr, parsers
ocr.apply(); parsers.apply()
from plugins._document_query.helpers.fetch import FetchedDocument
from plugins._document_query.helpers.parsers.image import ImageParser
p = "/home/kunweiz/a0-probe/a0_probe.png"
doc = FetchedDocument(uri="file://"+p, scheme="file", mimetype="image/png",
                      content=open(p,"rb").read(), local_path=p)
text = asyncio.run(ImageParser().parse(doc, {}, timeout=180))
print("type:", type(text).__name__, "len:", len(text))
print("text:", repr(text[:300]))
assert isinstance(text, str) and text.strip(), "empty OCR result"
print("ASSERT non-empty Markdown-ish text OK")
PY
INNER
```

期望：`text` 非空，且包含 `42`（探针图上的字）；`type` 是 `str`。

**重要前置**：`a0flatpak/ocr.py:21` 默认 `OCR_MODEL = "xiaomi-ocr"`，但当前 Models 扩展的 `manifests/` 里**只有** `lfm3-omni:2b-q4_K_M` 与 `qwen3-embedding:4b-q4_K_M` 两个 manifest；`xiaomi-ocr` 的 metadata 以 blob 形式存在（`models/metadata/sha256-1e49...json` 记录 `general.basename: Xiaomi-OCR`），但**没有对应的 manifest 条目**。因此默认名很可能加载不到。两个办法：

```sh
# 办法 1：换成一个确实存在的多模态模型
export A0_OCR_MODEL='lfm3-omni:2b-q4_K_M'   # 必须在 flatpak run 时 --env 传入，或写进 override
# 办法 2：确认 xiaomi-ocr 是否被 Ollama 识别（Ollama 在跑时）
curl -sS http://127.0.0.1:11434/api/tags | python3 -c 'import json,sys;print([m["name"] for m in json.load(sys.stdin)["models"]])'
```

### 6.6 失败时最可能的三个原因

1. PDF：上面那个 `TypeError`（打包层缺陷，与数据无关）。
2. 图片：`xiaomi-ocr` 没有 manifest，`/api/chat` 返回 model not found。
3. 路径：把探针文件放在宿主 `/tmp`，沙盒看不到（Flatpak 私有 `/tmp`）。必须放 `$HOME` 下。

---

## 7. 浏览器工具

### 7.1 目的

用宿主 Chrome 打开一个 `data:text/html` 页面并读回标题。

### 7.2 调用面

- 工具名：`browser`（`plugins/_browser/tools/browser.py`，`Browser.execute(action=...)`），动作 `open` / `state` / `navigate` / `content` / `screenshot` 等。
- 运行时：`plugins/_browser/helpers/runtime.py:3199 get_runtime(context_id)`。
- 补丁：`a0flatpak/browser.py` 把 `hooks.prepare_playwright_cache` 指向系统 Chrome，并把 `BrowserPool.start` 改成用 `nodriver` 带 `browser_executable_path` 启动。

### 7.3 关键事实：沙盒内看不到 Chrome

已实测：

```sh
flatpak info --show-permissions org.agentzero.AgentZero
# filesystems=home;/run/udev:ro;
```

manifest 里写的 `--filesystem=host`、`host-etc:ro`、`host-os:ro` **没有体现在已安装的 build 上**（安装 commit `44c0ae8`，2026-11-01）。结果是沙盒内 `/opt` 不存在、`/run/host` 只有 `fonts`/`share`，`browser.find_system_chrome()` 返回 `None`，`_patch_stealth_browser` 退回原始行为（尝试下载 Patchright Chromium）。

宿主 Chrome 的真实位置：`/usr/bin/google-chrome-stable -> /opt/google/chrome/google-chrome`，版本 `Google Chrome 156.0.8078.79`。

### 7.4 前置条件：让沙盒看见 Chrome（**改 Flatpak 权限**）

> **本机实测（2026-11-17，v6 之后）：这一节的前置已经失效。** 清单里的
> `--filesystem=host` 与 `host-os:ro` 让宿主 Chrome 在沙盒里直接可见
> （`/run/host/root/opt/google/chrome/google-chrome` 与 `/opt/google/chrome/google-chrome`
> 都是可执行的，`--version` rc=0、`ldd` 无 `not found`），**不需要任何 override**。
> 没有 Chrome 时 Patchright 还会静默下载 `chromium-1228` 回退，因此「看不到 Chrome」
> 这个前提在本机已经无法复现。下面的 override 步骤只在旧版打包（无 `host*` 权限）上才需要。

```sh
flatpak override --user --filesystem=/opt/google/chrome:ro org.agentzero.AgentZero
flatpak info --show-permissions --user org.agentzero.AgentZero | sed -n '/filesystems/p'
# 期望：filesystems=home;/run/udev:ro;/opt/google/chrome:ro;
```

如果 Chrome 的可执行文件在 `/usr/bin` 且需要该路径可见，再加一条：

```sh
flatpak override --user --filesystem=/usr/bin/google-chrome-stable:ro org.agentzero.AgentZero
```

回滚（恢复到安装时权限，**作者已执行，当前真机就是这个状态**）：

```sh
flatpak override --user --reset org.agentzero.AgentZero
```

已实测（旧打包）：加 `/opt/google/chrome:ro` 后，`browser.find_system_chrome()` 从 `None` 变为 `Path('/opt/google/chrome/google-chrome')`；随后执行了 `--reset` 回滚。**该结论对当前构建不再成立**：`--filesystem=host*` 已覆盖这条路径，默认安装即可命中，见本节开头的说明。

同时要显式告诉补丁去哪找（否则它仍走 `shutil.which`）：

```sh
flatpak run --user --command=sh --env=A0_BROWSER_CHROME=/opt/google/chrome/google-chrome \
  org.agentzero.AgentZero -s <<'INNER'
... 探针 ...
INNER
```

### 7.5 命令：打开 data: 页面并取标题（只读）

下面是自包含的一次性探针。矩阵里的 `S-BROWSER MODE=…` 是同一段逻辑的命名版本，
定义在 `test-matrix.md` §「S-BROWSER」；三种 MODE 的差别只有最后的断言：
`MODE=chrome` 只打印 `chrome:` 后退出，`MODE=title` 起浏览器取 `title`，
`MODE=nochrome` 断言 `open` 抛出可读错误而不是挂死。

```sh
flatpak run --user --command=sh \
  --env=A0_BROWSER_CHROME=/opt/google/chrome/google-chrome \
  org.agentzero.AgentZero -s <<'INNER'
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
"$B/venv/bin/python" - <<'PY'
import asyncio
from a0flatpak import browser
browser.apply()
print("chrome:", browser.find_system_chrome())
from plugins._browser.helpers.runtime import get_runtime

HTML = "data:text/html,<title>A0 Probe Title</title><h1>hello</h1>"
async def main():
    rt = await get_runtime("probe-ctx")
    res = await rt.call("open", HTML)
    print("open id:", res["id"])
    st = await rt.call("state", res["id"])
    print("title:", repr(st.get("title")), "url:", st.get("currentUrl"))
    assert st.get("title") == "A0 Probe Title", "title mismatch"
    print("ASSERT title OK")
    await rt.call("close_all")
asyncio.run(main())
PY
INNER
```

期望：`chrome: /opt/google/chrome/google-chrome`；`title: 'A0 Probe Title'`；`ASSERT title OK`。

补充：`BrowserRuntimeSession.call` 是异步的；`open` 返回 `{"id":..., "state":{...}}`（`helpers/runtime.py:1327`），`state` 里带 `title`（`helpers/runtime.py:2896`）。

### 7.6 失败时最可能的三个原因

1. `chrome: None`：`A0_BROWSER_CHROME` 指向的文件不存在或**不可执行**（v9 起 override 分支也校验 `os.access(X_OK)`，`/etc/passwd` 这类路径会被当作未找到），或宿主确实没装 Chrome。
2. Chrome 起了但立即退出：沙盒内缺 `/dev/dri` 或 X 连接。`DISPLAY=:0.0` 在沙盒里是可见的（`/tmp/.X11-unix/X0` 存在），`browser.py` 用 `headless = not os.environ.get("DISPLAY")`，有 DISPLAY 就走有头模式；若宿主 X 拒绝连接，改装 headless 或检查 `XAUTHORITY=/run/flatpak/Xauthority`。
3. `stealth_browser` 导入失败：`a0flatpak/browser.py:96` 的 `_patch_stealth_browser` 直接 `return`，于是退回下载 Patchright，沙盒内无网/无 cache 时失败。

---

## 8. 桌面 / Xpra

### 8.1 目的

在沙盒里调用 `ensure_system_desktop()`，拿到 Xpra HTML 页面地址。

### 8.2 调用面

- 函数：`plugins/_desktop/helpers/desktop_session.py:140 DesktopSessionManager.ensure_system_desktop(self) -> dict`
- 返回**结构化 dict**，不是 HTML：成功含 `available/session_id/url/token/display/desktop_path/width/height`；失败含 `available:false, error, status`。
- Web UI 入口：`/api/plugins/_desktop/desktop_session`（`plugins/_desktop/api/desktop_session.py`），以及启动时挂载的 `/desktop` ASGI 路由（`extensions/python/startup_migration/_20_desktop_routes.py`）。
- 端口：`XPRA_PORT_BASE = 14500`，显示 `:120` 起，最多 12 个会话。

### 8.3 命令：启动系统桌面（**会写状态**）

直接复用 `systemd/a0-desktop-start` 的形态：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
export LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export A0_BASE_DIR="$B"
cd /app/share/agent-zero
GIT_PYTHON_REFRESH=quiet \
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
  "$B/venv/bin/python" - <<'PY'
import json
import a0flatpak; a0flatpak.apply()
from plugins._desktop.helpers import desktop_session as ds
r = ds.DesktopSessionManager().ensure_system_desktop()
print("available:", r.get("available"))
print("error:", r.get("error") or "")
print("session_id:", r.get("session_id"))
print("display:", r.get("display"))
print("url:", r.get("url"))
print("token:", r.get("token"))
if r.get("available"):
    print("ASSERT url non-empty:", bool(r.get("url")))
PY
INNER
```

期望：`available: True`；`display: ':0'` 或 `':120'`；`url` 形如
`/desktop/session/agent-zero-desktop/index.html?path=%2Fdesktop%2Fsession%2Fagent-zero-desktop%2F&title=Desktop&quality=85&speed=80&...`

### 8.4 取 Xpra HTML 页面

`ensure_system_desktop()` 返回的 `url` 是 **Agent Zero 自己挂载的路径**，要拼上 Web UI 的 origin：

```sh
URL_PATH=$(python3 -c '...')   # 上一步打印的 url
curl -sS -o /dev/null -w 'HTTP=%{http_code}\n' \
  "http://127.0.0.1:5080${URL_PATH}"
```

若启用了 `A0_AUTH_KEY`，带 cookie 或 Bearer：

```sh
curl -sS -o /dev/null -w 'HTTP=%{http_code}\n' \
  -H "Authorization: Bearer $A0_AUTH_KEY" \
  "http://127.0.0.1:5080${URL_PATH}"
```

期望 `HTTP=200`，且响应体是 HTML（含 `xpra` 客户端脚本引用）。直接连 Xpra 的 TCP 端口不是给人看的页面（那是 Xpra 的协议端口）：

```sh
ss -ltn | grep -E '1450[0-9]'
```

### 8.5 `A0_AUTH_KEY` 如何映射到 Xpra

**只在无显示器的分支生效**。`a0flatpak/desktop.py` 的 `_spawn_desktop_locked` 分两条路：

- **有可达 DISPLAY**（当前真机就是这种：`DISPLAY=:0.0`、沙盒内 `/tmp/.X11-unix/X0` 存在）→ 走 `desktop_session._xpra_shadow_command(xpra, session)`，**不加** `--tcp-auth`，**不设** `XPRA_PASSWORD`。Xpra 端口 14500+ 只 bind `127.0.0.1`，但没有密码。
- **无 DISPLAY 但有 Xvfb** → 走 `start-desktop` 分支，且

```python
auth_key = os.environ.get("A0_AUTH_KEY", "").strip()
if auth_key:
    env["XPRA_PASSWORD"] = auth_key
...
*(["--tcp-auth=env"] if os.environ.get("A0_AUTH_KEY", "").strip() else []),
```

即 `XPRA_PASSWORD=<A0_AUTH_KEY>` + `--tcp-auth=env`（Xpra 的 `env` 认证模块读 `XPRA_PASSWORD`）。

对应验证命令：

```sh
# 判断当前会走哪条分支
flatpak run --user --command=sh org.agentzero.AgentZero -s <<'INNER'
python3 - <<'PY'
import os
d = os.environ.get("DISPLAY","").strip()
n = d.partition(".")[0].partition(":")[2] if d else "0"
print("DISPLAY:", repr(d))
print("X socket exists:", os.path.exists(f"/tmp/.X11-unix/X{int(n or 0)}"))
print("=> branch:", "shadow (no xpra auth)" if d and os.path.exists(f"/tmp/.X11-unix/X{int(n or 0)}") else "headless (tcp-auth=env)")
PY
INNER
```

**安全含义要写清楚**：`A0_AUTH_KEY` 保护的是 Agent Zero 的 ASGI（`a0flatpak/auth.py`），**不保护** shadow 分支下 14500 端口的 Xpra。本机任何进程都能连。要多用户隔离，只能靠 headless 分支的 `--tcp-auth=env`。

### 8.6 失败时最可能的三个原因

1. `available: False` + `error` 提到 `xpra`：`/app/bin/xpra` 缺失（当前已实测存在），或 `collect_desktop_status()` 报 `xpra-html5` 缺失。
2. `_host_display()` 抛 `RuntimeError: No desktop to share`：`DISPLAY` 为空且 `Xvfb` 不在 `PATH`/`/app/bin/Xvfb`（当前两者都存在）。
3. `xpra` 启动了但端口不通：`session.profile_dir/xpra-stderr.log` 里有原因；`LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb` 漏了会缺 `gi`/`cairo`。

---

## 9. WPS MCP

### 9.1 目的

确认注册格式与 MCP 握手，并用一条命令完成 `initialize` + `tools/list`。

### 9.2 注册格式（`flatpak/wps-mcp-config.json`）

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/node",
      "args": [
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

**这里有一个与真机不符的地方**：WPS 扩展是 **user 安装**，实际路径在 `~/.local/share/flatpak/...`；`/var/lib/flatpak/app/org.agentzero.AgentZero.Wps` 在本机**不存在**（已实测）。而且 `files/bin/` 下**没有 `node`**，只有 `bun` 与 `wps-mcp`（已实测）。

所以照抄这份配置中的 `command` 会 ENOENT。可用的两种写法：

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
      "args": [
        "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

或直接走扩展的 entrypoint（`files/bin/wps-mcp`，内容 `exec "$BUN" "$SERVER" "$@"`）：

```json
{ "mcpServers": { "wps-office": { "command": "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/wps-mcp", "args": [] } } }
```

配置读取位置：`usr/settings.json` 的 `mcp_servers` 字段（`helpers/settings.py:98`、`helpers/mcp_server.py`）。UI 在 Settings → MCP。

### 9.3 传输方式

**stdio**，不是 HTTP。证据：`dist/server/mcp-server.js:574` `new StdioServerTransport()`；`wps-mcp.sh` 的注释也写明 "speaks MCP on stdin/stdout"，另外它起一个 `127.0.0.1:58891` 的 add-in 轮询端口。

### 9.4 命令 A：手写 JSON-RPC 握手（只读，已实测）

```sh
python3 - <<'PY'
import json, os, subprocess
ROOT = os.path.expanduser("~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files")
BUN = os.path.join(ROOT, "bin", "bun")
SERVER = os.path.join(ROOT, "wps-skills/wps-office-mcp/dist/index.js")
msgs = [
    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"2024-11-05","capabilities":{},
        "clientInfo":{"name":"a0-probe","version":"0.0.1"}}},
    {"jsonrpc":"2.0","method":"notifications/initialized"},
    {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}},
]
payload = "".join(json.dumps(m, ensure_ascii=False) + "\n" for m in msgs)
p = subprocess.run([BUN, SERVER], input=payload, capture_output=True, text=True, timeout=90)
print("rc:", p.returncode)
for line in p.stdout.splitlines():
    if line.strip():
        print(json.dumps(json.loads(line), ensure_ascii=False)[:400])
PY
```

实测输出（首两行）：

```
{"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"wps-office-mcp","version":"1.0.0"}},"jsonrpc":"2.0","id":1}
{"result":{"tools":[{"name":"wps_check_connection","description":"检查WPS Office连接状态","inputSchema":{"type":"object","properties":{}}}, ... ]},"jsonrpc":"2.0","id":2}
```

断言：

- `result.serverInfo.name == "wps-office-mcp"`、`result.protocolVersion == "2024-11-05"`。
- 第二条的 `result.tools` 是数组且长度 > 0，包含 `wps_check_connection`、`wps_get_active_document`、`wps_insert_text` 等。
- `rc == 0`。

### 9.5 命令 B：用官方 MCP SDK（可选，需要 `mcp` 包）

```sh
python3 - <<'PY'
import asyncio, os
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = os.path.expanduser("~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files")
params = StdioServerParameters(
    command=os.path.join(ROOT, "bin", "bun"),
    args=[os.path.join(ROOT, "wps-skills/wps-office-mcp/dist/index.js")],
    env=dict(os.environ),
)
async def main():
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            init = await s.initialize()
            print("server:", init.serverInfo.name, init.protocolVersion)
            tools = await s.list_tools()
            print("tools:", len(tools.tools), [t.name for t in tools.tools][:8])
asyncio.run(main())
PY
```

如果目标机没有 `mcp` 包，不要安装；用 9.4 的手写版本即可（无依赖）。

### 9.6 失败时最可能的三个原因

1. `FileNotFoundError`：照抄了 `/var/lib/flatpak/...`（user 安装不在那），或用了 `bin/node`（该扩展只带 `bun`）。
2. `rc != 0` 且 stderr 提到 `bun: command not found`：`wps-mcp` entrypoint 里的 `BUN=/app/bin/bun` 只在 `flatpak run --command=wps-mcp` 时有意义，宿主直跑要指到 `files/bin/bun`。
3. 握手成功但 `tools/list` 为空：server 起来了但 `wpsClient` 连不上 WPS（需要宿主装了 WPS 且 add-in 已安装；本机 `command -v wps` 为空，`/opt/kingsoft/wps-office` 不存在）。这只影响工具的实际效果，不影响握手。

---

## 10. 所有探针的一页速查

| 功能 | 一条命令的入口 | 是否需要 Ollama | 是否改状态 |
|---|---|---|---|
| 聊天（HTTPS 同步） | `POST /api/api_message` + `X-API-Key` | 否（走 kw92） | 是 |
| 聊天（浏览器等价） | `POST /api/message_async` + `/api/poll` | 否 | 是 |
| kw92 端点 | `POST http://127.0.0.1:18080/v1/chat/completions` | 否 | 否 |
| 嵌入维度 | 沙盒 `models.get_embedding_model(...).embed_query` | 是 | 否 |
| 记忆写入/检索 | 沙盒 `Memory.get_by_subdir("default")` | 是 | 写入=是 / 检索=否 |
| TTS | 沙盒 `tts.synthesize_sentences([...])` | 是 | 否 |
| STT | 沙盒 `stt.transcribe(b64)` | 是 | 否 |
| 图片 OCR | 沙盒 `ImageParser().parse(doc)` | 是 | 否 |
| PDF 解析 | 沙盒 `PdfParser().parse(doc)` | 否（但当前有 bug） | 否 |
| 浏览器 | 沙盒 `get_runtime(...).call("open", "data:text/html,...")` | 否 | 否 |
| 桌面 | 沙盒 `DesktopSessionManager().ensure_system_desktop()` | 否 | 是 |
| WPS MCP | 宿主 `bun dist/index.js` + stdio JSON-RPC | 否 | 否 |

---

## 11. 不确定、必须在实机上再试的假设

下面这些我**没有**在真机上完整验证，或证据只到「代码如此」，请按条目逐个确认。

1. **Ollama 从未在这个环境里启动过**（`ss` 无 11434、`curl /api/version` 失败）。第 4/5/6 节里所有依赖 Ollama 的断言（2560 维、WAV 头、OCR 文本）只在代码层成立，尚未跑通一次真实调用。必须先确认 Ollama 由 `flatpak run --user org.agentzero.AgentZero` 正常拉起（它由 `agent-zero.sh` 启动，模型缺失时会设 `A0_MODELS_MISSING=1`）。
2. **`xiaomi-ocr` 能否被加载**：`models/manifests/` 里没有它的条目，只有 metadata blob。默认 `A0_OCR_MODEL=xiaomi-ocr` 很可能失败。需要 `ollama list` 或 `/api/tags` 确认。
3. **`lfm3-omni` 的音频端点**：manifest 只证明有 model + projector（视觉）。`/v1/audio/speech` 与 `/v1/audio/transcriptions` 是否被这个 Ollama 版本支持、是否需要额外 audio projector，未验证。
4. **TTS 的真实采样率**：不要照抄 24000。上游 Kokoro 写死 24000，Flatpak 走 Ollama，值可能不同；第 5.4 节打印实测值。
5. **`PdfParser` 的补丁缺陷**（已实测失败）是否会影响其它调用面：`document_query` 工具、`UnstructuredParser` 的 soffice/OCR 回退路径、以及 LibreOffice 桌面打开文档。我只验证了 `PdfParser.parse()` 直接失败；工具链上层会把这个 `TypeError` 包成工具错误返回给模型。
6. **`flatpak override` 的持久性**：我加过 `/opt/google/chrome:ro` 并实测生效，随后已执行 `--reset` 回滚，当前真机权限回到 `filesystems=home;/run/udev:ro;`。`--reset` 会一并清掉你已有的其它 override；若你之前就有自定义 override，先备份 `~/.local/share/flatpak/overrides/org.agentzero.AgentZero`。
7. **`A0_AUTH_KEY` 在真机上是否设置**：当前 `/api/health` 返回 `000`（服务没起），无法判断。若设置了，所有 curl 都要加 `Authorization: Bearer`，且 `X-API-Key` 与它不是一个值（前者过 ASGI 门，后者过 handler 门）。
8. **`/api/message` 的 CSRF**：我按 `requires_csrf=True` 推断需要 `X-CSRF-Token`，但没有在运行中的服务上实测过；`/api/api_message` 明确 `requires_csrf=False`，是更稳的路径。
9. **Socket.IO 的「回答完成」信号**：`state_push` 里的 `type=="response"` 条目只有 `content`，我没找到可靠的 `kvps.finished` 标记（`extensions/python/response_stream/_20_live_response.py:41` 只设 `type/heading/id`）。因此第 2.7 节的断言用「出现非空 response」而不是「finished==true」。
10. **kw92 的 `/v1/models`**：它返回纯文本 `Use a POST completion endpoint.`，不是 JSON。任何把模型清单当健康检查的脚本都会误判。以 `POST /v1/chat/completions` 为准。
11. **`max_tokens=384000` 的服务端上限**：实测 `HTTP=200` 且只生成 2 token，说明参数被接受；但**没有**验证接近上限时的行为（截断、超时、计费）。
12. **`ctx_length=1000000` 只是框架预算**：`helpers/history.py` 用它裁剪历史，不发给服务端。真实可用上下文取决于 zproxy 背后的模型；这一层没有可观测的校验点。
13. **WPS add-in**：宿主没有 `wps` 命令、没有 `/opt/kingsoft/wps-office`，所以 `wps-mcp` 的工具调用不会真正生效。握手与 `tools/list` 我已实测通过。
14. **沙盒私有 `/tmp`**：Flatpak 把 `/tmp` 隔离，宿主文件必须放 `$HOME` 下才能被沙盒看到（已实测）。
15. **`flatpak run --command=<venv python>` 与 `--command=sh` 的等价性**：我只实测了 `--command=sh` 后手动 `cd` + 设 `PYTHONPATH`。直接用 `--command=$B/venv/bin/python` 时 `argv[0]`/`sys.path[0]` 会不同，`import a0flatpak` 可能失败，除非同样设 `PYTHONPATH` 与 cwd。建议统一用 `--command=sh`。
