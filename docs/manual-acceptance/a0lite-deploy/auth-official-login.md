# 官方 UI 登录替换自建 API Key

2026-11-18。实例 `127.0.0.1:5080`，systemd `agent-zero.service`，Flatpak `org.agentzero.AgentZero`。

## §1 为什么换

自建 `A0_AUTH_KEY` 是打包层 `flatpak/a0flatpak/auth.py` 的 ASGI 中间件，由 `serve.py` 包住整个 app，豁免只有 `/api/health` 与 `/js/manifest.json`——连上游 `/login` 也被挡成 401。key 又通过 `?key=` 进入 URL、浏览器历史与反向代理日志。官方登录用 Flask session cookie，凭据既不进 URL 也不进日志。

## §2 官方机制

`helpers/login.py`：`get_credentials_hash()` = `sha256("AUTH_LOGIN:AUTH_PASSWORD")`（无盐），`AUTH_LOGIN` 非空即 `is_login_required()`；登录成功后该 hash 写入 session。`helpers/settings.py:851`：`mcp_server_token` = `base64url(sha256(f"{runtime_id}:{login}:{password}"))[:16]`。

## §3 改了什么

- `usr/.env`（`600 kunweiz:kunweiz`）：写入 `AUTH_LOGIN=admin`、`AUTH_PASSWORD=<随机 32 字符>`、`FLASK_SECRET_KEY=<64 hex>`，各一次。备份 `.env.bak-auth-20261118-131450`。
- `/etc/a0lite/env`（`600 root:root`）：删除 `A0_AUTH_KEY`，只剩注释与 `A0_PORT=5080`。备份 `/etc/a0lite/env.bak-auth-20261118-131450`。
- 无需改代码、无需重建：`serve.py:30,34` 仅在 `A0_AUTH_KEY` 非空时安装 `AuthMiddleware`。
- 密码存 `/root/a0-admin-credential.txt`（`600`）。

## §4 验证（重启后原始状态码）

| 组 | 请求 | 结果 |
|---|---|---|
| A | `GET /login` | 200；`<form ... method="POST" action="/login?next=/">`，字段 `username`、`password`、`next` |
| B | `GET /` | 302 → `/login?next=/` |
| B | `GET /api/get_work_dir_files` | 302 → `/login?next=/api/get_work_dir_files` |
| B | `GET /api/csrf_token` | 302 → `/login?next=/api/csrf_token` |
| C | `GET /?key=<旧key>` | 302 → 登录页 |
| C | `POST /api/message` + `Authorization: Bearer <旧key>` | 302 → 登录页 |
| C | `POST /api/message` + `X-API-KEY: <旧key>` | 302 → 登录页 |
| C | `POST /api/message` 无凭据 | 302 → 登录页 |
| D | 错密码 `POST /login` | 200，停留登录页 |
| D | 正确密码 `POST /login` | 302 → `/`；随后 `GET /` 200，`<title>Agent Zero</title>`，无 `login-form` |
| E | `GET /desktop/health` | 401 |
| F | `https://a0-7940hs.kw92.cyou/login` | 200，`ssl_verify_result=0` |
| F | `https://a0-7940hs.kw92.cyou/api/health` | 200 |

`GET /api/message` 返回 405 是因为路由只收 POST，不作认证结论。

## §5 副作用

`mcp_server_token` 随凭据变化（实测 old→new `changed=True`，16 字符）。所有 `X-API-KEY` 机器调用与 `/t-<旧token>/sse|http` MCP URL 立即失效，需在各客户端与 MCP 配置里换成新 token。Web UI 登录不受影响。

## §6 查看密码

```sh
sudo cat /root/a0-admin-credential.txt
```

## §7 回滚

```sh
cp -a /etc/a0lite/env.bak-auth-20261118-131450 /etc/a0lite/env
cp -a ~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/.env.bak-auth-20261118-131450 \
      ~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/.env
sudo systemctl stop agent-zero; flatpak kill org.agentzero.AgentZero 2>/dev/null
sudo systemctl start agent-zero
```

回滚后旧 key 恢复、官方登录关闭。
