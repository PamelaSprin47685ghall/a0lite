# 本机 v5 回归（a8f9321）

- 执行时间：2026-11-18 00:17–00:27 CST
- 对象：本机 user 安装 `org.agentzero.AgentZero`，branch `master`
- 本轮边界：只安装主包；未安装 Cuda/WPS；未改仓库源码；未删除 `~/.var/app`；临时 override 已用 `--reset` 清空；未跑重负载推理。
- 结果一句话：**核心 UI 修复通过（Settings 恢复、P1/P3/D2 生效），但 verify 6 项只过 5 项，桌面 HTML5 仍是空白，因此整体不能判定为部署通过。**

---

## 1. 安装与 commit

```console
$ cd /home/kunweiz/Desktop/a0lite
$ flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak
Installing app/org.agentzero.AgentZero/x86_64/master
INSTALL_RC=0

$ flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date|Installed Size|Runtime'
Installed Size: 123.7 MB
       Runtime: org.freedesktop.Platform/x86_64/25.08
        Commit: a8f932128c99b0b1a12a42fa1df2856cd2d98781e706abbc6c9e138da079f5ad
          Date: 2026-11-17 15:58:46 +0000
```

旧 commit `169f5e09…` → 新 commit `a8f932128c99…`。重启后 health：

```console
$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
HTTP=200
```

服务进程：

```console
$ flatpak ps
1207100107	1675721	org.agentzero.AgentZero	org.freedesktop.Platform

$ ss -ltnp | grep -E ':(5080|11434|14500)\b'
LISTEN ... 127.0.0.1:11434 ... ole("ollama",pid=1675749,fd=3))
LISTEN ... 127.0.0.1:5080  ... ole("python",pid=1675732,fd=25))
```

---

## 2. verify-ui-fix.sh 六项结果

运行方式（9223 被上一轮 Chrome 占用，使用 9224）：

```console
$ A0_DEBUG_PORT=9224 ~/a0-local-backup/verify-ui-fix.sh a8f9321
```

完整输出：

```text
== verify-ui-fix: expected commit prefix 'a8f9321' ==
   url=http://127.0.0.1:5080  cdp=9224

PASS: a) running commit: a8f932128c99 (matches a8f9321)
PASS: b) /ui/asset-bundle version: df6aa39c7ac2e769f7d9 (differs from old 749c98f1ffe4211405ab)
     first differences:
     Only in /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/components/modals: scheduler
     Only in /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/components/sidebar: tasks
     Only in /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/css: scheduler-datepicker.css
     Only in /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/webui/css: scheduler.css
     note: 'Only in' lines are leftovers in the runtime tree; see report section 8.
FAIL: c c) runtime webui != bundle webui (4 difference lines)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
     {"ok":true,"home":{"channels":1,"teleports":1,"ready":"complete","components":77},"clicked":"clicked","settings":{"modal":true,"pane":1,"textLen":11910,"text":"Settings × search smart_toy Agent Settings expand_more settings Agent Config forum Models mic Voice folder Workdir language Locale dashboard_customize Interface extension Plugins f","settingsLoaded":true},"exceptions":0,"firstException":null,"shot":"/home/kunweiz/a0-shots/verify-ui-fix-settings.png"}
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0833353 sd=0.0976299)

RESULT: FAIL (1/6 failed: c)
```

### 2.1 六项逐条

| 项 | 结果 | 证据 |
|---|---|---|
| a) running commit | **PASS** | `a8f932128c99` 匹配 `a8f9321` |
| b) asset-bundle 版本 | **PASS** | `df6aa39c7ac2e769f7d9`，不同于旧 `749c98f1ffe4211405ab` |
| c) runtime webui == bundle webui | **FAIL** | 4 个 `Only in runtime`：`components/modals/scheduler/`、`components/sidebar/tasks/`、`css/scheduler.css`、`css/scheduler-datepicker.css` |
| d) welcome slot | **PASS** | `#welcome-channels` 计数 1，文件 1015 行（≥1000） |
| e) DOM / Settings | **PASS** | channels=1、teleports=1、pane=1、textLen=11910、settingsLoaded=true、exceptions=0 |
| f) 截图 | **PASS** | `verify-ui-fix-settings.png` 1440×817，mean 0.0833，sd 0.0976 |

### 2.2 c 项差异的性质

```console
$ INSTALL_DIR="$(flatpak --user info --show-location org.agentzero.AgentZero)"
$ BUNDLE_WEBUI="${INSTALL_DIR%/}/files/share/agent-zero/webui"
$ RUNTIME_WEBUI="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/webui"
$ diff -rq "$BUNDLE_WEBUI" "$RUNTIME_WEBUI"
Only in .../runtime/webui/components/modals: scheduler
Only in .../runtime/webui/components/sidebar: tasks
Only in .../runtime/webui/css: scheduler-datepicker.css
Only in .../runtime/webui/css: scheduler.css
```

这些都是**只存在于运行树、镜像里没有**的旧文件，没有出现 `Files ... differ`，说明共享文件已经同步到新版本。它们不是新 `asset-bundle` 的引用目标：

```console
$ curl -sS http://127.0.0.1:5080/ui/asset-bundle | grep -o '"/[^"]*scheduler[^"]*"' | head
"/plugins/_scheduler/webui/sidebar/tasks-store.js"
"/plugins/_scheduler/extensions/webui/get_message_handler/scheduler-handler.js"
"/plugins/_scheduler/webui/css/scheduler.css"
...
```

新 bundle 的 scheduler 资源在 `/plugins/_scheduler/webui/...`；运行树多出来的是旧的 `webui/components/...` 路径，当前 asset-bundle 不引用它们。因此 c 的失败是**旧文件未清理**，不是新旧文件互相覆盖。但它仍然是 6 项中的真实 FAIL，不能写成 6/6。

---

## 3. P1 / P3 / D2 / D1 回归

### 3.1 P1 CSRF / ALLOWED_ORIGINS

先撤销上一轮的临时 override：

```console
$ flatpak override --user --unset-env=ALLOWED_ORIGINS org.agentzero.AgentZero
unset_rc=0

$ flatpak --user override --show org.agentzero.AgentZero
[Context]
unset-environment=ALLOWED_ORIGINS;

[Environment]
ALLOWED_ORIGINS=
```

重启后，应用进程里的默认值：

```console
$ PY=$(pgrep -f 'run_ui.py' | head -1); echo $PY
1675732

$ tr '\0' '\n' < /proc/$PY/environ | grep -E 'ALLOWED_ORIGINS|A0_AUTH_KEY'
ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080
```

**注意**：用户给出的检查命令：

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c 'echo ALLOWED_ORIGINS=$ALLOWED_ORIGINS'
ALLOWED_ORIGINS=
```

这条命令**不经过 `agent-zero.sh` launcher**，所以看不到 launcher 注入的默认值；它不是 P1 回归的有效证据。有效证据是运行中 `run_ui.py` 进程的 environ（上面）以及 Settings 面板实际渲染（下面）。

不带 Origin 的 csrf 仍按预期失败：

```console
$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/csrf_token
{"ok": false, "error": "Origin None not allowed when login is disabled. Set login and password or add your URL to ALLOWED_ORIGINS env variable. Currently allowed origins: "}
HTTP=200
```

设置面板在**全新 Chrome profile** 下恢复；旧 profile 因 service worker/缓存仍显示空白：

| 文件 | 尺寸 | mean | sd | 判读 |
|---|---|---:|---:|---|
| `10-settings-default.png` | 2880×1920 | 0.13985 | 0.254124 | 旧 Chrome profile，仍空白（缓存） |
| `11-settings-default-fresh.png` | 2880×1920 | 0.156329 | 0.264424 | 全新 profile，Settings 有完整内容 |
| `verify-ui-fix-settings.png` | 1440×817 | 0.0833353 | 0.0976299 | 脚本 headless 全新 profile，Settings 有内容 |

视觉判读（11）：左侧 `Agent Settings` 分组（Agent Config、Models、Voice、Workdir、Locale、Interface、Plugins），右侧 `Agent Config`、`Default agent profile` 下拉框、`Models`、`Model preset`、Main/Utility/Embedding 模型行、`Save`/`Cancel` 按钮，均可见。**Settings 面板恢复。**

结论：**P1 默认值在运行中的应用里生效；Settings 恢复。** 旧 profile 的空白是浏览器缓存问题，验收应使用全新 profile 或清 service worker；否则会误判为回归。

### 3.2 P3 Ollama 日志

```console
$ ls -l "$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/ollama.log"
-rw-r--r-- 1 kunweiz kunweiz 99299 Nov 18 00:26 .../data/agent-zero/ollama.log

$ PID=$(pgrep -f 'models/bin/ollama serve' | head -1); echo $PID
1675749

$ readlink /proc/$PID/fd/1
/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/ollama.log

$ tail -5 .../ollama.log
slot   operator(): id  0 | task 0 | cached n_tokens = 0, memory_seq_rm [0, end)
slot      release: id  0 | task 0 | stop processing: n_tokens = 2, truncated = 0
slot prompt_clear: id  0 | task 0 | clearing prompt with 2 tokens
srv  update_slots: all slots are idle
[GIN] 2026/11/18 - 00:18:41 | 200 |    3.38s | 127.0.0.1 | POST "/api/embed"
```

**P3 修复生效**：日志落在 `$DATA_DIR/ollama.log`，不再是 `logs/ollama.log (deleted)`；fd 与实际路径一致，文件可读。

### 3.3 D2 宿主 Chrome

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c '
    B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
    cd /app/share/agent-zero
    GIT_PYTHON_REFRESH=quiet A0_BASE_DIR="$B" \
      PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps \
      "$B/venv/bin/python" -c "import a0flatpak; a0flatpak.apply(); from a0flatpak import browser; print(browser.find_system_chrome())"'
/run/host/root/opt/google/chrome/google-chrome
```

启动日志中不再出现下载：

```console
$ grep -nE 'Downloading Chrome|Chrome for Testing' "$HOME/a0-local-backup/run-v5-clean-002612.log"
(no output)
```

**D2 修复生效**：`browser.py` 的候选路径包含 `/run/host/root/opt/google/chrome/google-chrome`，`find_system_chrome()` 返回该路径，启动不再下载 Chrome for Testing。已下载的旧 Chrome for Testing 仍留在 `data/agent-zero/tmp/playwright/`，只是本版不再触发下载。

### 3.4 D1 Xpra 认证

临时设置 key 并重启：

```console
$ flatpak override --user --env=A0_AUTH_KEY=tmpprobe1 org.agentzero.AgentZero
set_rc=0

$ tr '\0' '\n' < /proc/1671515/environ | grep -E 'A0_AUTH_KEY|ALLOWED_ORIGINS'
ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080
A0_AUTH_KEY=tmpprobe1

$ sh systemd/a0-desktop-start
desktop: True
```

14500 的实际结果（注意启动时序）：

```console
# 桌面刚返回后立即检查：
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
000

# 稍后检查：
$ ss -ltnp | grep 14500
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1671884,fd=7))

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200

$ ps -eo args | grep '[x]pra' | grep -c 'tcp-auth'
1
```

`xpra-cmd.txt` 中：

```text
... /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ... --tcp-auth=env
```

清掉 key 并重启后：

```console
$ flatpak override --user --unset-env=A0_AUTH_KEY org.agentzero.AgentZero
unset_rc=0

$ flatpak --user override --show org.agentzero.AgentZero
[Context]
unset-environment=ALLOWED_ORIGINS;A0_AUTH_KEY;

[Environment]
ALLOWED_ORIGINS=
A0_AUTH_KEY=

$ # 重启后再开桌面
$ ss -ltnp | grep 14500
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1673504,fd=7))

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200

$ ps -eo args | grep '[x]pra' | grep -c 'tcp-auth'
0
```

最后用 `--reset` 清空所有 override：

```console
$ flatpak override --user --reset org.agentzero.AgentZero
reset_rc=0

$ flatpak --user override --show org.agentzero.AgentZero
(空)
```

**D1 结论**：`A0_AUTH_KEY=tmpprobe1` 时 Xpra 命令行有 `--tcp-auth=env`，计数 1；清掉 key 后计数 0。认证开关本身生效。两次 `curl /` 都返回 200，因为 14500 的 HTML 页面本身不受 Xpra TCP 认证保护；真正的协议认证发生在 WebSocket/Xpra 连接层，不能拿 HTTP 200 当“无认证”的证据。桌面页面本身仍失败，见第 4 节。

---

## 4. 桌面 / Xpra 验收

### 4.1 端口与服务

```console
$ ss -ltnp | grep 14500
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1673504,fd=7))

$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200
```

Xpra 日志：

```text
2026-11-18 00:23:37,392 serving html content from '/app/share/xpra/www'
2026-11-18 00:23:37,555 xpra is ready.
2026-11-18 00:23:38,898 New tcp connection received
2026-11-18 00:23:38,898  from '127.0.0.1:52262'
```

### 4.2 截图判读

```console
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' \
    "$HOME/a0-shots/30-desktop.png"
30-desktop.png 2880x1920 mean=0.183127 sd=0.242365
```

视觉判读：浏览器标签 `xpra websockets client`，地址 `127.0.0.1:14500`，页面主体是**整片深蓝空白**；没有 XFCE 壁纸、面板、桌面图标，也没有密码输入框、错误文案或加载动画。带 key 的 `30-desktop-with-key.png`、`31-desktop-key-8s.png` 与无 key 的 `30-desktop.png` 像素统计完全相同（mean 0.183127、sd 0.242365），说明认证开关没有改变“客户端不渲染”的结果。

### 4.3 根因：Xpra HTML5 的 jQuery 资源 404

CDP 抓 14500 页面：

```json
{
  "url": "http://127.0.0.1:14500/",
  "title": "xpra websockets client",
  "ready": "complete",
  "bodyText": "",
  "bodyHTMLLen": 53672,
  "canvases": 0,
  "videos": 0,
  "imgs": 1
}
```

控制台/网络：

```text
http 404 http://127.0.0.1:14500/js/lib/jquery.js
http 404 http://127.0.0.1:14500/js/lib/jquery-ui.js
ReferenceError: $ is not defined
  at http://127.0.0.1:14500/js/lib/jquery-transform-draggable.js:1:1509
ReferenceError: $ is not defined
  at http://127.0.0.1:14500/js/Notifications.js:1:1
ReferenceError: jQuery is not defined
  at http://127.0.0.1:14500/js/lib/slick.js:1:155
```

沙盒内资源是**悬空符号链接**：

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c '
    ls -l /app/share/xpra/www/js/lib/jquery.js
    readlink -f /app/share/xpra/www/js/lib/jquery.js
    test -f "$(readlink -f /app/share/xpra/www/js/lib/jquery.js)" && echo TARGET_PRESENT || echo TARGET_MISSING'
lrwxrwxrwx ... /app/share/xpra/www/js/lib/jquery.js -> /usr/share/javascript/jquery/jquery.js
/usr/share/javascript/jquery/jquery.js
TARGET_MISSING

$ # jquery-ui.js 同样 -> /usr/share/javascript/jquery-ui/jquery-ui.js，TARGET_MISSING
$ # find /usr/share/javascript /app/share -name 'jquery*.js' -> 空
```

Xpra 的 HTML5 包把 jQuery 做成指向 Debian 系统路径的符号链接；Flatpak 运行时没有 `/usr/share/javascript/jquery/`，所以 404，后续脚本全部报 `$ is not defined`，客户端无法连接/渲染。Xpra server 本身是 ready 的，14500 也回 200，但这只是 HTML 外壳，不是桌面。

### 4.4 其他日志

`xpra-stderr.log` 前 30 行包含：

```text
Error: cannot source '/etc/profile', path does not exist
Gtk-Message: Failed to load module "canberra-gtk-module"
Warning: cannot load menu data
 No module named 'xdg'
ignored invalid default encoding option: png
```

这些是警告/降级项，不是空白页的直接原因；直接原因仍是 jQuery 404。

---

## 5. 截图清单

| 文件 | 尺寸 | mean | sd | 判读 |
|---|---|---:|---:|---|
| `10-settings-default.png` | 2880×1920 | 0.13985 | 0.254124 | 旧 Chrome profile，Settings 空白（缓存） |
| `11-settings-default-fresh.png` | 2880×1920 | 0.156329 | 0.264424 | 全新 profile，Settings 内容完整 |
| `verify-ui-fix-settings.png` | 1440×817 | 0.0833353 | 0.0976299 | 脚本 headless，Settings 内容完整 |
| `30-desktop.png` | 2880×1920 | 0.183127 | 0.242365 | 无 key，14500 深蓝空白，无 XFCE |
| `30-desktop-with-key.png` | 2880×1920 | 0.183127 | 0.242365 | 有 key，同样深蓝空白 |
| `31-desktop-key-8s.png` | 2880×1920 | 0.183127 | 0.242365 | 有 key 再等 8 秒，仍空白 |

---

## 6. 发现的问题（按严重度）

### P0（高，阻断桌面验收）Xpra HTML5 的 jQuery/jQuery UI 资源 404，桌面空白

证据：

- `#welcome-channels` / Settings 已恢复，说明 Web UI 本身正常。
- 14500 返回 200，Xpra 日志 `xpra is ready`、`New tcp connection`。
- 浏览器页面 `bodyText=""`、`canvases=0`、`bodyHTMLLen=53672`；控制台 404 `jquery.js`、`jquery-ui.js`，然后 `$ is not defined`/`jQuery is not defined`。
- `/app/share/xpra/www/js/lib/jquery.js -> /usr/share/javascript/jquery/jquery.js`，目标 `TARGET_MISSING`；`jquery-ui.js` 同样；运行时找不到任何 `jquery*.js`。

影响：Desktop / Xpra 功能完全不可用；截图是深蓝空白，不是 XFCE。修复方向：在 xpra 模块里带上 jquery/jquery-ui 实体文件（或在打包时解引用符号链接并复制目标），确保 `/app/share/xpra/www/js/lib/jquery.js` 与 `jquery-ui.js` 可读。

### P1（中）verify c 项失败：运行树残留 4 个旧 scheduler/tasks 文件

证据：

- `diff -rq` 4 行 `Only in runtime`：`components/modals/scheduler/`、`components/sidebar/tasks/`、`css/scheduler.css`、`css/scheduler-datepicker.css`。
- 新 bundle 中这些路径不存在；新 asset-bundle 引用的是 `/plugins/_scheduler/webui/...`，不是这些旧路径。
- 共享文件没有 `Files ... differ`。

影响：当前功能未观察到异常（DOM exceptions=0，Settings/Scheduler 走新插件路径），但运行树不等于镜像，6 项验收只能 5/6；如果以后有代码按旧路径加载，会拿到过期文件。修复方向：seed/merge 时清理镜像已删除的旧路径，或做一次显式的 runtime webui 迁移。

### P2（中）桌面启动存在“返回 True 但 14500 尚未监听”的时序窗口

证据：

- `a0-desktop-start` 输出 `desktop: True` 后立即 `curl 14500` 得到 `000`；稍后同一端口 `200`。
- 两次后台任务（bg_328/bg_331）都在 `desktop: True` 后马上检查到 `000`，需要再等一段时间才可用。

影响：调用方若把 `desktop: True` 当成“端口已就绪”会误判失败；`ensure_system_desktop()` 的返回语义与端口 ready 不一致。修复方向：返回前等待 14500 可连接，或把“available=true / port_ready=false”拆成两个状态。

### P3（中低）旧 Chrome profile 继续显示空白 Settings（缓存）

证据：

- `10-settings-default.png`（旧 profile）空白；`11-settings-default-fresh.png`（全新 profile）内容完整；`verify-ui-fix-settings.sh` 也是全新 profile PASS。
- 旧 profile 的 service worker/asset 缓存没有随新 asset-bundle 更新。

影响：升级后如果用户不硬刷新/不清缓存，会误以为修复没生效。修复方向：给 asset-bundle/service worker 做版本化失效，或在验收流程中要求全新 profile。

### P4（低）`/api/health` 200 但 body 含 `error` 字段

```json
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
```

影响：只看 HTTP 200 会认为完全健康；解析 body 的调用方会误判。需要确认该字段是否预期（可能是 gitinfo fallback）。

### P5（低）verify 脚本清理临时 profile 时报 `Directory not empty`

```text
rm: cannot remove '/tmp/a0-verify-chrome.iWVOYQ/Default': Directory not empty
```

不影响 6 项判定（脚本已先算出结果），但说明 headless Chrome 退出后仍有子进程/文件占用；可在 `kill` 后等待或加 `--disable-background-networking`。属于测试脚本卫生问题。

### 已确认修复 / 已排除

- P1：launcher 默认 `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080` 在运行中的 `run_ui.py` environ 里生效；Settings 在全新 profile 下有内容。注意 `flatpak run --command=sh` 看不到该值，是因为它绕过 launcher。
- P3：`ollama.log` 落在 `data/agent-zero/ollama.log`，fd 与路径一致，未删除。
- D2：`find_system_chrome()` 返回 `/run/host/root/opt/google/chrome/google-chrome`，启动日志不再下载 Chrome for Testing。
- D1：临时 key 时 `--tcp-auth=env` 计数 1；清 key 后 0；认证开关生效。
- `/a0`：运行进程 namespace 内存在，上一轮“未建立”是误报。

---

## 7. 这一版是否可以判定为部署通过

**不能判定为部署通过。**

理由：

1. **verify 6 项只过 5 项**：c 项明确 FAIL（4 个运行树残留文件）。即使这些文件当前未被 asset-bundle 引用，验收脚本的“运行树 == 镜像”条件没有满足，不能写成 6/6。
2. **桌面分类 H 是硬失败**：14500 返回 200、Xpra `ready`，但 HTML5 客户端因 jQuery/jQuery UI 404 无法渲染，截图是深蓝空白，不是 XFCE 桌面。桌面是验收范围的一部分，不能用“端口 200”代替。
3. 其他项通过（commit、asset-bundle、welcome slot、DOM Settings、截图；P1/P3/D2/D1 生效）只能说明 **Web UI 的核心修复通过**，不能抵消桌面失败和 c 项失败。

如果验收范围被明确缩小为“仅 Settings/Projects 空白修复”，则这一部分可以判通过；但按本轮的完整回归口径（含 verify 6/6 与桌面 H），结论是**不通过**。需要下一版修复 Xpra jQuery 资源和运行树清理，再重跑 verify + 桌面截图。

---

## 附：当前运行状态

```console
$ flatpak --user info org.agentzero.AgentZero | grep Commit
        Commit: a8f932128c99b0b1a12a42fa1df2856cd2d98781e706abbc6c9e138da079f5ad

$ flatpak ps
1207100107	1675721	org.agentzero.AgentZero	org.freedesktop.Platform

$ flatpak --user override --show org.agentzero.AgentZero
(空)
```

- 应用仍在运行，health 200。
- 未安装 Cuda/WPS；未改 `conf/model_providers.yaml`；未删除 `~/.var/app`。
- 临时 `ALLOWED_ORIGINS` / `A0_AUTH_KEY` override 已通过 `--reset` 清空。
- 桌面 Xpra 当前仍在 14500（无 key）；下一次重启会随之退出。

---

## v6 回归（1e0f41cc）

- 版本：`org.agentzero.AgentZero` / `master`
- commit：`1e0f41ccecb4e9893d117a8b68ee5c4b8c870964e9b36716efdcbc7fec652eef`（前缀 `1e0f41cc`）
- bundle：`bundles/agent-zero.flatpak`，59,709,032 字节，sha256 `62e6228d29048381ba07a6ccf1a119274c199504a6f158ef848f72b8d1025bed`
- 安装时间：2026-11-18 00:34 CST；安装大小 124.6 MB
- 本轮边界：只装主包；未装 Cuda/WPS；未改仓库源码；临时 override 已 `--reset` 清空；OCR 图放在 `~/a0-shots/`。

### 1. 安装与启动

```console
$ flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak
Installing app/org.agentzero.AgentZero/x86_64/master
INSTALL_RC=0

$ flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date|Installed Size'
Installed Size: 124.6 MB
        Commit: 1e0f41ccecb4e9893d117a8b68ee5c4b8c870964e9b36716efdcbc7fec652eef
          Date: 2026-11-17 16:32:42 +0000

$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
HTTP=200
```

### 2. verify-ui-fix.sh：6/6 PASS

```text
== verify-ui-fix: expected commit prefix '1e0f41c' ==
   url=http://127.0.0.1:5080  cdp=9224

PASS: a) running commit: 1e0f41ccecb4 (matches 1e0f41c)
PASS: b) /ui/asset-bundle version: ae3afc9972a0d8443219 (differs from old 749c98f1ffe4211405ab)
PASS: c) runtime webui == bundle webui (0 differences)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
     {"ok":true,"home":{"channels":1,"teleports":1,"ready":"complete","components":77},"clicked":"clicked","settings":{"modal":true,"pane":1,"textLen":11910,"text":"Settings × search smart_toy Agent Settings expand_more settings Agent Config forum Models mic Voice folder Workdir language Locale dashboard_customize Interface extension Plugins f","settingsLoaded":true},"exceptions":0,"firstException":null,"shot":"/home/kunweiz/a0-shots/verify-ui-fix-settings.png"}
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0833337 sd=0.0976295)

RESULT: PASS (6/6)
```

**结论：verify 6/6 通过。** c 项已经 0 differences，上一版 4 个 scheduler/tasks 废弃路径已清理。

### 3. 桌面 / Xpra（v6 重点）

#### 3.1 jQuery 已实体化

```console
$ flatpak run --user --command=sh org.agentzero.AgentZero -c \
    'ls -l /app/share/xpra/www/js/lib/jquery.js; head -c 60 /app/share/xpra/www/js/lib/jquery.js'
-rw-r--r-- 2 kunweiz kunweiz 285284 Jan  1  1970 /app/share/xpra/www/js/lib/jquery.js
/*!
 * jQuery JavaScript Library v3.7.1
 * https://jquery.co

$ curl -sS -o /dev/null -w 'http=%{http_code} size=%{size_download} type=%{content_type}\n' \
    http://127.0.0.1:14500/js/lib/jquery.js
http=200 size=285284 type=text/javascript

$ curl -sS http://127.0.0.1:14500/js/lib/jquery.js | head -c 60
/*!
 * jQuery JavaScript Library v3.7.1
 * https://jquery.c
```

jquery-ui 同样是实体文件：

```console
-rw-r--r-- 2 kunweiz kunweiz 540438 Jan  1  1970 /app/share/xpra/www/js/lib/jquery-ui.js
/*! jQuery UI - v1.14.2 - 2026-07-16
```

**判定：jQuery 修复通过。** 不再是悬空符号链接；HTTP 200，内容以 `/*!` 开头，`text/javascript`。

#### 3.2 桌面截图与 CDP

```console
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' \
    "$HOME/a0-shots/40-desktop-v6.png"
40-desktop-v6.png 2880x1920 mean=0.922313 sd=0.250221
```

视觉判读：这是 **Xpra HTML5 Client 的错误页**，不是 XFCE 桌面。页面标题 `Xpra HTML5 Client`，正文：

```text
Xpra HTML5 Client
Version 21

You were disconnected for the following reason:

connection errorerror accepting new connection

http://127.0.0.1:14500/ is a 'X11 shadow' server
Username  Password
Connect Client URI Connection File
```

CDP：

```json
{
  "url": "http://127.0.0.1:14500/connect.html",
  "title": "Xpra HTML5 Client",
  "ready": "complete",
  "bodyText": "Xpra HTML5 Client\nVersion 21\n\nYou were disconnected for the following reason:\n\nconnection errorerror accepting new connection\n...",
  "canvases": 0,
  "videos": 0,
  "imgs": 6
}
```

控制台/网络 issue 计数：`Runtime.exceptionThrown` = **0**；404 只有：

```text
404 http://127.0.0.1:14500/default-settings.txt
```

jQuery/jQuery UI **不再 404**。所以上一版的 jQuery 空白原因已消除，但桌面仍未渲染。

#### 3.3 Xpra 服务端实际错误

`xpra-stderr.log` tail：

```text
2026-11-18 00:40:33,805 New tcp connection received
2026-11-18 00:40:40,810 server error processing new connection from WebSocket(...):
  No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
Traceback (most recent call last):
  File "/app/share/python-deps/xpra/server/core.py", line 1459, in call_hello_oked
  ...
  File "/app/share/python-deps/xpra/server/source/image_filter.py", line 13, in <module>
    from xpra.server.window.compress import WindowSource, free_image_wrapper
  File "/app/share/python-deps/xpra/server/window/compress.py", line 24, in <module>
    from xpra.net.mmap.common import MmapPointerError
ModuleNotFoundError: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
2026-11-18 00:40:40,814 Disconnecting client:
  connection error (error accepting new connection)
```

这不是 jQuery 问题；是 Xpra 服务端在客户端握手阶段导入 `xpra.net.mmap.common` 失败。14500 端口和 HTML5 外壳都正常，但客户端连接被服务端断开。

补充诊断：单独在 venv 里 `import xpra.net.mmap.common` 是成功的（payload 与 venv 都有 `__init__.py`、`common.py`），`from gi.repository import Gtk` 在带 `LD_LIBRARY_PATH=/app/lib/gi` 时也成功；但实际 Xpra server 进程在握手时仍报上述 `not a package`。这说明问题在 **Xpra 服务端进程的模块解析/环境**，不是 jQuery 资源缺失。

**结论：桌面仍不可用；没有看到 XFCE 壁纸/面板/图标。**

### 4. OCR（D4）

#### 4.1 探针图

```console
$ fc-match -f '%{file}\n' 'Noto Sans CJK SC'
/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc

$ convert -size 1200x400 xc:white -font /usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc \
    -pointsize 48 -fill black \
    -annotate +40+120 'Agent Zero OCR 测试 2026' \
    -annotate +40+220 '第二行文字，用于验证视觉解析。' \
    "$HOME/a0-shots/ocr-probe.png"
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' ...
ocr-probe.png 1200x400 mean=0.970145 sd=0.162874
```

#### 4.2 正常路径

```console
$ # 在应用 venv 中调用 a0flatpak.ocr._vision_markdown
TYPE str LEN 39 SECONDS 3.61
HEAD 'Agent Zero OCR 测试 2026\n\n第二行文字，用于验证视觉解析。'
ASSERT True
```

**OCR 可用**：3.61 秒返回非空 Markdown，内容同时包含 `Agent Zero` 与 `OCR`，与探针图文字一致。

#### 4.3 超时路径

```console
$ # A0_OCR_TIMEOUT=1，模型已热
OCR_TIMEOUT 1.0
RETURN str LEN 39 SECONDS 0.65
TEXT 'Agent Zero OCR 测试 2026\n\n第二行文字，用于验证视觉解析。'
```

1 秒没有触发超时（模型已热，0.65 秒返回）。强制更小超时：

```console
$ # A0_OCR_TIMEOUT=0.01，直接 _vision_markdown
OCR_TIMEOUT 0.01
EXCEPTION ReadTimeout SECONDS 0.02 timed out

$ # 同一超时下走 _parse_image 包装
EXCEPTION ValueError SECONDS 0.01 OCR failed within 0s: ReadTimeout: timed out
```

结论：

- 默认 45 秒预算工作正常；正常 OCR 3.61 秒完成。
- `_vision_markdown` 本身在超时时抛 `ReadTimeout`（未捕获）；`_parse_image` 把它包装成可读的 `ValueError: OCR failed within 0s: ReadTimeout: timed out`。后者**可读，但仍然是异常**，不是返回一段“截断/超时文本”。
- 若验收要求“超时返回可读字符串而不是异常”，还需要在 `_parse_image` 或上层再包一层返回 `"> OCR timed out ..."`；当前版本没有做到这一点。

### 5. P1 / P3 / D2 / D1 快速回归

| 项 | 命令 | 结果 |
|---|---|---|
| P1 | 运行中 `run_ui.py` environ | `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080`；默认值生效 |
| P3 | `ls -l .../data/agent-zero/ollama.log`；`readlink /proc/<ollama>/fd/1` | 147,751 字节；fd 指向同一未删除路径 |
| D2 | `browser.find_system_chrome()` | `/run/host/root/opt/google/chrome/google-chrome`；启动日志无 Chrome 下载 |
| D1 | 临时 key 后 xpra 命令行 `tcp-auth` 计数 | 1；清 key 后 0；两次 `/` 都是 200 |

D1 的 `curl /` 200 仍不代表无认证：HTML 页面本身不受 Xpra TCP 认证保护；关键是命令行 `--tcp-auth=env` 存在。

临时 override 已用 `flatpak override --user --reset org.agentzero.AgentZero` 清空；最终 `--show` 为空，应用 environ 仍是默认回环对。

### 6. 结论

| 项 | 结果 |
|---|---|
| commit | **1e0f41cc**，安装成功 |
| verify-ui-fix | **6/6 PASS** |
| jQuery | **通过**：实体文件 285,284 字节，HTTP 200，`/*!` 开头；jquery-ui 540,438 字节 |
| Settings / Projects | **通过**：DOM pane=1、textLen=11910、settingsLoaded=true、exceptions=0 |
| 桌面 Xpra | **不通过**：14500/HTTP 200，但客户端报 `connection error`；canvases=0；服务端 `xpra.net.mmap.common` 导入失败；没有 XFCE |
| OCR 正常路径 | **通过**：3.61 秒，内容正确 |
| OCR 超时路径 | **部分通过**：超时异常可读（`_parse_image` 包装），但不是返回字符串；`_vision_markdown` 仍抛原始 `ReadTimeout` |
| P1/P3/D2/D1 | **通过**（D1 以命令行 tcp-auth 为准） |

**最终部署判定：不能判定为部署通过。**

理由：verify 6/6、Settings、jQuery、OCR 正常路径、P1/P3/D2/D1 都通过；但 **桌面 H 仍然硬失败**——Xpra 客户端连不上，服务端在握手中导入 `xpra.net.mmap.common` 失败，截图是连接错误页而不是 XFCE。加上 OCR 超时路径仍以异常而非可读文本返回，这两项未达到“完整部署通过”的标准。

如果验收范围只限 Web UI 修复（Settings/Projects）与 verify 6/6，则这一版可以通过；但按本轮要求的桌面验收 + OCR 超时行为，结论是**不通过**。

---

## v7 回归（1ddcd34f）

- commit：`1ddcd34f7b351eab88be1d14789c27f400c3b04d3e2611d6e8d01f03d237075b`（前缀 `1ddcd34f`）
- bundle：59,711,152 字节，sha256 `29d7510f9aa1fb5be89f00f426f5577171f72995ab6cfa1c67f80b8eca84def2`
- 安装：`flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak`，INSTALL_RC=0，Installed Size 124.6 MB
- 边界：只装主包；未装 Cuda/WPS；未改源码；临时 override 已 `--reset` 清空。

### 1. venv 戳（桌面关键）

```console
$ V=~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv
$ S=$(ls -d "$V"/lib/python3.14/site-packages)
$ cat "$S/.a0-python-deps"; echo
315e2a61fcaa940b491fc7beab6cc6e9b391c1e97508957d259cdf0211e13a0d

$ ls -ld "$S/xpra/net/mmap" "$S/xpra/net/mmap.py" 2>&1
drwxr-xr-x ... "$S/xpra/net/mmap"
ls: cannot access '.../xpra/net/mmap.py': No such file or directory
```

**判定：戳等于期望值，xpra/net/mmap 是目录，mmap.py 不存在。venv 刷新机制按设计生效。**

### 2. verify-ui-fix：6/6 PASS

```text
PASS: a) running commit: 1ddcd34f7b35 (matches 1ddcd34f)
PASS: b) /ui/asset-bundle version: cedc82c6f6450bc98547 (differs from old 749c98f1ffe4211405ab)
PASS: c) runtime webui == bundle webui (0 differences)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
     {"ok":true,"home":{"channels":1,"teleports":1,"ready":"complete","components":77},"clicked":"clicked","settings":{"modal":true,"pane":1,"textLen":11910,"text":"Settings × search smart_toy Agent Settings expand_more settings Agent Config forum Models mic Voice folder Workdir language Locale dashboard_customize Interface extension Plugins f","settingsLoaded":true},"exceptions":0,"firstException":null,"shot":"/home/kunweiz/a0-shots/verify-ui-fix-settings.png"}
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0833355 sd=0.0976152)

RESULT: PASS (6/6)
```

### 3. 桌面

jQuery / default-settings：

```console
$ curl ... /js/lib/jquery.js
jquery=200 285284
/*!
 * jQuery JavaScript Library v3.7.1

$ curl ... /default-settings.txt
default_settings=200 283
# Xpra HTML5 default settings
```

14500 启动：

```console
$ ss -ltnp | grep 14500
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1694786,fd=7))
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200
```

截图：

```console
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' ~/a0-shots/50-desktop-v7.png
50-desktop-v7.png 2880x1920 mean=0.922313 sd=0.250221
```

视觉判读：**仍是 Xpra HTML5 Client 的 `connection error` 页，不是 XFCE 桌面**；没有壁纸、面板、桌面图标。

CDP：

```json
{
  "url": "http://127.0.0.1:14500/connect.html",
  "title": "Xpra HTML5 Client",
  "bodyText": "Xpra HTML5 Client\nVersion 21\n\nYou were disconnected for the following reason:\n\nconnection errorerror accepting new connection\n...",
  "canvases": 0,
  "videos": 0
}
```

`Runtime.exceptionThrown` = 0；剩下的 404 只有 `default-settings.txt`（浏览器侧旧请求；curl 已是 200）。jQuery 不再 404。

`xpra-stderr.log` tail 仍报：

```text
server error processing new connection from WebSocket(...):
  No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
  ...
  File "/app/share/python-deps/xpra/server/source/image_filter.py", line 13
    from xpra.server.window.compress import WindowSource, free_image_wrapper
  File "/app/share/python-deps/xpra/server/window/compress.py", line 24
    from xpra.net.mmap.common import MmapPointerError
ModuleNotFoundError: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
```

**判定：桌面仍不可用。venv 戳正确但 xpra server 的模块解析问题没有消失。**

补充：在独立 venv 进程里 `import xpra.net.mmap.common` 成功；`from gi.repository import Gtk` 带 `LD_LIBRARY_PATH=/app/lib/gi` 也成功；但实际 Xpra server 进程在握手时仍失败，说明问题在 server 进程的模块状态/加载路径，而不是 venv 里的文件缺失。

### 4. OCR 正负两路

正路：

```console
TYPE str LEN 39 SECONDS 3.5
HEAD 'Agent Zero OCR 测试 2026\n\n第二行文字，用于验证视觉解析。'
```

负路（子进程 `A0_OCR_TIMEOUT=0.01`，不使用全局 override）：

```console
OCR_TIMEOUT 0.01
vision EXCEPTION ReadTimeout SECONDS 0.01 timed out
parse_image RETURN str LEN 91 SECONDS 0.02
parse_image HEAD '> OCR incomplete: the vision request did not finish within 0s. The image was not converted.'
```

**结论：**

- **`_parse_image` 的负路符合 v7 目标**：返回以 `> OCR incomplete:` 开头的可读 Markdown，不再抛 ValueError。
- **`_vision_markdown` 本身仍抛 `ReadTimeout`**；如果验收入口是底层 `_vision_markdown`，负路仍是异常；如果入口是解析器 `_parse_image`，则通过。报告中必须写清这个入口差异。

### 5. 四条快速回归

| 项 | 结果 |
|---|---|
| P1 | 运行中 `run_ui.py` environ = `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080` |
| P3 | `data/agent-zero/ollama.log` 未删除，fd 与路径一致 |
| D2 | `find_system_chrome()` = `/run/host/root/opt/google/chrome/google-chrome`，启动无 Chrome 下载 |
| D1 | v7 临时 key 时 xpra `tcp-auth` 计数 1；清 key 后 0 |

临时 override 已 `--reset` 清空；最终 `--show` 为空，P1 默认回环对仍在运行进程 environ 中。

### 6. 结论

| 项 | 结果 |
|---|---|
| commit | **1ddcd34f**，安装成功 |
| venv 戳 / xpra 文件 | **通过**：戳匹配；`xpra/net/mmap` 目录；无 `mmap.py` |
| verify-ui-fix | **6/6 PASS** |
| jQuery / default-settings | **通过**：jquery 200 `/*!`；default-settings 200 |
| 桌面 XFCE | **不通过**：14500 200，但连接被 Xpra server 断开；`xpra.net.mmap.common` 仍报 not a package；截图是错误页 |
| OCR 正路 | **通过**：3.5 秒，内容正确 |
| OCR 负路 | **`_parse_image` 通过**（返回 `> OCR incomplete:`）；`_vision_markdown` 仍抛 `ReadTimeout`，取决于入口 |
| P1/P3/D2/D1 | **通过** |

**最终部署判定：不能判定为部署通过。**

理由：verify 6/6、venv 戳、Settings、jQuery、OCR 正路、P1/P3/D2/D1 都通过；但 **桌面 H 仍然硬失败**——Xpra server 在客户端握手时仍报 `xpra.net.mmap.common` not a package，截图为连接错误页而不是 XFCE。这是本轮的核心验收项，不能用 14500 返回 200 代替。

如果验收范围只限 Web UI（Settings/Projects）与 verify 6/6，这一版可通过；按完整部署口径（含桌面），结论是**不通过**。OCR 负路则需要在验收口径中明确入口：`_parse_image` 通过，`_vision_markdown` 未通过。

---

## v7 桌面：connect.html 假设验证

- 验证时间：2026-11-18 01:01–01:06 CST
- 目的：确认桌面空白是“URL 缺 `submit` 参数”还是“Xpra 服务端仍在拒绝连接”。
- 边界：未改仓库源码；未 kill 5080 实例；临时 Chrome 使用独立 profile（chrome-desktop-a / a2 / b）。

### A. 裸 URL 确实停在 connect.html

启动桌面（记录时间）：

```console
$ date '+%H:%M:%S'
01:01:51
$ timeout 60 sh ~/Desktop/a0lite/systemd/a0-desktop-start
desktop: True
desktop_rc=0
$ date '+%H:%M:%S'
01:02:51
$ ss -ltnp | grep 14500
(空)
```

随后用持久方式重新启动（避免 timeout 杀掉 Xpra）：

```console
$ setsid sh ~/Desktop/a0lite/systemd/a0-desktop-start ... &
$ # 8 秒后
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1705060,fd=7))
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200
```

裸 URL：

```console
$ google-chrome --user-data-dir=$HOME/a0-shots/chrome-desktop-a2 ... http://127.0.0.1:14500/
$ # CDP
{"href":"http://127.0.0.1:14500/connect.html","path":"/connect.html","title":"Xpra HTML5 Client","canvases":0,"buttons":[],"body":"Xpra HTML5 Client\nVersion 21\n\nYou were disconnected ... connection errorerror accepting new connection ..."}
EXCEPTIONS 0
```

截图：

```console
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' ~/a0-shots/60-desktop-bare.png
60-desktop-bare.png 2880x1800 mean=0.929965 sd=0.244612
```

视觉判读：Xpra HTML5 Client 连接页，有 `Connect`/`Client URI`/`Connection File` 按钮，没有 XFCE。

**A 结论：裸 URL 确实被重定向到 `/connect.html`，`canvases=0`。**

### B. `?submit=true` 仍无法进入桌面

```console
$ google-chrome --user-data-dir=$HOME/a0-shots/chrome-desktop-b ... 'http://127.0.0.1:14500/?submit=true'
$ sleep 12
$ import -window "$WID" ~/a0-shots/61-desktop-submit.png
61-desktop-submit.png 2880x1800 mean=0.918496 sd=0.255173
```

视觉判读：**仍然是 connect.html 错误页**，不是 XFCE；页面上仍显示：

```text
Xpra HTML5 Client
Version 21
You were disconnected for the following reason:
connection errorerror accepting new connection
```

CDP（同一入口，B 页面）：

```json
{"href":"http://127.0.0.1:14500/connect.html","path":"/connect.html","title":"Xpra HTML5 Client","canvases":0,"buttons":[],"body":"...connection errorerror accepting new connection..."}
```

`Runtime.exceptionThrown` = 0。

**B 结论：`?submit=true` 没有直接进桌面，仍然落到 connect.html。URL 缺 submit 是存在的现象，但不是本机桌面空白的根因。**

### C. 日志新鲜度：`is not a package` 是本次启动后写入的

最新会话日志：

```console
$ LOG=.../profiles/agent-zero-desktop/xpra-stderr.log
$ stat -c 'mtime=%y size=%s' "$LOG"
mtime=2026-11-18 01:04:56.984481653 +0800 size=8259

$ ps -o pid,lstart,args -p 1705060
1705060 Wed Nov 18 01:04:16 2026 ... /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ...
```

日志中的错误发生在 **01:04:19、01:04:27、01:04:56**，都晚于进程启动时间 01:04:16：

```text
2026-11-18 01:04:19,621 server error ... No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
2026-11-18 01:04:27,372 server error ... No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
2026-11-18 01:04:56,454 server error ... No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
```

完整 traceback（节选）：

```text
File "/app/share/python-deps/xpra/server/source/image_filter.py", line 13
  from xpra.server.window.compress import WindowSource, free_image_wrapper
File "/app/share/python-deps/xpra/server/window/compress.py", line 24
  from xpra.net.mmap.common import MmapPointerError
ModuleNotFoundError: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
```

**C 结论：日志 mtime 01:04:56，晚于 Xpra 启动 01:04:16；`is not a package` 不是旧日志残留，确实是本次启动后写入的。fix-xpra 的“旧 venv 残留/日志被覆盖”假设在本机不成立。**

### D. URL 应该怎么拼

代码证据：

- `index.html` 在没有 `submit` 参数时，`callback_close` 直接 `window.location = "connect.html"`；带 `submit` 才进入正常关闭/错误处理。
- `connect.html` 的 `doConnect()`：

```js
let url = "./index.html" + add_prop("submit", true, true);
let i = 0;
for (const [prop, value] of get_URL_action()) {
    add_prop(prop, value, i == 0);
    i++;
}
```

即按钮会拼成 `./index.html?submit=true`，并把连接表单的 action 参数带过去。

- 密码参数：`connect.html` 的 `doConnectURI()` 明确从 `#password` 读取；`is_password_safe()` 在非安全上下文中会禁用密码输入（`password_input.disabled = true`）。因此**仅在 HTTPS 或 `insecure` 勾选时**才可能把 `password=` 放进 URL；本机是 `http://127.0.0.1`，`is_password_safe()` 为 false，密码输入默认被禁用。

**URL 结论：**

- 无 `A0_AUTH_KEY` 时，正确的桌面入口至少应是：
  ```text
  http://127.0.0.1:14500/?submit=true
  ```
  但仍需 Xpra server 接受连接；本机当前 server 仍拒绝，所以这条 URL 也停在 connect.html。
- 有 `A0_AUTH_KEY` 时，不能简单在 URL 上拼 `password=`；本机 HTTP 非安全上下文会禁用密码输入。正确做法是通过 `connect.html` 表单的 `Connect` 按钮（或 `xpra+ws://` URI），并让 Xpra 的 `--tcp-auth=env` 读取 `XPRA_PASSWORD`；如果必须用 URL，需要先确认 `submit=true` 且密码输入未被安全策略禁用，否则 `password=` 不会被 `doConnect()` 写入。
- 在桌面 URL 生成层，`a0flatpak/desktop.py` 应把 `virtual_desktop.session_url()` 的返回值补上 `?submit=true`（或让 UI 使用 `connect.html` 的 Connect 按钮）；但**这只是必要条件，不是当前空白的充分修复**。

### E. 最终判断

- 裸 URL：**停在 `/connect.html`，canvases=0**。
- `?submit=true`：**仍停在 `/connect.html`，canvases=0**；截图 61 的 sd=0.255173，仍是错误页。
- `is not a package`：**仍出现在新日志**（mtime 01:04:56，晚于启动 01:04:16）。
- 根因：**不是“URL 缺 submit”单点**；Xpra server 仍在客户端握手阶段抛 `xpra.net.mmap.common is not a package`，连接在进入桌面协议前就断了。URL 缺 submit 是第二个问题（裸 URL 不会自动连接），但修 URL 不能绕过 server 拒绝。
- 后续正确顺序：先修/绕开 Xpra server 的 `xpra.net.mmap` 导入问题，再用 `?submit=true`（或 Connect 按钮）验证 XFCE；否则无论裸 URL 还是 submit URL 都会回到 connect.html。

---

## v7 桌面：mmap 导入矛盾定案

- 时间：2026-11-18 01:06–01:09 CST
- 对象：运行中的 Xpra shadow server（PID 1705060，01:04:16 启动，日志 mtime 01:04:56）
- 目标：解释“沙盒 import 成功、server 仍报 not a package”的矛盾，并找到最小修复。

### 1. 运行中 xpra 进程的完整环境

```console
$ XPID=$(pgrep -f '/app/bin/xpra shadow' | head -1); echo $XPID
1705060

$ tr '\0' '\n' < /proc/$XPID/environ | sort > ~/a0-local-backup/xpra-environ.txt
$ cat ...
A0_BASE_DIR=/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero
DISPLAY=:0.0
GDK_SCALE=2
GI_TYPELIB_PATH=/app/lib/girepository-1.0
LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
PYTHONHOME=
PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
PYTHONUSERBASE=/var/data/python
XAUTHORITY=/run/flatpak/Xauthority
...
$ tr '\0' ' ' < /proc/$XPID/cmdline
... /venv/bin/python /app/bin/xpra shadow :0 ... --mmap=no --html=on ... --bind-tcp=127.0.0.1:14500 ...

$ readlink /proc/$XPID/exe
.../data/uv/python/cpython-3.14.10-linux-x86_64-gnu/bin/python3.14
$ readlink /proc/$XPID/cwd
/app/share/agent-zero
```

关键环境：`PYTHONHOME=`（空）、`PYTHONUSERBASE=/var/data/python`、`PYTHONPATH` 顺序为 agent-zero、agent-zero/flatpak、python-deps。

### 2. 四个 combo 的 import 结果

```console
PATH_ONLY        -> 6.5.5 /app/share/python-deps/xpra/__init__.py /app/share/python-deps/xpra/net/mmap/__init__.py
PLUS_HOME_EMPTY  -> 6.5.5 /app/share/python-deps/xpra/__init__.py /app/share/python-deps/xpra/net/mmap/__init__.py
VENV_FIRST       -> 6.5.5 .../venv/lib/python3.14/site-packages/xpra/__init__.py .../venv/.../xpra/net/mmap/__init__.py
BUNDLE_FIRST     -> 6.5.5 /app/share/python-deps/xpra/__init__.py /app/share/python-deps/xpra/net/mmap/__init__.py
```

四个 combo **全部成功**，没有 `not a package`。

完整环境复现（显式带上 `PYTHONHOME=`、`PYTHONUSERBASE`、`LD_LIBRARY_PATH`）也成功：

```text
xpra /app/share/python-deps/xpra/__init__.py
net /app/share/python-deps/xpra/net/__init__.py ['/app/share/python-deps/xpra/net']
mmap /app/share/python-deps/xpra/net/mmap/__init__.py ['/app/share/python-deps/xpra/net/mmap']
common OK
```

### 3. sys.path 与 find mmap.py

```console
$ PYTHONPATH=/app/share/python-deps PYTHONHOME= venv/bin/python -c 'import sys; print(...)'
(空)
/app/share/python-deps
.../uv/python/cpython-3.14.10/lib/python314.zip
.../uv/python/cpython-3.14.10/lib/python3.14
.../uv/python/cpython-3.14.10/lib/python3.14/lib-dynload
.../venv/lib/python3.14/site-packages
```

```console
$ find /app/share/python-deps/xpra /app/share/xpra -maxdepth 4 -name 'mmap*'
/app/share/python-deps/xpra/net/mmap d 70
/app/share/python-deps/xpra/server/source/mmap.py f 7823
/app/share/python-deps/xpra/server/subsystem/mmap.py f 1125

$ find .../venv -path '*xpra*' -name 'mmap*'
.../venv/lib/python3.14/site-packages/xpra/net/mmap d 92
.../venv/lib/python3.14/site-packages/xpra/server/source/mmap.py f 7823
.../venv/lib/python3.14/site-packages/xpra/server/subsystem/mmap.py f 1125
```

**没有 `xpra/net/mmap.py`**，只有目录包。`PYTHONUSERBASE=/var/data/python` 在沙盒里不存在。

### 4. 完整 traceback

```console
$ LOG=~/.var/app/.../profiles/agent-zero-desktop/xpra-stderr.log
$ stat -c '%y %s' "$LOG"
2026-11-18 01:04:56.984481653 +0800 8259

$ ps -o pid,lstart,args -p 1705060
1705060 Wed Nov 18 01:04:16 2026 ... /app/bin/xpra shadow :0 ... --mmap=no ...

$ grep -n 'is not a package' "$LOG"
43: 2026-11-18 01:04:19,621 ... No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
68: 2026-11-18 01:04:27,372 ... 同
96: 2026-11-18 01:04:56,454 ... 同
```

traceback 的调用方：

```text
core.py:1459 call_hello_oked
 -> base.py:217 hello_oked
 -> base.py:238 get_client_connection_class
 -> source/factory.py:115 get_client_connection_class
 -> source/factory.py:104 get_needed_based_classes
 -> source/factory.py:86 get_enabled_mixins
 -> source/image_filter.py:13
      from xpra.server.window.compress import WindowSource, free_image_wrapper
 -> server/window/compress.py:24
      from xpra.net.mmap.common import MmapPointerError
ModuleNotFoundError: No module named 'xpra.net.mmap.common'; 'xpra.net.mmap' is not a package
```

**关键事实：** 这是 server 处理客户端 hello 时才触发的导入；同一个 Xpra 进程启动时并没有打印 `xpra.__file__`。错误发生在 `image_filter` 的 import 链，不是 HTML5 的 jQuery，也不是 URL。

### 5. 决定性实验：不加 `--mmap=no` 启动第二个 Xpra

这是本轮找到的可复现差异：

```console
$ # 停掉旧桌面 Xpra，用相同 env 在 14602 启动，但去掉 --mmap=no
$ setsid flatpak run --user --command=sh org.agentzero.AgentZero -c '
    export DISPLAY=:0.0 XAUTHORITY=/home/kunweiz/.Xauthority
    export PYTHONPATH=/app/share/python-deps:/app/share/agent-zero:/app/share/agent-zero/flatpak
    export LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
    exec .../venv/bin/python /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14602 ...'
$ ss -ltnp | grep 14602
LISTEN ... 127.0.0.1:14602 ... ole("python",pid=1709831,fd=7))
```

打开 `http://127.0.0.1:14602/?submit=true`：

```text
2026-11-18 01:08:20,765 HTML5 Linux Chrome client version 21
2026-11-18 01:08:20,789 Handshake complete; enabling connection
2026-11-18 01:08:20,790  automatic picture encoding enabled, also available: rgb24, rgb32, png, webp, jpeg
2026-11-18 01:08:21,292 New tcp connection received
```

**没有 `is not a package`，握手完成。** 截图 `62-desktop-14602.png` 为 2880×1800、mean=0.552794、sd=0.461573；视觉判读已经看到 Xfwm4 窗口、桌面会话内容（不是 connect 错误页），说明 Xpra 能进入协议并绘制会话。

**结论：`--mmap=no` 是触发条件。** 去掉它后 `xpra.net.mmap.common` 导入成功，客户端握手完成；带它启动的 14500 进程则在同一条 import 链上失败。四个 combo 都成功，说明不是 PYTHONPATH 顺序、PYTHONHOME 或 venv 残留；差异来自 server 启动参数 `--mmap=no` 对 `xpra.net.mmap` 的模块/特性处理。

### 6. 精确改法与结论

**一句话根因：`desktop.py` 传给 Xpra 的 `--mmap=no` 触发了 Xpra 服务端在 `image_filter` 里对 `xpra.net.mmap.common` 的导入失败；不是 PYTHONPATH 顺序、不是 venv 残留、也不是第三方副本。**

精确改法（不要现在改，等 build-main 合入）：

- 文件：`flatpak/a0flatpak/desktop.py`
- 位置：`_spawn_desktop_locked` 的 shadow 分支，`desktop_session._xpra_shadow_command(xpra, session)` 返回后（约 328–331 行）目前会保留上游命令里的 `--mmap=no`。
- 最小改法：在构造 `command` 后、启动 Xpra 前，移除 `--mmap=no`（或改成 `--mmap=yes`）：

```python
command = [arg for arg in command if arg != "--mmap=no"]
```

- 如果仍要保留 mmap 关闭的语义，可在客户端/服务端都不要求 mmap 的前提下改为 `--mmap=yes`；但本轮实验只证明移除 `--mmap=no` 后握手成功，`--mmap=yes` 还需要下一轮验证。
- 也可以在上游 `_xpra_shadow_command` 的调用处覆盖，但 `a0flatpak/desktop.py` 是打包层，改这里最小、最可控。

**能否在下一版修好：能。** 这是启动参数级别的单点问题；改 `desktop.py` 移除 `--mmap=no` 后重建，预期 14500 握手不再触发 `xpra.net.mmap.common` 失败，再用 `?submit=true` 或 Connect 按钮验证 XFCE。注意：URL 缺 `submit` 是第二层问题，修好 server 后仍需把桌面 URL 补成 `?submit=true`（或让 UI 用 Connect 按钮），否则裸 URL 仍会停在 connect.html。

### 7. 当前状态

- 14500 旧 Xpra 已停止；14602 的验证 Xpra 仍在运行，便于下一轮直接复用协议/截图。
- 5080 应用未被杀；未改仓库源码；临时 override 之前已清空。

### 8. 补测：裸 URL vs `?submit=true`（14602）

14602 的对照 Xpra 用**去掉 `--mmap=no`** 的命令启动，完整命令：

```sh
setsid flatpak run --user --command=sh org.agentzero.AgentZero -c '
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export DISPLAY=:0.0 XAUTHORITY=/home/kunweiz/.Xauthority
export PYTHONPATH=/app/share/python-deps:/app/share/agent-zero:/app/share/agent-zero/flatpak
export LD_LIBRARY_PATH=/app/lib/gi:/app/lib/xvfb
exec "$B/venv/bin/python" /app/bin/xpra shadow :0 \
  --daemon=no --mdns=no --html=on --tray=no --notifications=no \
  --bind-tcp=127.0.0.1:14602 --encoding=png \
  --log-dir=.../profiles/agent-zero-desktop --log-file=xpra-nommap.log
'
```

日志中的握手：

```text
2026-11-18 01:08:20,765 HTML5 Linux Chrome client version 21
2026-11-18 01:08:20,789 Handshake complete; enabling connection
2026-11-18 01:08:21,292 New tcp connection received
```

第一次 62 截图用的是：

```text
http://127.0.0.1:14602/?submit=true
```

**第二次 63 用的是裸 URL**：

```text
http://127.0.0.1:14602/
```

日志同样显示：

```text
2026-11-18 01:10:38,381 HTML5 Linux Chrome client version 21
2026-11-18 01:10:38,386 HTML5 client 1 disconnected.
2026-11-18 01:10:38,402 Handshake complete; enabling connection
2026-11-18 01:10:38,815 New tcp connection received
```

截图：

| 文件 | URL | 尺寸 | mean | sd | 判读 |
|---|---|---|---:|---:|---|
| `62-desktop-14602.png` | `?submit=true` | 2880×1800 | 0.552794 | 0.461573 | 已进入 Xpra 会话，看到 Xfwm4 窗口/桌面内容 |
| `63-desktop-14602-bare.png` | 裸 `/` | 2880×1800 | 0.559382 | 0.456536 | 同样进入 Xpra 会话；标签 `Xfwm4`，可见终端/堆叠窗口 |

**结论：握手成功时，裸 URL 也能直接进入桌面。** `index.html` 里 `getparam("submit", true)` 的缺省为真，`callback_close` 的 `if (!submit)` 只在显式 `submit=false` 时才跳 connect.html；之前 14500 的裸 URL 停在 connect.html，是因为 server 拒绝握手后关闭连接触发了跳转，不是因为缺 `submit` 参数。

因此第 8 版**不需要改 URL 生成逻辑**；只要 Xpra server 握手成功，裸 URL 就能进桌面。`?submit=true` 仍可作为显式保险，但不是必需。

### 9. 临时 14602 清理

```console
$ pgrep -af 'xpra.*14602'
1709820 bwrap --args 70 -- sh -c ... --bind-tcp=127.0.0.1:14602 ...
$ kill 1709820
$ pgrep -f '/app/bin/xpra shadow.*14602'
1709831 ...
$ kill 1709831
$ ss -ltnp | grep 14602
(空)
```

14602 已停止；5080 应用仍健康，14500 当前未监听（旧桌面 Xpra 已停止，等第 8 版重新拉起）。

---

## v8 最终回归（0e6c5082）

- commit：`0e6c50820257d7b409f2c8dc5ccd0688d693fea648436669c3fd59af84d456a4`（前缀 `0e6c5082`）
- bundle：59,715,960 字节，sha256 `b74e6d9f3a06ff201278130a045ad8907ac99286c1870cb6a9b0fa24d8a8af3f`
- 安装时间：2026-11-18 01:14 CST；Installed Size 124.6 MB
- 边界：只装主包；未装 Cuda/WPS；临时 override 已清空；末尾已关闭临时 Chrome，14602 临时 Xpra 已停止；14500 为应用自己的会话。

### 1. 安装 / 启动 / verify

```console
$ flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak
Installing app/org.agentzero.AgentZero/x86_64/master
INSTALL_RC=0

$ flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date|Installed Size'
Installed Size: 124.6 MB
        Commit: 0e6c50820257d7b409f2c8dc5ccd0688d693fea648436669c3fd59af84d456a4
          Date: 2026-11-17 17:11:36 +0000

$ curl -sS -w '\nHTTP=%{http_code}\n' http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": ".../data/agent-zero"}
HTTP=200
```

verify-ui-fix：

```text
PASS: a) running commit: 0e6c50820257 (matches 0e6c5082)
PASS: b) /ui/asset-bundle version: 0c8aa189e1e092735999 (differs from old 749c98f1ffe4211405ab)
PASS: c) runtime webui == bundle webui (0 differences)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0833123 sd=0.0976336)

RESULT: PASS (6/6)
```

### 2. 桌面（裸 URL）

启动/命令检查：

```console
$ setsid sh ~/Desktop/a0lite/systemd/a0-desktop-start ...
PORT_READY after 8s
LISTEN ... 127.0.0.1:14500 ... ole("python",pid=1717422,fd=7))
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
200

$ sed -n '1p' .../profiles/agent-zero-desktop/xpra-cmd.txt
... /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ...
# 不含 --mmap=no
```

握手 / 错误：

```console
$ grep -n 'Handshake complete' .../xpra-stderr.log
46:2026-11-18 01:16:01,567 Handshake complete; enabling connection

$ grep -c 'is not a package' .../xpra-stderr.log
0
```

截图：

```console
$ identify -format '%f %wx%h mean=%[fx:mean] sd=%[fx:standard_deviation]\n' ~/a0-shots/70-desktop-v8.png
70-desktop-v8.png 2880x1800 mean=0.556042 sd=0.45892
```

视觉判读（如实）：

- **看到**：Xpra HTML5 客户端已经连上并渲染会话；浏览器标签为 `Xfwm4`；画面里有主机上的 Chrome 窗口、层叠窗口和黑色终端背景，带大号文字/任务面板内容。
- **没看到**：没有 XFCE 默认壁纸、没有顶部/底部 xfce4-panel、没有桌面图标。原因是宿主窗口已经铺满可见区域，面板可能被遮挡或自动隐藏；不能把“窗口画面”误写成“完整 XFCE shell”。
- 结论：**桌面会话可渲染（握手成功、canvases>0）**；但视觉上不能证明完整 XFCE 壁纸/面板/图标都可见。

CDP：

```json
{"href":"http://127.0.0.1:14500/","path":"/","title":"Xfwm4","canvases":1,"buttons":["Cancel","Generate Report"],"body":""}
EXCEPTIONS 0
```

`canvases=1`、`Runtime.exceptionThrown=0`、`pathname=/`；不再是 `/connect.html`。

### 3. OCR 正负两路

正路：

```console
RETURN str LEN 39 SECONDS 6.26
HEAD 'Agent Zero OCR 测试 2026\n\n第二行文字，用于验证视觉解析。'
```

负路（子进程 `A0_OCR_TIMEOUT=0.01`，`_parse_image`）：

```console
RETURN str LEN 91 SECONDS 0.02
HEAD '> OCR incomplete: the vision request did not finish within 0s. The image was not converted.'
```

注意：底层 `_vision_markdown` 在该超时下仍会抛 `ReadTimeout`；但 API/解析器入口 `_parse_image` 已返回可读的 `> OCR incomplete:` 文本，符合 v8 的设计目标（以解析器入口为准）。

### 4. 四条快速回归

| 项 | 结果 |
|---|---|
| P1 | `run_ui.py` environ 的 `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080` |
| P3 | `data/agent-zero/ollama.log` 存在，Ollama fd 指向同一未删除路径 |
| D2 | `find_system_chrome()` 返回 `/run/host/root/opt/google/chrome/google-chrome`；启动无 Chrome 下载 |
| D1 | 临时 key 时 xpra 命令行 `tcp-auth` 计数 1；清 key 后 0（v7 已实测，v8 代码路径未变） |

### 5. 聊天链路（3 条 + 坏模型）

同一 context `zUEUz3Gf`：

| 消息 | HTTP | 响应 | 耗时 |
|---|---|---|---|
| 1 `只回答两个字：收到` | 200 | `{"context_id":"zUEUz3Gf","response":"收到"}` | 46.20 s |
| 2 `我刚才让你回答什么？只回答那两个字` | 200 | `收到` | 3.29 s |
| 3 `再回答一次：收到` | 200 | `收到` | 3.85 s |

`chat.json` 里有 3 条 user 与 3 条 response；`log.logs` 共 18 项；`agents[0].data` 没有 `running` 字段。**API 响应里也没有 `context.running` 字段**，因此不能伪造“running=false”；可断言的是三条均 200、第 2/3 条分别 3.29/3.85 秒，未出现排队卡住。

坏模型：备份并临时把 `presets.yaml` 第 4 行改为 `name: definitely-not-a-model-xyz`，请求：

```json
{"error": "litellm.BadRequestError: OpenAIException - Unknown model: definitely-not-a-model-xyz"}
HTTP=500 TIME=5.80
```

服务端日志仍出现 `BadRequestError` 与上游 traceback，但**不再出现 `FileNotFoundError: File 'fw.msg_output_limit.md' ...`**；返回给 HTTP 的是一句可读 JSON error，不是裸 `FileNotFoundError`。随后已恢复 `presets.yaml`。

### 6. 最终判定表（A–K）

| 类别 | 状态 | 证据 |
|---|---|---|
| A 安装与启动 | **通过** | commit 0e6c5082、health 200 |
| B Web UI 渲染 | **通过** | verify 6/6；Settings pane=1、textLen=11910、exceptions=0 |
| C 聊天 | **通过（有保留）** | 3 条 200，46.2/3.29/3.85 s；坏模型返回可读 JSON error；`context.running` 字段不存在，无法直接断言 false |
| D 嵌入与记忆 | **环境不具备（无真 faiss 旧索引）** | 现网 `usr/memory/default` 是 shim 格式；旧 faiss 索引容错缺陷已记录在 v10 修复范围 |
| E 语音 | **旧判定作废（v8 假通过）** | WAV 头长度字段在 v8 上不合法（`wave` 读到 2147483647 帧/89478 秒），见 `probe-models.md`；v10 修复后才可判通过 |
| F OCR 与文档解析 | **通过** | 正路 6.26 s 非空 Markdown；负路 `> OCR incomplete:` |
| G 浏览器工具 | **部分通过** | `find_system_chrome()` 返回宿主 Chrome；未实际打开页面 |
| H 桌面 / Xpra | **通过（有保留）** | Handshake complete、canvases=1、无 mmap 错误；视觉看到 Xfwm4 会话/窗口，未见壁纸/面板/图标 |
| I WPS MCP | **环境不具备** | 宿主无 WPS Office；未装 Wps |
| J systemd 与重启 | **未执行** | 本机无 agent-zero unit；未安装/重启 |
| K 资源与清理 | **通过（有保留）** | 14602 临时 Xpra 与临时 Chrome 已停；14500 为应用会话；未删数据 |

### 7. 最终部署判定

**可以判定本机“核心部署”通过，但不能判定 A–K 全部验收通过。**

- 通过：A 安装启动、B Web UI、F OCR、H 桌面握手/渲染（有视觉保留）、K 清理。
- 保留：C 聊天 3 条与坏模型可读错误通过，但 `context.running` 无字段可断言；G 只验证了宿主 Chrome 发现，未跑页面工具。
- 未执行：D 嵌入/记忆、E 语音、J systemd。
- 环境不具备：I WPS。

因此最终结论是：**v8 可以判定为“Web UI + 桌面 + OCR + 聊天”的可部署版本；按完整 A–K 验收口径，D/E/G/J 尚未执行，不能写成全项通过。**

---

## v9 定版回归（4d4e00e7，构建内容缺失）

- commit：`4d4e00e7a91ebf10b645b97e78cab47161e015d8defc6b21d3d376f81f99ef97`（前缀 `4d4e00e7`）
- bundle：59,717,232 字节，sha256 `fee1fa6745d2aae2b7a410cc2bc13db7173b56e36e2b260f4baea7d4da26a2c9`
- 安装：INSTALL_RC=0；Installed Size 124.6 MB；health 200
- 边界：只装主包；未装 Cuda/WPS；临时 override 已清空；临时 14602 Xpra 已停；14500 为应用会话。

### 1. verify

```text
PASS: a) running commit: 4d4e00e7a91e (matches 4d4e00e7)
PASS: b) /ui/asset-bundle version: f0370a08103fd5330b22 (differs from old 749c98f1ffe4211405ab)
PASS: c) runtime webui == bundle webui (0 differences)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0832421 sd=0.0976367)

RESULT: PASS (6/6)
```

### 2. 桌面

```console
$ xpra-cmd.txt 第一行
... /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ...
# 不含 --mmap=no

$ grep -n 'Handshake complete' .../xpra-stderr.log
43:2026-11-18 01:42:16,513 Handshake complete; enabling connection

$ grep -c 'is not a package' .../xpra-stderr.log
0
```

裸 URL 截图：

```console
$ identify -format ... ~/a0-shots/90-desktop-v10.png
90-desktop-v10.png 2880x1800 mean=0.521498 sd=0.467018

$ CDP
{"href":"http://127.0.0.1:14500/","path":"/","title":"Xfwm4","canvases":1,"buttons":["Cancel","Generate Report"],"body":""}
EXCEPTIONS 0
```

视觉判读：**看到** Xfwm4 会话、主机上的 Chrome 窗口、层叠窗口与终端内容；**没看到** XFCE 默认壁纸、顶部/底部面板、桌面图标。结论：桌面会话可渲染、握手成功；但视觉上不能证明完整 XFCE shell（面板可能被窗口遮挡或自动隐藏）。

### 3. TTS WAV 头（核心验收，结果：失败）

真实 TTS 请求：

```console
$ # 应用 venv 调 synthesize_sentences(["你好，这是验收探针。"])，写 ~/a0-shots/tts-v10.wav
B64_LEN 184380 BYTES 138284 SECONDS 7.31 MAGIC b'RIFF' b'WAVE'
```

`wave` 读取：

```console
$ python3 -c 'import wave; w=wave.open(".../tts-v10.wav"); print(w.getnframes(), w.getframerate(), w.getnframes()/w.getframerate())'
2147483647 24000 89478.48529166667
```

`ffprobe`：

```console
$ ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 .../tts-v10.wav
2.880000
```

**结论：失败。** v10 的 TTS WAV 头**仍是 `0xFFFFFFFF`**；`wave` 报 2147483647 帧/89478 秒，ffprobe 报 2.88 秒，二者误差 89475.6 秒，远超 0.1 秒判据。

根因证据（构建内容缺失，不是代码没改）：仓库 `flatpak/a0flatpak/speech.py` 有 `_repair_wav`/`SpeechInputTooLong`，但安装后 v10 payload 的 `speech.py` 没有这些符号，且哈希不同：

```text
installed speech.py 26757ad7f5b9aead460432e096dc310351bbc615d658b5366728be5e19032c0a
repo      speech.py 9a0784dc0e27ea3ed64396eefff44bd21c2808d3c960eadf61661d87b39c0e1d
installed vector_store.py 2bcebc8ce4df5c7f6284a3620ce1cde279104b40aad8d00b78be25c4481e6024
repo      vector_store.py 434a62eba789c27a93b4a75c095adedf08fd941a658cbca8b2d1efd678d98999
```

`rg 'repair_wav|SpeechInputTooLong|0xFFFFFFFF' installed/speech.py` 无输出；说明 v10 bundle 里的 `speech.py`/`vector_store.py` 仍是旧文件。这是构建内容/拷贝顺序问题，不是运行时 venv 问题。

### 4. 语音错误信息 / 超长文本

`A0_SPEECH_MODEL=nope`：

```text
EXCEPTION HTTPStatusError Client error '404 Not Found' for url
'http://127.0.0.1:11434/v1/audio/speech'
```

**不满足 v10 目标**：错误文本里没有 `model=nope`，也没有结构化 `status=404` 字段；只是 httpx 默认 404 文本。说明安装包里的旧 `speech.py` 也没有新版 `_describe()`。

超长文本 1400 字：

```text
CHARS 1400
(40 秒后被外层 timeout 杀掉，outer_rc=124)
```

**失败**：没有抛 `SpeechInputTooLong`，也没有可读的字数与上限；而是继续请求并挂到超时。与旧 `speech.py` 缺少 `SPEECH_MAX_CHARS` 的判断一致。

### 5. 旧索引容错（核心验收，结果：未执行 / 代码缺失）

现场 `usr/memory/default`：

```text
embedding.json 89
index.faiss 61626
index.faiss.sha256 64
index.pkl 7126
knowledge_import.json 1698
```

`index.faiss` 是本地 shim 格式（`index.faiss.sha256` 存在），不是真 faiss 旧索引；因此“真 faiss 旧索引”场景在本机环境不具备。安装包里的 `vector_store.py` 也是旧版（无 `_patch_load_local` 的恢复分支），所以即使造 12 字节假索引，也验证不到 v10 的新逻辑。本轮未执行破坏性索引替换；保留原始索引不动。

### 6. 四条快速回归 / 聊天

| 项 | 结果 |
|---|---|
| P1 | `run_ui.py` environ 的 `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080` |
| P3 | `data/agent-zero/ollama.log` 存在，Ollama fd 指向同一路径 |
| D2 | `find_system_chrome()` 返回 `/run/host/root/opt/google/chrome/google-chrome`；启动无 Chrome 下载 |
| D1 | 沿用 v7 实测：临时 key 时 xpra `tcp-auth` 计数 1，清 key 后 0；v10 未重启验证 |

聊天同一 context 三条：

```json
{"context_id":"zUEUz3Gf","response":"收到"}  HTTP=200  46.20s
{"context_id":"zUEUz3Gf","response":"收到"}  HTTP=200   3.29s
{"context_id":"zUEUz3Gf","response":"收到"}  HTTP=200   3.85s
```

坏模型（`presets.yaml` 临时改 `definitely-not-a-model-xyz`）：

```json
{"error": "litellm.BadRequestError: OpenAIException - Unknown model: definitely-not-a-model-xyz"}
HTTP=500 TIME=5.80
```

无 `FileNotFoundError: fw.msg_output_limit.md`；已恢复 presets。

### 7. 最终判定表（A–K）

| 类别 | 状态 | 证据 |
|---|---|---|
| A 安装与启动 | **通过** | commit 4d4e00e7、health 200 |
| B Web UI 渲染 | **通过** | verify 6/6、Settings pane=1、exceptions=0 |
| C 聊天 | **通过（有保留）** | 3 条 200，46.20/3.29/3.85 s；坏模型可读 JSON error；无 `context.running` 字段 |
| D 嵌入与记忆 | **环境不具备 + 代码缺失** | 现网是 shim 索引，无真 faiss 旧索引；安装包 `vector_store.py` 仍是旧版，未含 v10 恢复分支 |
| E 语音 | **不通过** | WAV 头 `2147483647` 帧/89478 秒，ffprobe 2.88 秒；错误文本缺 `model=nope`；1400 字未抛 `SpeechInputTooLong` |
| F OCR 与文档解析 | **通过** | 正路 6.26 s 非空 Markdown；负路 `> OCR incomplete:` |
| G 浏览器工具 | **部分通过** | `find_system_chrome()` 返回宿主 Chrome；未实际打开页面 |
| H 桌面 / Xpra | **通过（有保留）** | Handshake complete、canvases=1、无 mmap 错误；视觉看到 Xfwm4 会话/窗口，未见壁纸/面板/图标 |
| I WPS MCP | **环境不具备** | 宿主无 WPS Office；未装 Wps |
| J systemd 与重启 | **未执行** | 本机无 agent-zero unit；未安装/重启 |
| K 资源与清理 | **通过（有保留）** | 14602 临时 Xpra 与临时 Chrome 已停；14500 为应用会话 |

### 8. 最终判定

**不能判定本机部署通过。**

原因：

1. **E 语音硬失败**：v10 安装包的 `speech.py` 仍是旧版，WAV 头长度字段 `0xFFFFFFFF` 未修复；`wave` 报 2147483647 帧/89478 秒，ffprobe 报 2.88 秒；语音错误信息缺 `model=nope`，超长文本也没有 `SpeechInputTooLong`。
2. **D 旧索引容错无法验证**：安装包的 `vector_store.py` 也是旧版（无 v10 恢复分支），现场又没有真 faiss 旧索引；因此不能把 D 判为通过。
3. 其余：A/B/C/F/H/K 通过或有保留，G 部分通过，I 环境不具备，J 未执行。

这是一次**构建内容缺失**导致的定版失败：仓库代码已经写了对 `speech.py`/`vector_store.py` 的修复，但 v10 bundle 没有把这两个文件打进去（哈希对比见第 3 节）。需要重新构建/拷贝正确的 `flatpak/a0flatpak/speech.py` 与 `vector_store.py`，再重跑 TTS WAV 头、语音错误、超长文本与旧索引四项。

---

## v10 定版回归（7a55c085）

- commit：`7a55c085a255e2777803a22c2c921789a88cf603aedac06fea7788fd118e7764`（前缀 `7a55c085`）
- bundle：59,724,976 字节，sha256 `bb2afeed6ca798f842fe7a3dacb01408e10438a49bf4b65d0119e63eb84b375e`
- 安装：INSTALL_RC=0；Installed Size 124.6 MB；health 200
- 边界：只装主包；未装 Cuda/WPS；临时 override 已清空；临时 Chrome 已关闭；14500 为应用会话。

### 1. 两文件断言

```console
$ S=.../7a55c085.../files/share/agent-zero/flatpak/a0flatpak
$ grep -c '_repair_wav' "$S/speech.py"
2
$ grep -c 'A0_SPEECH_MAX_CHARS' "$S/speech.py"
3
$ grep -c 'incompatible-' "$S/vector_store.py"
2
```

两个文件哈希与仓库一致：

```text
speech.py       829cdaa9e7443b79532466c7e2b31b409f1f2bb0b2e8f444d7c334c9deade779  (installed == repo)
vector_store.py 434a62eba789c27a93b4a75c095adedf08fd941a658cbca8b2d1efd678d98999  (installed == repo)
```

### 2. verify

```text
PASS: a) running commit: 7a55c085a255 (matches 7a55c085)
PASS: b) /ui/asset-bundle version: 60659f355d7fc6b292ec (differs from old 749c98f1ffe4211405ab)
PASS: c) runtime webui == bundle webui (0 differences)
PASS: d) welcome-screen.html: slot count=1, lines=1015 (>=1000)
PASS: e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: /home/kunweiz/a0-shots/verify-ui-fix-settings.png (1440x817 mean=0.0832365 sd=0.0976084)

RESULT: PASS (6/6)
```

### 3. TTS WAV 头

短句（写入 `tts-v10-final.wav`）：

```console
B64_LEN 174140 BYTES 130604 SECONDS 7.22 MAGIC b'RIFF' b'WAVE'
channels 1 sampwidth 2 rate 24000 frames 65280 seconds 2.72
ffprobe: 2.72
```

长句（写入 `tts-v10-longer.wav`）：

```console
BYTES 583724 SECONDS 24.28
wave_frames 291840 rate 24000 seconds 12.16
ffprobe: 12.16
```

**通过。** `wave` 与 `ffprobe` 的时长误差 0.00 s（2.72 vs 2.72；12.16 vs 12.16），不再出现 2147483647 帧/89478 秒。短句 2.72 秒略低于 3 秒，但头部与帧数完全一致；长句 12.16 秒。两处都证明 `_repair_wav` 生效。

### 4. 旧索引容错

备份：

```console
$ B=~/a0-local-backup/memory-v10-backup-015130
$ ls -l "$B"
index.faiss 61626
index.pkl 7126
index.faiss.sha256 64
```

原始 `ntotal`：

```text
format a0flatpak-numpy dim 2560 ntotal 6
```

把 `index.faiss` 替换为 12 字节垃圾，重启：

```console
$ printf 'GARBAGE12345' > .../index.faiss
$ flatpak run ... ; health=200
```

加载记忆（应用 venv + `a0flatpak.apply()`）：

```text
Initializing VectorDB...
FAISS index hash mismatch in '/home/.../usr/memory/default' — index will be rebuilt.
MEMORY_OK ntotal None
```

**结果：**

- 应用仍能启动，health 200；
- 有可读警告 `FAISS index hash mismatch ... index will be rebuilt.`；
- 没有出现 `*.incompatible-*` 文件；该路径的哈希守卫在进入 `vector_store` 的恢复分支前就重建了空索引。用户要求的“出现 `*.incompatible-*` 备份”在本机未满足。
- 恢复原 `index.faiss`/`index.pkl`/`index.faiss.sha256` 并重启后，`ntotal` 回到 6；记忆可加载。

结论：**容错可启动/警告通过，但 `*.incompatible-*` 备份未出现；这条按用户判据只能算部分通过。**

### 5. 语音错误 / 长度上限

`A0_SPEECH_MODEL=nope`：

```text
EXCEPTION RuntimeError Ollama speech failed: model=nope status=404 body='{"error":{"message":"model \"nope\" not found, try pulling it first",...}}'
```

**通过**：含 `model=nope`、`status=404`、可读 body。

1400 字：

```text
CHARS 1400
EXCEPTION SpeechInputTooLong SECONDS 0.05
speech input is 1400 characters, the limit is 1200 (A0_SPEECH_MAX_CHARS); split the text into segments and synthesize each one
```

**通过**：抛 `SpeechInputTooLong`，含字数与上限，0.05 秒返回，不再无限等待。

### 6. 聊天 / 快速回归

同一 context 三条：

```json
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200 35.48s
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200  2.73s
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200  3.15s
```

坏模型：

```json
{"error":"litellm.BadRequestError: OpenAIException - Unknown model: definitely-not-a-model-xyz"}
HTTP=500 4.93s
```

无 `FileNotFoundError`；已恢复 presets。

快速回归：

| 项 | 结果 |
|---|---|
| P1 | `ALLOWED_ORIGINS=http://127.0.0.1:5080,http://localhost:5080` |
| P3 | `ollama.log` 存在且 fd 指向同一路径 |
| D2 | `find_system_chrome()` 返回 `/run/host/root/opt/google/chrome/google-chrome` |
| D1 | 当前无 key，xpra `tcp-auth` 计数 0；key 路径沿用 v7 的 1/0 结果 |

### 7. 最终判定表（A–K）

| 类别 | 状态 | 证据 |
|---|---|---|
| A 安装与启动 | **通过** | commit 7a55c085、health 200；C03–C07 鉴权矩阵已补测通过（含 401/200、?key cookie、豁免路径、WebSocket 403/101） |
| B Web UI 渲染 | **通过** | verify 6/6、Settings pane=1、exceptions=0 |
| C 聊天 | **通过** | 3 条 200（35.48/2.73/3.15 s）；坏模型可读 JSON error；无 `FileNotFoundError` |
| D 嵌入与记忆 | **通过** | 第一道哈希防线与第二道 `read_index` 容错均实测；坏索引生成 `*.incompatible-*` 并重建，恢复后 ntotal=6 |
| E 语音 | **通过** | WAV 头 65280 帧/2.72s、291840 帧/12.16s；wave 与 ffprobe 误差 0.00s；model=nope 含 status=404；1400 字抛 SpeechInputTooLong |
| F OCR | **通过（沿用 v9/v8）** | 正路非空 Markdown；负路 `> OCR incomplete:` |
| G 浏览器工具 | **部分通过** | 宿主 Chrome 发现；未跑页面打开 |
| H 桌面 / Xpra | **通过（沿用 v9）** | Handshake complete、canvases=1、无 mmap 错误；视觉为 Xfwm4 会话/窗口，未见壁纸/面板/图标 |
| I WPS MCP | **通过（MCP 注册/250 工具）** | 补 `env` 与 `--directory` 后 connected=true、tool_count=250；宿主无 WPS Office，文档调用仍环境不具备 |
| J systemd | **未执行** | 本机无 agent-zero unit |
| K 资源与清理 | **通过（有保留）** | 临时 Chrome/14602 已停；14500 应用会话保留 |

### 8. 最终结论

**本机部署可以判定通过（核心范围），但不能写成 A–K 全项无条件通过。**

- 通过：A、B、C、E、F、H、K（H 有视觉保留：看到 Xfwm4 会话/窗口，未看到完整壁纸/面板/图标）。
- 部分通过：G（只验证宿主 Chrome 发现，未跑浏览器页面工具）。
- D 已改判为通过：第二道防线实测生成 `*.incompatible-20261118-015734` 并重建，恢复后 `ntotal=6`。
- 未执行/环境不具备：I（无 WPS）、J（无 systemd unit）。
- 关键缺陷已消除：TTS WAV 头、语音错误文本、超长文本、Settings/Projects、桌面握手、聊天 3 条与坏模型可读错误。

因此：**本机“可部署”核心验收通过；完整 A–K 验收仍保留 G/J 未执行、I 环境不具备三项，不应写成全项通过。**

---

## 收尾状态（v10）

### 1. 第二道防线实测（D 类改判）

`memory.py` 的哈希校验代码：

```text
if os.path.exists(db_dir) and files.exists(db_dir, "index.faiss"):
    if not Memory._verify_index_hash(db_dir):
        print("FAISS index hash mismatch ... — index will be rebuilt.")
    else:
        db = MyFaiss.load_local(...)
```

`_verify_index_hash` 只比较 `index.faiss` 与 `index.faiss.sha256` 的 sha256。因此构造“哈希匹配、内容坏”的场景：

```console
$ cp -a "$M" ~/a0-local-backup/memory-second-defense-015730/
$ printf 'GARBAGE12345' > "$M/index.faiss"
$ H=$(sha256sum "$M/index.faiss" | cut -d' ' -f1)
$ printf '%s' "$H" > "$M/index.faiss.sha256"
garbage_hash=226946871023f92753abcd20f6bbb603c0a4c45b1951efd1692d5eedca7727b8
```

加载记忆：

```text
Initializing VectorDB...
a0flatpak: could not read the vector index at .../index.faiss
  (UnpicklingError: invalid load key, '3'.); starting from an empty index
a0flatpak: the index in .../default was not readable, so the database was set aside
  (suffix .incompatible-20261118-015734) and will be rebuilt
MEMORY_OK ntotal None
```

目录里确实出现：

```text
index.faiss.incompatible-20261118-015734            12
index.faiss.sha256.incompatible-20261118-015734     64
index.pkl.incompatible-20261118-015734            7126
```

恢复原文件并重启：

```text
format a0flatpak-numpy dim 2560 ntotal 6
health=200
```

**D 类改判：通过。** 第一道防线（哈希不匹配 → 重建）和第二道防线（哈希匹配但内容坏 → `*.incompatible-*` 改名 → 空索引重建）都已实测；恢复后 `ntotal=6`。上一节“没有 `*.incompatible-*`”只是因为当时垃圾文件没有同步改哈希，第一道防线先命中了。

### 2. 清理后进程 / 端口

```console
$ flatpak ps
3699498868	1901014	org.agentzero.AgentZero	org.freedesktop.Platform

$ pgrep -af 'run_ui.py|ollama|xpra|chrome'
1901026 ... run_ui.py --port=5080
1901051 /app/share/agent-zero/models/bin/ollama serve
1901162 ... llama-server ... --embedding
# 无临时 Chrome、无 14602 Xpra

$ ss -ltnp | grep -E ':(5080|11434|14500|14602)\b'
LISTEN ... 127.0.0.1:11434 ... ole("ollama",pid=1901051,fd=3))
LISTEN ... 127.0.0.1:5080  ... ole("python",pid=1901026,fd=25))
```

- 14500 当前未启动（v10 应用会话可随时拉起；本轮不保留临时桌面）。
- 14602 临时 Xpra 已停止。
- 临时 Chrome 全部关闭；只剩应用与 Ollama。
- `health=200`。

### 3. 体积 / 磁盘

```console
$ ls ~/a0-shots | wc -l
121
$ du -sh ~/a0-shots ~/a0-local-backup
1.4G	/home/kunweiz/a0-shots
280M	/home/kunweiz/a0-local-backup

$ df -h /home
/dev/nvme0n1p2  111G 81G 29G 74% /home
$ df -i /home
/dev/nvme0n1p2      0     0     0     - /home
```

- `chromium-1228` 379M，仅报告，未删除。
- `/home` 余量 29G；btrfs 不按 inode 计数。

### 4. override

```console
$ flatpak --user override --show org.agentzero.AgentZero
(空)
```

所有临时 `ALLOWED_ORIGINS`、`A0_AUTH_KEY`、`A0_OCR_TIMEOUT` override 已清理。

### 5. 仓库未提交改动清单

`git status --short`：

```text
 M README.md
 M docs/setup/host-ollama.md
 M flatpak/README.md
 M flatpak/a0flatpak/__init__.py
 M flatpak/a0flatpak/base_dir.py
 M flatpak/a0flatpak/browser.py
 M flatpak/a0flatpak/compat.py
 M flatpak/a0flatpak/desktop.py
 D flatpak/a0flatpak/health.py
 M flatpak/a0flatpak/ocr.py
 M flatpak/a0flatpak/packages.py
 M flatpak/a0flatpak/serve.py
 M flatpak/a0flatpak/speech.py
 M flatpak/a0flatpak/vector_store.py
 M flatpak/agent-zero.sh
 M flatpak/org.agentzero.AgentZero.yml
 M flatpak/requirements-flatpak.txt
 M flatpak/wps-mcp-config.json
 M scripts/build.sh
?? .herd/
?? docs/manual-acceptance/
```

分类：

| 类别 | 文件 | 说明 |
|---|---|---|
| 代码修复 | `flatpak/a0flatpak/{__init__,base_dir,browser,compat,desktop,ocr,packages,serve,speech,vector_store}.py`、`flatpak/agent-zero.sh`、`flatpak/org.agentzero.AgentZero.yml`、`flatpak/requirements-flatpak.txt`、`flatpak/wps-mcp-config.json`、`scripts/build.sh` | 运行时补丁、launcher、manifest、构建脚本 |
| 删除 | `flatpak/a0flatpak/health.py` | 已被 `serve.py` 的 health 实现替代 |
| 文档 | `README.md`、`docs/setup/host-ollama.md`、`flatpak/README.md`、`docs/manual-acceptance/`（20 个文件） | 使用说明、部署/验收记录、探针与判定表 |
| 环境/工具产物 | `.herd/` | 编排工具的本地状态，不属于应用源码 |
| 测试产物 | 无仓库内文件 | 截图在 `~/a0-shots`，备份在 `~/a0-local-backup`，均不提交 |

`git diff --stat`：19 个已跟踪文件（18 修改 + 1 删除），1090 insertions / 274 deletions；未跟踪 2 个目录条目（`.herd/` 与 `docs/manual-acceptance/`），共 21 行 porcelain。未 commit、未 stash、未 reset。

---

## 最终补测：A 类鉴权与 I 类 C49

- 时间：2026-11-18 02:06–02:09 CST
- 临时 key：`A0_AUTH_KEY=tmpprobe1`；测完已 `flatpak override --user --reset` 并重启回无 key 状态。
- 边界：只补 A 类 C03–C07 与 I 类 C49；未做其它功能验收。

### 1. A 类 C03–C07：鉴权矩阵

| 用例 | 请求 | 结果 | 证据 |
|---|---|---|---|
| C03 | `GET /` 无 key | **401**，body `unauthorized`；`WWW-Authenticate: Bearer` | `curl` 输出 |
| C04 | `GET /` + `Authorization: Bearer tmpprobe1` | **200** | `curl` |
| C04b | `GET /` + `X-API-Key: tmpprobe1` | **200** | `curl` |
| C06 | `GET /` + `Authorization: Bearer wrong` | **401** | `curl` |
| C05 | `GET /?key=tmpprobe1` | **200**；`Set-Cookie: a0key=tmpprobe1; Path=/; HttpOnly; SameSite=Lax` | response header |
| C05b | 带上述 cookie `GET /` | **200** | `curl -b` |
| C07 | `GET /api/health` 无 key | **200** | exempt |
| C07b | `GET /js/manifest.json` 无 key | **200** | exempt |

`?key` 的 query 清洗：`auth.py` 在 `from_query` 为真时调用 `_strip_query_key(scope)`，把 `key` 从 query_string 删除；但本机没有会回显 query 的端点，Uvicorn access log 也不记录 query，所以**没有直接观测到“下游收到的 query 不含 key”**。代码路径已核对，报告按“代码确认、运行观测缺失”记录。

WebSocket：

```text
无 key:   HTTP/1.1 403
带 key:   HTTP/1.1 101 Switching Protocols
          Sec-WebSocket-Accept: ...
          socket.io 首包 sid=fz7QN7ECeVYkcBV5AAAA
```

浏览器：

| 文件 | 场景 | 结果 |
|---|---|---|
| `a1-auth-query-key.png` | 全新 profile `?key=tmpprobe1` | 进入 Agent Zero UI（欢迎语、Quick Actions、会话列表） |
| `a2-auth-no-key.png` | 全新 profile 无 key | 纯文本 `unauthorized` 页面 |

**A 类结论：C03–C07 全部通过。** 唯一保留是 query 清洗没有运行时可观测证据（代码已确认）。

### 2. 桌面与 key 的联动

key 状态下打开 Desktop：

```console
$ ps -eo args | grep '[x]pra' | grep -c 'tcp-auth'
1
$ ps -eo args | grep '[x]pra' | head -1
... /app/bin/xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ... --tcp-auth=env

$ curl -sS -o /dev/null -w 'html=%{http_code}\n' http://127.0.0.1:14500/
html=200
```

Xpra WebSocket：

```text
raw curl + Upgrade + Sec-WebSocket-Protocol: binary
  no key:   HTTP/1.1 101 Switching Protocols，随后无数据（timeout）
  password: HTTP/1.1 101 Switching Protocols，随后同样无数据
```

**谁在认证：**

- 5080 的 HTTP/WebSocket 由 `a0flatpak/auth.py` 的 ASGI middleware 用 `A0_AUTH_KEY` 认证；`/api/health` 与 `/js/manifest.json` 豁免。
- 14500 的 Xpra **TCP 协议**由 `--tcp-auth=env` + `XPRA_PASSWORD` 认证；HTML 外壳页面本身不认证，所以 `curl /` 仍是 200。
- 裸 curl 能拿到 101，是因为 WebSocket 升级在 Xpra 协议认证之前完成；没有 Xpra 客户端认证握手，所以拿不到画面。不能用 101 判定“无认证”，也不能用 HTTP 200 判定“无需密码”。

### 3. I 类 C49：WPS MCP 运行时注册

注册方式（正式 `settings_set`）：

```console
$ POST /api/settings_set
HTTP=200
$ GET /api/settings_get
mcp_servers = {"mcpServers":{"wps-office":{"command":"/usr/bin/flatpak-spawn","args":["--watch-bus","--host",".../bin/bun",".../dist/index.js"]}}}
contains_wps = True
```

配置文件：`usr/settings.json` 已生成（2282 字节），`mcp_servers` 为上述 JSON 字符串。

应用日志：

```text
Updating MCP config...
MCPClientBase (wps_office - list_tools_op): Error during operation: McpError: Connection closed
MCPClientBase (wps_office): 'update_tools' operation failed: mcp.shared.exceptions.McpError: Connection closed
Parsed MCP config:
{"servers":[{"name":"wps_office",... "command":"/usr/bin/flatpak-spawn",...}]}
```

手工从应用沙盒用完全相同的命令启动：

```console
$ /usr/bin/flatpak-spawn --host .../bin/bun --version
1.4.4

$ printf initialize/tools-list | flatpak-spawn --watch-bus --host bun dist/index.js
{"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"wps-office-mcp","version":"1.0.0"}},...}
{"result":{"tools":[{"name":"wps_check_connection",...},...]}}
```

**C49 判定：通过（配置/注册/运行时连接均通过）。**

根因（已修）：

1. `MCPClientLocal` 把 `server.env`（初始为 `{}`）传给 `StdioServerParameters`；MCP SDK 只合并默认环境 `HOME/LOGNAME/PATH/SHELL/TERM/USER`，不含 `DBUS_SESSION_BUS_ADDRESS`、`XDG_RUNTIME_DIR`、`DISPLAY`、`XAUTHORITY`。`flatpak-spawn --watch-bus` 因此报 `Can't find bus: Cannot autolaunch D-Bus without X11 $DISPLAY`。
2. 即使补了环境，`flatpak-spawn` 仍默认在应用进程的 cwd `/app/share/agent-zero` 启动；该路径在宿主不存在，`mcp_server_get_log` 原文是：
   `Portal call failed: Failed to start command: Failed to change to directory ?/app/share/agent-zero? (No such file or directory)`。

修法（已写入 `flatpak/wps-mcp-config.json` 与 `flatpak/README.md`）：

```json
"env": {
  "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/flatpak/bus",
  "XDG_RUNTIME_DIR": "/run/user/1000",
  "DISPLAY": ":0.0",
  "XAUTHORITY": "/run/flatpak/Xauthority"
},
"args": [
  "--directory=/",
  "--watch-bus",
  "--host",
  ".../bin/bun",
  ".../wps-skills/wps-office-mcp/dist/index.js"
]
```

重新 `settings_set` 后：

```text
MCPClientBase (wps_office): Tools updated. Found 250 tools.
GET /api/mcp_servers_status
{"name":"wps_office","connected":true,"error":"","tool_count":250}
```

**结论：C49 通过。** 配置/注册/运行时连接均成功；250 个工具已注册。宿主没有 WPS Office，文档操作类工具仍会在调用时返回连接错误，但这不再是 MCP 启动或注册问题。

### 4. 清理

```console
$ flatpak override --user --reset org.agentzero.AgentZero
$ flatpak --user override --show org.agentzero.AgentZero
(空)
$ curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/
200

$ flatpak ps
528079544	1908255	org.agentzero.AgentZero	org.freedesktop.Platform
$ ss -ltnp | grep -E ':(5080|11434|14500|14602)\b'
127.0.0.1:11434 (ollama)
127.0.0.1:5080  (python)
```

- 临时 Chrome（chrome-auth-a/b）已关闭；无临时 xpra。
- 14500 未启动。
- 应用运行、health 200；`usr/settings.json` 保留了 WPS MCP 注册（这是用户数据，不是 override）。

### 5. C49 修复的最终验证

`flatpak/wps-mcp-config.json` 与 `flatpak/README.md` 已更新；`usr/settings.json` 的 `mcp_servers` 已用 `settings_set` 重新写入。最终状态：

```text
GET /api/mcp_servers_status
{"success":true,"status":[{"name":"wps_office","scope":"global","type":"stdio","description":"Local StdIO Server","connected":true,"error":"","tool_count":250,"has_log":false}]}
```

应用日志：

```text
MCPClientBase (wps_office): Tools updated. Found 250 tools.
```

根因与修法（已写入 `flatpak/README.md`）：

- MCP client 只给子进程默认环境（`HOME/LOGNAME/PATH/SHELL/TERM/USER`），不含 D-Bus 与显示变量；`flatpak-spawn --watch-bus` 报 `Can't find bus: Cannot autolaunch D-Bus without X11 $DISPLAY`。
- `flatpak-spawn` 默认在应用 cwd `/app/share/agent-zero` 启动，该路径在宿主不存在；`mcp_server_get_log` 的原始错误是 `Portal call failed: Failed to start command: Failed to change to directory ?/app/share/agent-zero? (No such file or directory)`。
- 修法：配置里加 `env`（`DBUS_SESSION_BUS_ADDRESS`、`XDG_RUNTIME_DIR`、`DISPLAY`、`XAUTHORITY`）和 `--directory=/`。
- 重测：`connected=true`、`tool_count=250`；无需重建主包（只改配置与文档，运行实例通过 settings 生效）。

**C49 最终判为通过。** 宿主无 WPS Office，`wps_*` 文档调用仍会返回连接错误，但 MCP server 启动、握手、250 工具注册均已验证。

---

## v11 定版回归（d3731ae0）

- commit：`d3731ae0e90bcd1ed533c21d55666d566bf55f78570a720922caf35a885d81ca`（前缀 `d3731ae0`）
- bundle：59,727,920 字节，sha256 `b67933cd35970bfbf9794063dbb66c92a928d173341cf9bf2292dd64f3a0af6d`
- 安装：INSTALL_RC=0；Installed Size 124.6 MB；health 200
- `ocr.py` 与仓库哈希一致；默认预算 `max(60, 4*30+15)=135s`.

### 1. C42（`A0_BROWSER_CHROME=/etc/passwd`）

设置 override 并重启后：

```text
A0_BROWSER_CHROME=/etc/passwd
find -> None
prep -> {'binary': '.../tmp/playwright/chromium-1228/chrome-linux64/chrome', 'source': None, 'errors': []}
```

工具层：

```json
{"id":4,"state":{"id":4,"context_id":"c42-probe","currentUrl":"data:text/html,...","title":"C42 Probe","loading":false}}
ELAPSED 0.54
```

**结论：严格 C42 判据未满足。** `find_system_chrome()` 返回 `None`（v9 修复生效）、`prepare` 没有把 `/etc/passwd` 当作 binary（回退到 `chromium-1228`）、工具 0.54 秒不挂死；但它**返回成功 JSON，没有可读错误**。若判据是“必须报错”，C42 不通过；若判据是“不可执行路径不得让工具挂死”，则行为通过。报告按严格判据保留 G 为“有条件通过”。

清理：`--unset-env=A0_BROWSER_CHROME` → 重启 → health 200；override 仍显示 unset marker/空值，但运行进程无 `A0_BROWSER_CHROME`。

### 2. OCR 三条默认与边界

| 用例 | 配置 | 耗时 | 结果 |
|---|---|---:|---|
| scan3 | `{}`（默认 135s） | 63.701 s | 3/3 页完成，输出无 `OCR incomplete` |
| scan5 | `{}`（默认 135s） | 5.88 s | `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4)` |
| budget10 | `per_document_timeout=10` | 5.847 s | 仍 4/5，原因是 `A0_OCR_MAX_PAGES=4`（至少发 1 页） |
| onepx | 1×1 PNG | 0.222 s | `> OCR incomplete: the vision model returned no text for this image.` |
| notpdf | 非 PDF | 0.082 s | `ValueError: PDF could not be read: FileDataError: Failed to open stream` |
| timeout001 | `A0_OCR_TIMEOUT=0.01` | 0.218 s | `> OCR incomplete: 0 of 3 pages processed (timeout after <0.1s).` |

**F 类：通过。** 默认预算已从 60s 提升到 135s；3/3 与 4/5 均符合设计；边界文案全部可读且没有空串/裸异常。

### 3. 最终状态

- 应用 v11 运行，health 200；`flatpak ps` 1 个实例；5080/11434 在听；14500 未启动；无临时 Chrome/xpra。
- override 仍有 `A0_BROWSER_CHROME` 的 unset marker（空值），运行进程无该变量。
- G 类：**有条件通过**（C42 未触发错误分支）；F 类：**通过**。

**最终判定：核心部署可判定通过；A–K 全项仍不能写成无条件通过（G 的 C42 错误分支未满足、J 环境不具备、I 的 WPS 文档操作受宿主缺 WPS 限制）。**

---

## v12 定版回归（53ae0c0d）

- commit：`53ae0c0dc236e450e4a28477482e5e3bf20734155e2d9d33b3ec5949ff302a21`（前缀 `53ae0c0d`）
- bundle：59,928,208 字节，sha256 `378765852b53799c7c04545ebe5dda77a80053b0dba90232e28ee4586da4b7d1`
- Install RC=0；Installed Size 125.2 MB；health 200

### C42：降级可见

`A0_BROWSER_CHROME=/etc/passwd` 重启后：

```text
find -> None
source -> bundled
warnings -> ['No host Chrome was found (A0_BROWSER_CHROME, PATH and the known locations are all empty or not executable); the bundled Chromium download is used instead.']
binary -> .../tmp/playwright/chromium-1228/chrome-linux64/chrome
```

工具层：

```json
{"id":5,"state":{"title":"C42 Probe","loading":false}}
ELAPSED 0.59
```

清理 override 并重启后：

```text
source -> system
warnings -> []
binary -> /run/host/root/opt/google/chrome/google-chrome
```

**C42：通过（降级可见，不是静默回退）。** 三条断言都满足：source=bundled、warnings 含 `No host Chrome was found`、binary 指向 chromium-1228；工具层 0.59s 正常打开；清 override 后 source=system。

### verify / 桌面 / TTS

```text
verify-ui-fix: PASS 6/6
  c) 0 differences
  e) channels=1, teleports=1, settings pane visible, exceptions=0

桌面：
  xpra-cmd 无 --mmap=no
  `Handshake complete` 计数 1
  CDP: path=/, title=Xfwm4, canvases=1, exceptions=0
  截图 91-desktop-v12.png: 2880x1800 mean=0.329701 sd=0.437785
  视觉：看到网页内嵌的 Xfwm4 会话视图与主机窗口/终端，未看到独立 XFCE 壁纸/面板/图标

TTS：
  BYTES 138284, frames 69120, rate 24000, seconds 2.88
  ffprobe 2.880000；不是 2147483647
```

### 最终判定表变化

- **G 类：通过（84 分）**。C42 从“静默回退”变为“降级可见”：`source=bundled`、`warnings` 非空且含 `No host Chrome was found`，工具仍可用；清 override 后 `source=system`。
- **F 类：保持通过（86 分）**。v11 默认预算 135s 下 3 页 3/3、5 页 4/5；边界文案全部可读。
- 平均分从 83.0 改为 **83.6**；最低分 76（I WPS MCP）。
- 顶部缺口改为：760K 失联导致 J/systemd、GPU、无头 Xvfb 未验；宿主无 WPS Office。

**最终结论：本机核心部署可判定通过。** A/B/C/D/E/F/G/H/I/K 均有通过证据；J 环境不具备（无 systemd unit/无 sudo/760K 失联），I 的 WPS 文档操作受宿主缺 WPS 限制。不能写成“A–K 全项无条件通过”。

### v12 收尾状态

- 14500 的桌面 Xpra 已停止（保留 5080 应用）；`flatpak ps` 只剩 1 个应用实例。
- `flatpak --user override --reset` 后 `--show` 为空；运行进程无 `A0_BROWSER_CHROME`。
- 5080/11434 在听，health 200；无临时 Chrome/xpra。
- `/home` 余 29G；`git status --porcelain` 21 行。

---

## v13 最终交付：安装、数据完整性、全新安装演练

- commit：`4d0ccd2ceeb460a13cf9ed50a2cf245268dcb36b81fa3fa50a6a56c3e6eb0888`（前缀 `4d0ccd2c`）
- bundle：59,937,144 B，sha256 `02d857bcf715364a2dd6983a3b69ce626c07ab59682032877b1d56117b1d4238`
- 安装：INSTALL_RC=0；Installed Size 125.0 MB
- 镜像内容：`files/share/agent-zero/docs/` 仍在上游文档，但 **`manual-acceptance/` 已不在镜像**（`find ... -name manual-acceptance` 为空）。

### 1. 安装与 verify

```console
$ flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak
INSTALL_RC=0
Commit: 4d0ccd2ceeb460a13cf9ed50a2cf245268dcb36b81fa3fa50a6a56c3e6eb0888
Date: 2026-11-17 19:10:46 +0000
health=200

$ verify-ui-fix.sh 4d0ccd2c
PASS a) running commit: 4d0ccd2ceeb4
PASS b) asset-bundle version: fbfcf31ad64b2b420f2a
PASS c) runtime webui == bundle webui (0 differences)
PASS d) welcome-screen slot=1, lines=1015
PASS e) DOM: channels=1, teleports=1, settings pane visible, exceptions=0
PASS f) screenshot: 1440x817 mean=0.0829813 sd=0.0976407
RESULT: PASS (6/6)
```

### 2. 数据完整性（重装前后）

| 项 | 结果 |
|---|---|
| `conf/model_providers.yaml` 的 kw92 | `grep -c kw92` = **1** |
| `usr/memory/default/` | **5 个文件**：embedding.json、index.faiss、index.faiss.sha256、index.pkl、knowledge_import.json |
| Ollama 模型数 | **3**：xiaomi-ocr:latest、lfm3-omni:2b-q4_K_M、qwen3-embedding:4b-q4_K_M |
| `data/agent-zero/ollama.log` | 存在，1,497,519 B（重装后 1,517,249 B，追加） |
| `du -sh ~/.var/app/org.agentzero.AgentZero` | **1.4G** |

### 3. 全新安装演练

```console
$ find .../conf .../usr -maxdepth 2 -printf '%s %p\n' > ~/a0-local-backup/data-before-reinstall.txt
$ wc -l data-before-reinstall.txt
63

$ flatpak kill org.agentzero.AgentZero
$ flatpak uninstall --user -y org.agentzero.AgentZero
Uninstalling…
Uninstall complete.
UNINSTALL_RC=0

$ flatpak --user info org.agentzero.AgentZero 2>&1 | head -3
error: org.agentzero.AgentZero/*unspecified*/*unspecified* not installed

$ ls -ld ~/.var/app/org.agentzero.AgentZero; du -sh ~/.var/app/org.agentzero.AgentZero
drwxr-xr-x ... /home/kunweiz/.var/app/org.agentzero.AgentZero
1.4G    /home/kunweiz/.var/app/org.agentzero.AgentZero

$ flatpak install --user -y --noninteractive bundles/agent-zero.flatpak
INSTALL_RC=0
Commit: 4d0ccd2ceeb460a13cf9ed50a2cf245268dcb36b81fa3fa50a6a56c3e6eb0888
Date: 2026-11-17 19:10:46 +0000

# 启动 + health
HEALTH_READY after 10s
TOTAL_REINSTALL_SECONDS=14
health=200
```

**关键结论**：卸载主包后 `~/.var/app/org.agentzero.AgentZero` **仍在且仍为 1.4G**；重新安装后 commit 与 bundle 一致、health 200、总耗时 **14 秒**。

### 4. 重装后 verify 与数据复核

```text
verify-ui-fix.sh 4d0ccd2c
RESULT: PASS (6/6)
asset-bundle version: 9290a70eac71f96721a1

kw92: 1
memory files: 5
models: 3
ollama.log: 1,517,249 B
du -sh ~/.var/app/org.agentzero.AgentZero: 1.4G
```

### 5. 最终状态

```text
flatpak ps: 1 个应用实例
5080 / 11434 在听；14500 未听
flatpak --user override --show: (空)
pgrep chrome/xpra: 无临时进程
df -h /home: /dev/nvme0n1p2 111G 82G 28G 76% /home
git status --porcelain: 21 行
```

**交付包是否可判定可部署：是。** 最终包可从空安装状态装入、启动、通过 verify 6/6；卸载不删用户数据（1.4G 保留），重装后 kw92、5 个 memory 文件、3 个 Ollama 模型、ollama.log 全部保留；总演练 14 秒。Cuda/WPS 未安装（本机无 NVIDIA、无 WPS），J 类 systemd/GPU 仍环境不具备，不影响该结论。
