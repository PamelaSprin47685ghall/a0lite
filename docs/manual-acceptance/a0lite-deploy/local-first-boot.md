# 本机首次启动基线（7940HS）

- 执行时间：2026-11-17 23:34–23:40 CST
- 对象：本机 `org.agentzero.AgentZero` user 安装，branch `master`
- 本轮边界：**只安装主包**；未安装 Cuda/WPS；未删除 `~/.var/app`；未修改 `conf/model_providers.yaml`；未跑模型推理重负载；`/tmp` 只放了不在本轮使用的旧文件，无大文件。**§9 例外**：按本轮指令临时添加了 `ALLOWED_ORIGINS` override 做验证。
- 结果一句话：**安装成功、启动成功、health 200、Ollama 三模型可见；但设置/项目等模态框内容为空，且沙盒内看不到宿主 Chrome。**

---

## 1. Gate 0 结果

### 1.1 构建收尾

```console
$ pgrep -af '[s]cripts/build.sh|[f]latpak build-bundle' || echo 'BUILD_EXITED'
BUILD_EXITED

$ ls -l bundles/
total 947172
-rw-r--r-- 1 kunweiz kunweiz 860154032 Nov 17 23:32 agent-zero-cuda.flatpak
-rw-r--r-- 1 kunweiz kunweiz  50210576 Nov 17 23:34 agent-zero-wps.flatpak
-rw-r--r-- 1 kunweiz kunweiz  59533584 Nov 17 23:23 agent-zero.flatpak
```

第一次哈希：

```console
$ sha256sum bundles/*.flatpak | tee "$HOME/a0-bundles.sha256"
0cf9af0bce9c86a4d894bee9d7a928ca0f466832c87b01bc3dfa111183db062c  bundles/agent-zero-cuda.flatpak
248f2834112b744e9195c2013009e0998cb47effdd6f680e7725fc9ab3b1d634  bundles/agent-zero-wps.flatpak
6ca80d7d98df968aeb6c13d1e1c274c0a8098e1bd25fba5bd5cca462c0f564b8  bundles/agent-zero.flatpak
```

20 秒后复核：

```console
$ sleep 20; sha256sum -c "$HOME/a0-bundles.sha256"
bundles/agent-zero-cuda.flatpak: OK
bundles/agent-zero-wps.flatpak: OK
bundles/agent-zero.flatpak: OK
```

**判定：通过。** 构建进程已退出，三包齐全，哈希稳定。

| 包 | 大小 | sha256 |
|---|---:|---|
| `agent-zero.flatpak` | 59,533,584 | `6ca80d7d98df968aeb6c13d1e1c274c0a8098e1bd25fba5bd5cca462c0f564b8` |
| `agent-zero-cuda.flatpak` | 860,154,032 | `0cf9af0bce9c86a4d894bee9d7a928ca0f466832c87b01bc3dfa111183db062c` |
| `agent-zero-wps.flatpak` | 50,210,576 | `248f2834112b744e9195c2013009e0998cb47effdd6f680e7725fc9ab3b1d634` |

说明：WPS bundle 实际约 50.2 MB，不是报告里预估的 190 MB；CUDA bundle 实际约 860 MB，不是 1.4 GB。均以实测为准。

---

## 2. 安装结果（commit 变化）

### 2.1 安装命令与输出

```console
$ flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak
Installing app/org.agentzero.AgentZero/x86_64/master
INSTALL_RC=0
```

安装前：

```console
Installed Size: 128.1 MB
        Commit: 44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b
          Date: 2026-11-01 11:30:12 +0000
```

安装后：

```console
$ flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date|Installed Size|Runtime'
Installed Size: 123.7 MB
       Runtime: org.freedesktop.Platform/x86_64/25.08
        Commit: 169f5e09e525a00ea4c901eedcdd4606dfb29d8b442e1e4af10d8ae2da0d471d
          Date: 2026-11-17 15:22:58 +0000
```

**判定：通过。** commit 已从 `44c0ae83…` 变为 `169f5e09…`，安装大小 123.7 MB。

### 2.2 安装后权限

```console
$ flatpak --user info --show-permissions org.agentzero.AgentZero
[Context]
shared=ipc;network;
sockets=pulseaudio;x11;
devices=dri;
filesystems=host-etc:ro;host-os:ro;/run/udev:ro;host;

[Environment]
OLLAMA_HOST=http://127.0.0.1:11434
```

新权限已经包含 `host`、`host-etc:ro`、`host-os:ro`。没有 `--device=all`，没有 Wayland。

### 2.3 未安装的包

- 未执行 `flatpak install ... agent-zero-cuda.flatpak`。
- 未执行 `flatpak install ... agent-zero-wps.flatpak`。
- 旧 `Models`、`Cuda`、`Wps` 扩展保留未动；主包只替换自己的 deployment。

---

## 3. 启动结果

### 3.1 启动命令

```console
$ LOG="$HOME/a0-local-backup/run-20261117-233600.log"
$ setsid flatpak run --user \
    --env=OLLAMA_MAX_LOADED_MODELS=1 \
    --env=OLLAMA_KEEP_ALIVE=10m \
    org.agentzero.AgentZero >"$LOG" 2>&1 </dev/null &
launcher_pid=1584823

$ # 轮询 /api/health
HEALTH_READY after 16s
```

### 3.2 健康与进程

```console
$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
HTTP=200

$ curl -sS -o /dev/null -w 'root=%{http_code}\n' --max-time 5 http://127.0.0.1:5080/
root=200

$ flatpak ps
1639783018	1584825	org.agentzero.AgentZero	org.freedesktop.Platform

$ ss -ltnp | grep -E ':(5080|11434|14500|58891)\b'
LISTEN 0      4096   127.0.0.1:11434 0.0.0.0:* users:(("ollama",pid=1584854,fd=3))
LISTEN 0      2048   127.0.0.1:5080  0.0.0.0:* users:(("python",pid=1584839,fd=29))
```

14500 和 58891 没有监听；14500 要等 Desktop 打开，58891 要等 WPS add-in（本轮都没做）。

### 3.3 日志尾部（关键行）

```console
$ tail -40 "$LOG"
...
Preparing web server runtime...
Initializing Agent Zero components...
BEWARE: your OS is not officially supported by Patchright; downloading fallback build for ubuntu24.04-x64.
Downloading Chrome for Testing 149.0.7827.55 (playwright chromium v1228) ...
...
Chrome for Testing 149.0.7827.55 (playwright chromium v1228) downloaded to
  /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/playwright/chromium-1228
...
Starting UI/API server...
INFO:     Started server process [2]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:5080 (Press CTRL+C to quit)
Agent Zero is running.
...
FFmpeg (playwright ffmpeg v1011) downloaded ...
INFO:     127.0.0.1:53474 - "WebSocket /socket.io/?EIO=4&transport=websocket" [accepted]
```

**启动判定：通过（有保留）。** 进程在跑、health 200、root 200、Ollama 11434 在听；但 health body 里有 `error` 字段，且日志显示浏览器补丁走了 Patchright 下载回退，而不是宿主 Chrome。

---

## 4. 5 项重点观察

### 4.1 venv：复用了旧 venv，没有重建

```console
$ ls -la "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/.a0-ready"
-rw-r--r-- 1 kunweiz kunweiz 0 Nov  1 16:51 .../venv/.a0-ready
```

启动日志里**没有** `agent-zero: preparing the framework environment`；只有框架自己的 `Initializing Python framework...`。因此可以判定：`.a0-ready` 仍然有效，旧 venv 被直接复用。

旧 venv 里仍有新 requirements 已删除的两个包：

```console
$ ls "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/lib/python3.14/site-packages" | grep -Ei 'stealth|nodriver'
nodriver
nodriver-0.50.99.dist-info
stealth_browser
stealth_browser-0.2.0.dist-info
```

这不影响本次启动（这两个包只是多余，未观察到缺失依赖），但说明新 requirements 的“删包”没有反映到运行环境；后续如果要保证依赖与 requirements 一致，需要重命名 venv 重建。本轮未做。

### 4.2 `usr/.gitkeep` 门控：生效

```console
$ ls -la "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/" | head -20
drwxr-xr-x ... .
-rw-r--r-- ... .env
-rw-r--r-- ... .gitkeep
drwxr-xr-x ... agents
drwxr-xr-x ... api
drwxr-xr-x ... knowledge
drwxr-xr-x ... plugins
drwxr-xr-x ... projects
drwxr-xr-x ... scheduler
drwxr-xr-x ... skills
drwxr-xr-x ... workdir
```

`.gitkeep` 的 mtime 是 `Nov 17 23:35`，说明新 launcher 的 `usr/.gitkeep` 判断触发了 seed；`workdir/`、`skills/`、`agents/`、`api/`、`plugins/` 等目录已出现，旧 `.env` 被保留。

### 4.3 `/a0`：没有建立

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'ls -ld /a0 2>&1; echo "writable:"; [ -w / ] && echo yes || echo no; readlink -f /a0 2>&1'
ls: cannot access '/a0': No such file or directory
writable:
yes
/a0
```

沙盒内 `/` 报告可写，但 `/a0` 不存在。launcher 里的 `ln -s "$BASE_DIR" /a0 2>/dev/null || true` 没有留下链接，也没有日志（错误被吞掉）。这会影响依赖 `/a0` 的 workdir/路径解析；本轮未修。

### 4.4 Ollama：已启动，三个模型可见

```console
$ curl -sS http://127.0.0.1:11434/api/tags | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(m["name"] for m in d["models"]))'
xiaomi-ocr:latest
lfm3-omni:2b-q4_K_M
qwen3-embedding:4b-q4_K_M
```

Ollama 进程环境：

```console
$ PID=1584854; tr '\0' '\n' < /proc/$PID/environ | grep -E 'OLLAMA_'
OLLAMA_HOST=127.0.0.1:11434
OLLAMA_MODELS=/app/share/agent-zero/models/models
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_KEEP_ALIVE=10m
```

没有出现 `ollama exited during startup`，11434 在听。**但 Ollama 日志文件被删除了**：

```console
$ ls -l /proc/1584854/fd/1 /proc/1584854/fd/2
l-wx------ ... /proc/1584854/fd/1 -> .../data/agent-zero/logs/ollama.log (deleted)
l-wx------ ... /proc/1584854/fd/2 -> .../data/agent-zero/logs/ollama.log (deleted)

$ find .../data/agent-zero -maxdepth 3 -name '*.log'
(空)
```

原因线索：应用启动时框架打印 `Removing logs...`，在 Ollama 已经打开 `ollama.log` 之后删除了 logs 目录。进程仍持有已删除文件的 fd，因此日志无法从路径读取，诊断信息丢失。严重度见第 7 节。

### 4.5 浏览器：沙盒内看不到宿主 Chrome，Patchright 走了下载回退

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'command -v google-chrome; ls -l /usr/bin/google-chrome; command -v xpra; ls /app/share/python-deps | head'
google-chrome MISSING
ls: cannot access '/usr/bin/google-chrome': No such file or directory
/app/bin/xpra
cairo
gi
xpra
```

宿主 Chrome 实际存在于沙盒的 `/run/host/root/opt/google/chrome/google-chrome`：

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c \
  'ls -l /run/host/root/opt/google/chrome/google-chrome'
-rwxr-xr-x 1 nfsnobody nfsnobody 1034 Oct 29 04:20 /run/host/root/opt/google/chrome/google-chrome
```

但 launcher/浏览器补丁没有找到它，启动日志显示：

```console
BEWARE: your OS is not officially supported by Patchright; downloading fallback build for ubuntu24.04-x64.
Downloading Chrome for Testing 149.0.7827.55 (playwright chromium v1228) ... 177 MiB
Chrome for Testing ... downloaded to .../data/agent-zero/tmp/playwright/chromium-1228
```

因此：**宿主 Chrome 路径没有直接生效**；浏览器工具目前更可能使用下载的 Chrome for Testing（未做实际浏览器工具调用验证）。这解释了 `command -v google-chrome` 为 MISSING，也解释了数据目录从 984M 增长到 1.3G。

---

## 5. 基线检查表

### 5.1 首页 HTML 前 40 行

```console
$ curl -sS http://127.0.0.1:5080/ | head -40
<!DOCTYPE html>
<html lang="en" data-splash-theme="dark">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <title>Agent Zero</title>
    <link rel="icon" type="image/svg+xml" href="/public/favicon.svg">
    <script>
        try {
            if (localStorage.getItem("darkMode") === "false") document.documentElement.dataset.splashTheme = "light"
        } catch (_) {}
    </script>
    <style>
        html, body { width: 100%; height: 100%; margin: 0; }
        html { background: #131313; color: #fff; }
        html[data-splash-theme="light"] { background: #fafafa; color: #000; }
        body { display: grid; place-items: center; font-family: system-ui, sans-serif; }
        #startup-transition { display: grid; justify-items: center; gap: 1rem; }
        #startup-transition > svg {
            width: clamp(12rem, 34vw, 23rem); max-width: 72vw; height: auto;
            opacity: 0; animation: startup-logo-in .55s ease-out .05s forwards;
        }
        #startup-transition > p { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
        @keyframes startup-logo-in { to { opacity: 1; } }
    </style>
</head>

<body>
    <main id="startup-transition" role="status" aria-live="polite">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 163 26" aria-hidden="true">
            <path fill="currentColor" d="m138.7 15.3c0.8 1.2 ...（单行长 SVG path，省略）"/>
        </svg>
        <p id="startup-status">Starting Agent Zero</p>
    </main>

    <script>
        (() => {
            const APP_DOCUMENT_PATH = "/ui/index"
            const ACTIVATION_TIMEOUT_MS = 8000
            const CACHE_TIMEOUT_MS = 10000
            const FALLBACK_TIMEOUT_MS = 15000
            let replacementStarted = false
```

说明：只把单行超长 SVG path 用 `...` 省略；`<!DOCTYPE html>`、`<title>Agent Zero</title>` 和启动过渡层都在，确认不是 4xx/5xx 错误页。

### 5.2 检查结果

| 检查 | 命令 | 结果 | 判定 |
|---|---|---|---|
| 首页状态 | `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/` | `200` | 通过 |
| 健康检查 | `curl -sS http://127.0.0.1:5080/api/health` | `{"gitinfo": null, "error": ".../data/agent-zero"}`，HTTP 200 | 通过但有异常字段 |
| JS manifest | `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/js/manifest.json` | `200`，480 字节 | 通过 |
| 首页 HTML | `curl -sS http://127.0.0.1:5080/ \| head -40` | `<!DOCTYPE html>`、`<title>Agent Zero</title>`、启动过渡层；不是错误页 | 通过 |
| 静态资源 1 | `/index.css` | `200 32672` | 通过 |
| 静态资源 2 | `/index.js` | `200 27530` | 通过 |
| 静态资源 3 | `/css/settings.css` | `200 15920` | 通过 |
| favicon | `/public/favicon.svg` | `200 1426` | 通过 |
| 沙盒 Chrome | `command -v google-chrome` | `MISSING` | **不通过** |
| 沙盒 Xpra | `command -v xpra` | `/app/bin/xpra` | 通过 |
| 沙盒 Python 依赖 | `ls /app/share/python-deps` | `cairo gi xpra` | 通过 |
| OCR 清单目录 | `ls -l /app/share/.../manifests-v2/ollama.com/library/` | `lfm3-omni`、`qwen3-embedding`、`xiaomi-ocr` 三个目录 | 通过（目录存在） |
| 数据目录 | `du -sh .../data/agent-zero` | `1.3G` | 记录（含 177M Chrome 下载） |
| 进程 | `flatpak ps` | `org.agentzero.AgentZero` 在跑 | 通过 |
| 端口 | `ss -ltnp` | 5080、11434 在听；14500/58891 未听 | 通过 |

补充：静态资源必须用根路径（`/index.css` 等）访问；`/ui/index` 是文档路径，`/ui/index.css` 会 404。首页 `/` 通过 `document.write` 注入 `/ui/index`，所以浏览器里的相对路径按根解析，UI 才能正常加载。

OCR 清单只确认了目录；`find ... -type f` 在 `manifests-v2/ollama.com/library/` 下没有返回文件，说明当前模型元数据不是以普通文件形式放在该目录，或层级更深。Ollama `/api/tags` 已确认三个模型可被服务端识别，所以模型本身可用；清单目录的文件级核对留待后续。

---

## 6. 截图与判读

截图目录：`/home/kunweiz/a0-shots/`

| 文件 | 尺寸 | mean | sd | 判读 |
|---|---|---:|---:|---|
| `01-home-233642.png` | 2880×1920 | 0.16977 | 0.261582 | 首页正常，非空白 |
| `02-settings-233732.png` | 2880×1920 | 0.139733 | 0.254161 | Settings 模态框打开，但主体空白 |
| `03-settings-10s-233803.png` | 2880×1920 | 0.13974 | 0.25416 | 等 10 秒后仍空白 |
| `04-projects-233923.png` | 2880×1920 | 0.129632 | 0.257829 | Projects 模态框打开，但主体空白 |
| `05-settings-after-origins.png` | 2880×1920 | 0.139845 | 0.254336 | 加 ALLOWED_ORIGINS 并重启后，Settings 仍空白 |
| `06-settings-fresh-profile.png` | 2880×1920 | 0.13954 | 0.253688 | 全新 Chrome profile 下，Settings 仍空白（排除缓存） |

所有截图的 `sd` 都远大于 0.02，说明不是“纯色空白”；但模态框空白仍成立，因为背景有遮罩、侧栏和模糊内容。**不能仅凭 sd 判定内容正常。**

### 6.1 首页（01）

肉眼/视觉判读：

- 深色主题，左侧 `AGENT ZERO` 侧栏；
- 主区 `Hello! I'm Agent Zero 👋`、`How can I help you today?`；
- 输入框 `Ask anything to start a new chat`；
- Quick Actions 卡片：Memory、Scheduled Tasks、Projects、Memory、Tasks、Files、Settings、Plugins、Visit Website；
- 无登录页、无错误横幅、无加载 spinner；
- 侧栏底部 `Version unknown unknown`；
- Quick Actions 里 “Memory” 出现两次（一个只有标题，一个带说明），属 UI 展示问题，不影响启动。

### 6.2 Settings（02/03）

点击左侧齿轮后，`Settings` 模态框出现，但主体是纯深色空白；没有表单、开关、分组标题，也没有 loading 或错误文案。等待 10 秒后（03）完全一样。因此不是“还没加载完”的瞬时状态。

### 6.3 Projects（04）

点击 Quick Actions 的 `Projects` 卡片后，`Projects` 模态框出现，主体同样空白，没有项目列表、没有错误、没有 loading。与 Settings 的表现一致，说明不是单个面板的问题；§9 进一步定位为统一的前端渲染问题（Alpine teleport 目标缺失），而不是单个面板的 API。

### 6.4 与 CSRF 的证据链

```console
$ curl -sS http://127.0.0.1:5080/api/csrf_token
{"ok": false, "error": "Origin None not allowed when login is disabled. Set login and password or add your URL to ALLOWED_ORIGINS env variable. Currently allowed origins: "}
```

带 `Origin` 的同一请求：

```console
$ curl -sS -H 'Origin: http://127.0.0.1:5080' http://127.0.0.1:5080/api/csrf_token
{"ok": true, "token": "<redacted 43 chars>", "runtime_id": "1f961084c253e368"}
```

用该 token 调 `settings_get`：

```console
$ curl -sS -b "$C" -H "X-CSRF-Token: $TOKEN" -H 'Origin: http://127.0.0.1:5080' \
    -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/settings_get
{"settings": {"version": "unknown", "api_keys": {...}, ...}}
HTTP=200
```

不带 token：

```console
$ curl -sS -b "$C" -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/settings_get
CSRF token missing or invalid
HTTP=403
```

结论：后端 settings 接口本身可用；失败点是 `csrf_token` 在没有 `Origin` 时返回 `ok:false`。浏览器同源 GET 是否带 `Origin` 未在 DevTools 中抓包，因此“浏览器拿不到 token”是按同源请求语义与空白模态框一致性作出的推断，不是直接观测；但 `ok:false` 与空白模态框确实是当前最影响验收的证据链。**这是当前最影响验收的缺陷。**

---

## 7. 发现的问题（按严重度）

### P1（高）设置/项目模态框空白；CSRF 假设未确认，Alpine teleport 缺失更可疑

证据：

- Settings 模态框 3 秒、13 秒、加 `ALLOWED_ORIGINS` 重启后、全新 Chrome profile 下均空白（`02`–`06`）。
- Projects 模态框同样空白（`04`）。
- 无 `Origin` 的 `/api/csrf_token` 返回 `{"ok": false, "error": "Origin None not allowed ... Currently allowed origins: "}`。
- 带 `Origin` 的同一请求返回 `ok:true` 与 43 字符 token；带 token 的 `settings_get` 返回 200 和完整 settings JSON。
- §9 加 `ALLOWED_ORIGINS` 后，无 Origin 的请求仍 `ok:false`，P1 的 CSRF 根因**未确认**。
- §9 CDP 证据：`settingsStore` 存在、modal body 7837 字节，但 `settingsPane=false`、`settingsXComponents=0`；`#welcome-channels` 不存在，却有 299 个 `x-teleport="#welcome-channels"` 模板，Alpine 反复报 `Cannot find x-teleport element` 与 `appendChild` null。

影响：设置、项目等模态框无法使用；聊天等依赖同一渲染链的功能也可能受影响。不是静态资源或后端崩溃。

未做：没有修改 `.env`/源码；只按本轮要求加了 `ALLOWED_ORIGINS` override 做验证（见 §9）。

### P2（中）宿主 Chrome 实际可执行，但 browser.py 没有选择它，Patchright 下载了 177 MiB 回退 Chrome

证据：

- `command -v google-chrome` → `MISSING`；`ls /usr/bin/google-chrome` → 不存在。
- 宿主 Chrome 存在于 `/run/host/root/opt/google/chrome/google-chrome`，但不在 `/usr/bin` 或 `/opt` 的沙盒路径。
- §9 C2：`/run/host/root/opt/google/chrome/google-chrome --version` → `Google Chrome 156.0.8078.79`，`rc=0`；实际二进制 `chrome --version` 也 `rc=0`，`ldd` 缺库数为 `0`。
- 启动日志自动下载 Chrome for Testing 149（177 MiB）到 `data/agent-zero/tmp/playwright/chromium-1228`。
- 数据目录从 984M 增长到 1.3G。

影响：浏览器工具可能使用下载的 Chrome 而不是宿主 Chrome，行为与设计目标不一致；`A0_BROWSER_CHROME` 未设置。正确修复方向是给 `browser.py` 增加 `/run/host/root/opt/google/chrome/google-chrome` 候选，而不是放弃宿主 Chrome。

### P3（中）Ollama 日志被删除，诊断信息丢失

证据：

- `/proc/1595381/fd/1` 和 `fd/2` 都指向 `.../logs/ollama.log (deleted)`（P1 重启后仍是）。
- `find .../data/agent-zero -name '*.log'` 为空。
- 应用日志有 `Removing logs...`，发生在 Ollama 打开日志之后。

影响：Ollama 启动失败、模型加载失败、GPU/CPU 选择等问题没有持久日志可查；只能靠 `/api/tags` 和进程状态间接判断。严重度中。

### P4（已排除/信息）`/a0` 在新沙盒不可见，但在应用命名空间中存在

证据：

- §9 C1：沙盒内 `touch /a0-probe` 返回 `0`，`ln -s /tmp /a0-probe2` 返回 `0`，说明 `/` 可写、`ln` 正常。
- 运行中的应用进程 `/proc/1595368/root/a0` 是指向 `/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero` 的符号链接；Ollama 进程的 namespace 里同样存在。
- 之前 `flatpak run --command=sh` 看不到 `/a0`，是因为每个 `flatpak run` 有独立的 mount namespace；不是启动脚本缺陷。

结论：**误报，已排除**。`/a0` 在应用进程的 namespace 内建立成功；没有 ln 错误原文，因为 `ln_rc=0`。

### P5（低）`/api/health` 200 但 body 含 `error` 字段

```json
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
```

影响：如果上层只看 HTTP 200 会认为完全健康；如果解析 body 的 `error`，会误判为失败。需要确认该字段是否预期（可能是 gitinfo 不可用的 fallback）。严重度低到中，取决于调用方。

### P6（信息/低）venv 复用，旧包未清理

- `.a0-ready` mtime `Nov 1 16:51`；日志无 `preparing the framework environment`。
- 旧 venv 仍有 `stealth_browser`、`nodriver`，而新 requirements 已删除它们。
- 本次启动不受影响；但如果后续代码依赖“已移除包不存在”的假设，需要重建 venv。本轮未动。

### P7（信息）UI 展示小问题

- 侧栏 `Version unknown unknown`；
- Quick Actions 中 `Memory` 重复出现两次；
- 部分图标复用（Tasks/Scheduled Tasks 同时钟，Files/Projects 同文件夹）。

这些不影响启动和 health，但会进入界面验收记录。

### P8（信息）未覆盖项

- 未安装 Cuda/WPS，未验证 CUDA 或 WPS 文档操作；本机无 NVIDIA、无 WPS Office，环境不具备。
- 未测试聊天发送、模型推理、OCR、TTS/STT；按边界要求避免重负载。
- 未验证 Xpra 桌面（14500 未启动）。
- 未修改 `conf/model_providers.yaml`，kw92 provider 仍未注册。

---

## 8. 结论

- Gate 0：**通过**（三包齐全、哈希稳定）。
- 安装：**通过**（commit 44c0ae83 → 169f5e09）。
- 启动：**通过**（health 200、root 200、Ollama 三模型可见）。
- 关键缺口：**设置/项目模态框空白（P1；CSRF 假设未确认，§9 指向 Alpine `#welcome-channels` 缺失）**；P2 宿主 Chrome 未被 `browser.py` 选择（但已证明可执行）；P3 Ollama 日志丢失；P4 已排除（`/a0` 在应用命名空间存在）。
- 当前应用仍在运行，未停服务、未删数据；只按 §9 添加了 `ALLOWED_ORIGINS` override，未改 `conf/model_providers.yaml`；后续 worker 可以在此基础上继续。

---

## 9. P1–P4 的即时验证（2026-11-17 23:42–23:45 CST）

本轮只做三件事：加 `ALLOWED_ORIGINS` override、重启现有实例、用 CDP/沙盒命令取证。未重建镜像，未安装 Cuda/WPS，未改仓库源码，未改 `conf/model_providers.yaml`，未跑模型推理重负载。

### 9.1 验证 A：P1 根因确认

#### A1 修改前的 override

```console
$ flatpak --user override --show org.agentzero.AgentZero
(空)
```

#### A2 添加 ALLOWED_ORIGINS

```console
$ flatpak override --user --env=ALLOWED_ORIGINS=http://127.0.0.1:5080 \
    org.agentzero.AgentZero
$ echo $?
0

$ flatpak --user override --show org.agentzero.AgentZero
[Environment]
ALLOWED_ORIGINS=http://127.0.0.1:5080
```

#### A3 重启并等健康检查

```console
$ flatpak kill org.agentzero.AgentZero
kill_rc=0

$ setsid flatpak run --user \
    --env=OLLAMA_MAX_LOADED_MODELS=1 --env=OLLAMA_KEEP_ALIVE=10m \
    org.agentzero.AgentZero >"$LOG" 2>&1 </dev/null &
LOG=/home/kunweiz/a0-local-backup/run-p1-234213.log

$ # 轮询
health_ready_7x2s

$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
HTTP=200
```

#### A4 csrf 的三种请求

```console
$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/csrf_token
{"ok": false, "error": "Origin None not allowed when login is disabled. Set login and password or add your URL to ALLOWED_ORIGINS env variable. Currently allowed origins: "}
HTTP=200

$ curl -sS -H 'Referer: http://127.0.0.1:5080/' -w '\nHTTP=%{http_code}\n' \
    http://127.0.0.1:5080/api/csrf_token
{"ok": true, "token": "<redacted 43 chars>", "runtime_id": "52db4cb5c3e72858"}
HTTP=200

$ curl -sS -H 'Origin: http://127.0.0.1:5080' -w '\nHTTP=%{http_code}\n' \
    http://127.0.0.1:5080/api/csrf_token
{"ok": true, "token": "<redacted 43 chars>", "runtime_id": "52db4cb5c3e72858"}
HTTP=200
```

**结论：P1 根因未确认。** 按本轮判据，加 `ALLOWED_ORIGINS` 后“不带 Origin”仍返回 `ok:false`，所以不能把 P1 归因于“缺这个 override”并收口。另一方面，带 `Referer` 或 `Origin` 时已经 `ok:true`，说明该 override 对带来源头的请求有效；但设置面板仍然空白，证明 CSRF 不是空白的充分解释。

### 9.2 验证 B：设置面板是否恢复

#### B1 有头 Chrome 截图（现有 profile）

```console
$ import -window "$WID" "$HOME/a0-shots/05-settings-after-origins.png"
$ identify -format 'file=%f size=%wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' \
    "$HOME/a0-shots/05-settings-after-origins.png"
file=05-settings-after-origins.png size=2880x1920 mean=0.139845 sd=0.254336
```

视觉判读：Settings 模态框打开，标题栏和 `×` 正常，**主体仍然没有任何分组标题、开关、输入框**，也没有错误或 loading。结论：**设置面板未恢复**。

#### B2 全新 Chrome profile（排除缓存）

```console
$ google-chrome --user-data-dir="$HOME/.cache/a0-shots-chrome2" ... http://127.0.0.1:5080/ &
$ import -window "$WID" "$HOME/a0-shots/06-settings-fresh-profile.png"
$ identify -format 'file=%f size=%wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' \
    "$HOME/a0-shots/06-settings-fresh-profile.png"
file=06-settings-fresh-profile.png size=2880x1920 mean=0.13954 sd=0.253688
```

视觉判读：同样空白。全新 profile 排除了 service worker/旧缓存的解释。

#### B3 CDP：DOM 与控制台

用带 `--remote-debugging-port=9223` 的 Chrome 连 CDP，执行 `document.querySelector('#header-settings').click()` 后读 DOM：

```json
{
  "modal": true,
  "modalClass": "modal-inner settings-modal",
  "modalText": "Settings\n×",
  "bdChildren": 2,
  "bdHTMLlen": 7837,
  "settingsPane": false,
  "settingsXComponents": 0,
  "allXComponents": 64,
  "store": "settings-store-present",
  "modalHTMLlen": 8261
}
```

进一步检查 welcome teleport：

```json
{
  "welcomeChannels": false,
  "welcomeChannelsCount": 0,
  "teleports": ["#sidebar-quick-actions-dropdown-slot-start", "#sidebar-quick-actions-dropdown-slot-end", "#welcome-channels", "#welcome-accounts", ...],
  "discoveryStore": true,
  "settingsStore": true,
  "settingsPane": false,
  "settingsX": 0,
  "bodyLen": 7837
}
```

实际统计：**299 个** `x-teleport="#welcome-channels"` 模板，`#welcome-channels` 目标数量为 **0**；这些模板来自 `/plugins/_discovery/extensions/webui/welcome-actions-end/discovery-cards.html`。控制台重复出现：

```text
Alpine Warning: Cannot find x-teleport element for selector: "#welcome-channels"

Alpine Expression Error: Cannot read properties of null (reading 'appendChild')
Expression: "$store.discoveryStore"

TypeError: Cannot read properties of null (reading 'appendChild')
    at s (http://127.0.0.1:5080/vendor/alpine/alpine.min.js:6:27406)
    ...
```

源码侧 `webui/components/welcome/welcome-screen.html:135` 确有 `<section id="welcome-channels" ...>`，但运行时 DOM 里没有它；`discoveryStore` 和 `settingsStore` 都存在，所以不是 store 未注册，而是目标 slot 未渲染 + Alpine teleport 报错。最可疑的因果链是：welcome slot 缺失 → Alpine 反复抛 `appendChild` 异常 → settings modal 的 `x-if` 内容没有完成渲染。

#### B4 用 Referer 模拟浏览器请求

```console
$ curl -sS -H 'Referer: http://127.0.0.1:5080/' -w '\nHTTP=%{http_code}\n' \
    http://127.0.0.1:5080/api/csrf_token
{"ok": true, "token": "<redacted>", "runtime_id": "52db4cb5c3e72828"}
HTTP=200
```

带 Referer 的 CSRF 已通过，进一步说明“设置空白”不是 CSRF 单独造成的；但“浏览器实际发的是哪个请求”未在 Network 面板逐条抓包，因此 P1 的 CSRF 链路仍按判据记为**未确认**。

### 9.3 验证 C：`/a0` 与宿主 Chrome

#### C1 `/` 可写、ln 是否成功、真实错误

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c '
    id
    ls -ld /
    touch /a0-probe 2>&1; echo touch_rc=$?
    ln -s /tmp /a0-probe2 2>&1; echo ln_rc=$?
    ls -ld /a0-probe2 2>&1
    rm -rf /a0-probe /a0-probe2'
uid=1000(kunweiz) gid=1001(kunweiz) groups=1001(kunweiz),65534(nfsnobody)
drwxr-xr-x 15 kunweiz kunweiz 480 Nov 17 23:43 /
touch_rc=0
ln_rc=0
lrwxrwxrwx 1 kunweiz kunweiz 4 Nov 17 23:43 /a0-probe2 -> /tmp
```

没有 ln 错误原文，`ln_rc=0`。再查运行中应用进程的 namespace：

```console
$ ls -ld /proc/1595368/root/a0
lrwxrwxrwx 1 kunweiz kunweiz 62 Nov 17 23:42 /proc/1595368/root/a0 ->
  /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero

$ readlink /proc/1595368/root/a0
/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
```

**结论：P4 是误报，已排除。** `/a0` 在运行中应用进程的 mount namespace 内建立成功，并指向可写数据目录；之前用独立的 `flatpak run --command=sh` 检查看不到它，是因为每次 `flatpak run` 都有自己的 mount namespace，不是 launcher 的 `ln` 失败。

#### C2 宿主 Chrome 在沙盒内能否执行

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c '
    /run/host/root/opt/google/chrome/google-chrome --version 2>&1
    echo chrome_rc=$?
    ldd /run/host/root/opt/google/chrome/google-chrome 2>&1 | grep -c "not found"'
Google Chrome 156.0.8078.79
chrome_rc=0
0
```

实际二进制也验证一次：

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c '
    ls -l /run/host/root/opt/google/chrome/chrome
    /run/host/root/opt/google/chrome/chrome --version 2>&1
    echo chrome_bin_rc=$?
    ldd /run/host/root/opt/google/chrome/chrome 2>&1 | grep -c "not found"'
-rwxr-xr-x 1 nfsnobody nfsnobody 302792008 Oct 29 04:20 .../chrome
Google Chrome 156.0.8078.79
chrome_bin_rc=0
0
```

**结论（二选一）：宿主 Chrome 可执行，正确修复是给 `browser.py` 增加 `/run/host/root/opt/google/chrome/google-chrome` 候选（或实际二进制 `/run/host/root/opt/google/chrome/chrome`），不是放弃宿主 Chrome 去接受 Patchright 下载包。**

依据：wrapper `rc=0`、实际二进制 `rc=0`、两者 `ldd` 缺库数均为 `0`。

#### C3 Patchright 下载的 Chrome 是否可用

```console
$ ls -la "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/tmp/playwright/"
drwxr-xr-x ... chromium-1228
drwxr-xr-x ... ffmpeg-1011

$ "$HOME/.../tmp/playwright/chromium-1228/chrome-linux64/chrome" --version
Google Chrome for Testing 149.0.7827.55
downloaded_chrome_rc=0
```

下载的 Chrome 也能执行，可作为**后备**；但宿主 Chrome 已证明可执行，优先修 `browser.py` 的候选路径。

### 9.4 验证 D：P3 日志

```console
$ find "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero" -maxdepth 4 -name '*.log'
(空)

$ PID=$(pgrep -f 'models/bin/ollama serve' | head -1); echo "OLLAMA_PID=$PID"
OLLAMA_PID=1595381

$ ls -l /proc/1595381/fd/1 /proc/1595381/fd/2
l-wx------ ... /proc/1595381/fd/1 -> .../data/agent-zero/logs/ollama.log (deleted)
l-wx------ ... /proc/1595381/fd/2 -> .../data/agent-zero/logs/ollama.log (deleted)

$ grep -nE 'Removing logs' "$HOME/a0-local-backup/run-p1-234213.log"
3:Removing logs...
```

**结论：P3 确认，仍然丢失。** P1 重启后 Ollama 仍然打开已删除的 `ollama.log`，路径不存在，诊断信息不可读。

### 9.5 验证结果汇总

| 项 | 结论 |
|---|---|
| P1 CSRF/Origin | **根因未确认**。加 `ALLOWED_ORIGINS` 后无 Origin 仍 `ok:false`；带 Referer/Origin 为 `ok:true`。 |
| 设置面板 | **未恢复**。05/06 均空白；CDP 显示 `settingsStore` 存在、modal body 7837 字节，但 `settingsPane=false`、`settingsX=0`；`#welcome-channels` 缺失、299 个 teleport 模板、Alpine `appendChild` 异常。 |
| P4 `/a0` | **误报，已排除**。`ln_rc=0`；`/proc/1595368/root/a0 -> .../data/agent-zero`。 |
| P2 宿主 Chrome | **可执行**：wrapper/实际二进制 `rc=0`、缺库 `0`；应加 `/run/host/root/opt/google/chrome/google-chrome` 候选。 |
| P3 Ollama 日志 | **确认丢失**：`ollama.log (deleted)`，`find` 空。 |

### 9.6 当前 override 完整内容

```console
$ flatpak --user override --show org.agentzero.AgentZero
[Environment]
ALLOWED_ORIGINS=http://127.0.0.1:5080
```

这是本轮为验证 P1 临时添加的 override，未写入仓库，也未改 `.env`。如需撤销：

```sh
flatpak override --user --unset-env=ALLOWED_ORIGINS org.agentzero.AgentZero
```

本轮未执行撤销；保留现状等待下一步指令。

### 9.7 本轮未做

- 未安装 Cuda/WPS。
- 未改 `conf/model_providers.yaml`。
- 未删除 `~/.var/app`。
- 未跑模型推理重负载；只调用 `/api/health`、`/api/csrf_token`、`/api/settings_get` 和浏览器 UI。
