# D59 空消息返回 200

## 现象

`POST /api/message` 对 `{"text":""}`、`{}`、`{"text":null}`、纯空白返回 200，
并写入最近会话（如 `AydPBQMe`）。`/api/api_message` 对空消息返回 400。

## 根因

`api/message.py:54`（JSON）、`:31`（multipart）用 `get("text", "")` 取值，
空值不做检查，直接进入 `AgentContext.communicate`（`:63` 之后），模型因此
启动一轮真实对话。`api/api_message.py:51` 的 `if not message:` 已覆盖空串、
null 和缺失，故该入口不动。

## 改法

新增 `flatpak/a0flatpak/chat_guard.py`，包装 `api.message.Message.process`。
它从 handler 的同源字段读 `text`（JSON 用 `input`，multipart 用
`request.form`），缺失、`None`、纯空白返回 400
`{"ok":false,"error":"EMPTY_MESSAGE","message":"message text is required"}`；
非空文本原样交给原 `process`。幂等由 `Message._a0flatpak_chat_patched` 守卫，
读取异常写 `$A0_BASE_DIR/usr/logs/a0flatpak.log`。
`flatpak/a0flatpak/__init__.py:49-51` 在 `sensitive_paths` 之后接入。

## 沙盒验证

实例 venv + 实例代码树，独立进程执行 `a0flatpak.apply()`：

```
APPLY full: ok; patched: True
empty/missing/null/blank/multipart-missing: 400 {"ok":false,...,"message text is required"}
normal: {'message': 'hello', 'context': 'test'}
idempotent: True
api_message empty: 400 {"error": "Message is required"}
D59 VERIFY OK
```

## 构建后复验

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:PORT/api/message \
  -H 'Content-Type: application/json' -d '{"text":""}'        # 400
curl -s -X POST localhost:PORT/api/message -H 'Content-Type: application/json' \
  -d '{}'                                                     # EMPTY_MESSAGE，不碰会话
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:PORT/api/message \
  -H 'Content-Type: application/json' -d '{"text":"hello"}'   # 200
```
