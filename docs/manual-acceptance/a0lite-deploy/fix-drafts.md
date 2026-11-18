# a0lite 缺陷修复草案（未合入）

对象：当前工作树 `/home/kunweiz/Desktop/a0lite`（打包层），参考上游 `/home/kunweiz/Desktop/agent-zero` HEAD `ba9b67d`。
状态：**只出草案，没有改任何代码**。`flatpak/a0flatpak/` 已包含上一轮修改（`health.py` 删除、`ocr.py` 的 `PdfParser` 修 `self`、`browser.py` 去掉 stealth-browser 接线、`serve.py` 仅在有 key 时包装、`agent-zero.sh` 用 `.gitkeep` 门控 `usr` 种子），本文所有行号都基于改后现状。
本文中标注「实测」的结论来自本轮只读探针（`flatpak run --command=sh`、临时 `--filesystem=` 覆盖、直接执行扩展里的 `bun`），未安装/卸载任何包，未改任何仓库文件。

## 结论速览

| 编号 | 性质 | 结论 | 是否要重建 |
| --- | --- | --- | --- |
| D1 | 安全 | 成立。host-display（shadow）分支没有 Xpra 认证，`127.0.0.1:14500` 的会话无密码 | 是（主包） |
| D2 | 功能 | 成立，但根因要更正：`/usr` 是 runtime 的，`which` 永远找不到宿主 Chrome；且已安装 build 早于 `--filesystem=host` 清单 | 是（主包） |
| D3 | — | **已排除，不是缺陷**。`xiaomi-ocr` 的 manifest 在 `manifests-v2/`（符号链接），旧判断漏了新布局 | 否 |
| D4 | 功能 | 成立，机制已查清：parser 层 60 s 只包单次调用，`A0_OCR_TIMEOUT=300` 永远用不到 | 是（主包） |
| D5 | 文档/配置 | 成立。`wps-mcp-config.json` 用的是 system 路径 + `bin/node`，两者在真机都不存在 | 否（只改片段，重贴设置即可） |
| D6 | 文档 | 部分成立：Authentication 一句要随 D1 改写；`plugin/` 那行**已经是 `prompts/`**，无需再改 | 否 |

---

# D1（安全）`A0_AUTH_KEY` 不保护 Xpra shadow 分支

## 1. 证据

分支判定与后果，前一轮已实测记录在 `functional-probes.md:955-989`：

- `functional-probes.md:960`：「**有可达 DISPLAY**（当前真机就是这种：`DISPLAY=:0.0`、沙盒内 `/tmp/.X11-unix/X0` 存在）→ 走 `desktop_session._xpra_shadow_command(xpra, session)`，**不加** `--tcp-auth`，**不设** `XPRA_PASSWORD`。Xpra 端口 14500+ 只 bind `127.0.0.1`，但没有密码。」
- `functional-probes.md:989`：「`A0_AUTH_KEY` 保护的是 Agent Zero 的 ASGI（`a0flatpak/auth.py`），**不保护** shadow 分支下 14500 端口的 Xpra。」

暴露面不止本机：`kernel-gpu-migration.md:671-688` 记录过从 frp 侧探到 `5080/11434/14500` 三个端口 TCP OPEN，`curl http://frp.kw92.cyou:14500/` 当时返回 `000` 是因为 frpc 没注册，不是因为端口不通。也就是说这条 14500 一旦被转发，就是无认证的远程桌面。

现状代码核对（当前工作树）：

- `flatpak/a0flatpak/desktop.py:278-280`：`auth_key = os.environ.get("A0_AUTH_KEY", "").strip()` / `if auth_key: env["XPRA_PASSWORD"] = auth_key` —— **缩进在 `else:`（headless）分支里**。
- `flatpak/a0flatpak/desktop.py:294-296`：`--tcp-auth=env` 同样只在 headless 的 `command` 里，且注释写着「which the block below sets」——那行注释已经和代码对不上（上面的 block）。
- `flatpak/a0flatpak/desktop.py:325-332`：shadow 分支直接 `desktop_session._xpra_shadow_command(...)`，之后只改 `--encoding`、插 `--encoding=png`、前置解释器，**没有任何认证参数**。
- 上游 `plugins/_desktop/helpers/desktop_session.py:1851-1879` 的 `_xpra_shadow_command` 是字面量列表，**其中没有 `--tcp-auth`**（`--bind-tcp` 在 `:1875`，`--log-*` 在 `:1877-1878`）。所以我们追加一次不会重复。
- 上游 `_restart_xpra_shadow`（`:738-755`）在全仓**没有调用点**（`grep -rn _restart_xpra_shadow` 只命中定义），不需要一起改。

### 重复 `--tcp-auth` 会不会报错：查证结果

Xpra 6.5.5（bundle 内 `share/python-deps/xpra/__init__.py:8`）：

- `scripts/parsing.py:1920-1921`：`group.add_option("--tcp-auth", action="append", dest="tcp_auth", default=mlist(defaults.tcp_auth), ...)`。
- `server/auth.py:52-59`（`init_auth`）：遍历 `SOCKET_TYPES`，把 `opts.tcp_auth` 原样交给 `get_auth_modules`。
- `server/auth.py:63-66`：`modules = tuple(get_auth_module(auth_str) for auth_str in auth_strs)` —— 列表里有几个值就构造几个认证模块。
- 因此重复 `--tcp-auth=env` **不会在启动时报错**，会得到两个 `env` 认证模块；`server/auth.py:169-251` 的流程是逐个挑战，第一个通过后继续下一个，于是**客户端被要求输两次密码**（日志里会打印 `(1 of 2)` / `(2 of 3)`，`server/auth.py:222-225`）。这不是我们想要的效果。

结论：**不重复追加**。当前命令没有 `--tcp-auth`，可以安全加一次；为防上游以后自己加上，草案里用「先剔除同名选项、再加一次」的写法。

### 一个必须说清楚的细节：`--tcp-auth` 确实覆盖 HTML5

HTML5 客户端走 WebSocket，容易误以为要 `--ws-auth`。实际不是：

- `net/socket_util.py:261` 创建连接时把 `socktype_wrapped` 设为监听器的类型（tcp）。
- `server/core.py:1183` 在 HTTP 升级时只改 `conn.socktype = "ws"`，**没有**改 `socktype_wrapped`。
- `server/auth.py:141` 取的是 `socktype = conn.socktype_wrapped` —— 仍然是 `tcp`，于是用 `auth_classes["tcp"]`，也就是 `--tcp-auth`。
- `scripts/config.py:1302-1304`：`tcp-auth` / `ws-auth` / `wss-auth` 默认都是空列表，所以「不加就完全无认证」成立。

所以 `--tcp-auth=env` + `XPRA_PASSWORD` 就能覆盖浏览器会话，不需要 `--ws-auth`（加 `--ws-auth` 反而会在同一连接上再叠一层挑战）。这一点用日志可复核（见验证命令 4）。

## 2. 当前代码

`flatpak/a0flatpak/desktop.py:266-300`（认证只出现在 headless 分支）：

```python
        env["PYTHONHOME"] = ""
        if host:
            env["DISPLAY"] = host
        else:
            # Headless: let Xpra start its own Xvfb and serve that display.
            env.pop("DISPLAY", None)
            existing = env.get("LD_LIBRARY_PATH", "")
            parts = [p for p in existing.split(":") if p]
            for extra in (BUNDLED_XVFB_LIBS, BUNDLED_GI_LIBS):
                if extra not in parts:
                    parts.insert(0, extra)
            env["LD_LIBRARY_PATH"] = ":".join(parts)
            auth_key = os.environ.get("A0_AUTH_KEY", "").strip()
            if auth_key:
                env["XPRA_PASSWORD"] = auth_key
            xvfb = shutil.which("Xvfb") or BUNDLED_XVFB
            command = [
                *interpreter, xpra,
                "start-desktop",
                f":{session.display or 120}",
                f"--xvfb={xvfb} -screen 0 {desktop_session.MAX_SCREEN_WIDTH}x{desktop_session.MAX_SCREEN_HEIGHT}x24 -nolisten tcp -noreset",
                "--daemon=no",
                "--mdns=no",
                "--mmap=no",
                "--html=on",
                "--tray=no",
                "--notifications=no",
                f"--bind-tcp=127.0.0.1:{session.xpra_port}",
                # Xpra authenticates on its own socket. The env module reads
                # XPRA_PASSWORD, which the block below sets from A0_AUTH_KEY.
                *(["--tcp-auth=env"] if os.environ.get("A0_AUTH_KEY", "").strip() else []),
                f"--log-dir={session.profile_dir}",
                "--log-file=xpra.log",
            ]
```

`flatpak/a0flatpak/desktop.py:322-332`（shadow 分支无认证）：

```python
        command = desktop_session._xpra_shadow_command(xpra, session)
        command = [arg for arg in command if not arg.startswith("--encoding=")]
        anchor = command.index("--speed=80") + 1 if "--speed=80" in command else len(command)
        command.insert(anchor, "--encoding=png")
        # The xpra script uses whichever interpreter runs it. Only the
        # framework environment has the gi, cairo and Pillow modules Xpra needs
        # for an HTML5 session, so the interpreter is pinned explicitly.
        command = [*interpreter, *command]
```

## 3. 建议改动

整段替换 `flatpak/a0flatpak/desktop.py:239-355` 的 `_spawn_desktop_locked`（`def` 之前的内容不动）。下面这段已用 `python3 -m py_compile` 通过，并用桩件跑过四种组合（shadow/headless × 有 key/无 key），实测结果见「验证命令 1」。

```python
    def _spawn_desktop_locked(self, session: Any) -> None:
        if session.session_id != desktop_session.SYSTEM_SESSION_ID:
            return original_spawn(self, session)

        desktop_session.STATE_DIR.mkdir(parents=True, exist_ok=True)
        desktop_session.SESSION_DIR.mkdir(parents=True, exist_ok=True)
        session.profile_dir.mkdir(parents=True, exist_ok=True)

        host = _host_display()
        session.display = (
            _display_number(host) if host else desktop_session.DISPLAY_BASE
        )
        (session.profile_dir / "spawn-diag.txt").write_text(
            f"host={host!r} display={session.display} port={session.xpra_port}\n"
        )

        xpra = desktop_session._require_binary("xpra")
        interpreter = [sys.executable]
        env = {**virtual_desktop.XPRA_START_ENV, **self._display_env(session)}
        # The Xpra client needs the bundled gi and cairo modules, which the
        # runtime's interpreter cannot import.
        existing = env.get("PYTHONPATH", "")
        parts = [p for p in existing.split(":") if p]
        for extra in (BUNDLED_PY_DEPS,):
            if extra not in parts:
                parts.insert(0, extra)
        env["PYTHONPATH"] = ":".join(parts)
        env["PYTHONHOME"] = ""

        # Xpra authenticates its own sockets with the same key as the Web UI:
        # the `env` module reads XPRA_PASSWORD from this process environment,
        # and --tcp-auth=env installs it for every TCP socket of the server
        # (scripts/parsing.py:1920). The host-display shadow branch publishes
        # the same 127.0.0.1 port as the headless one, so both paths get it.
        auth_key = os.environ.get("A0_AUTH_KEY", "").strip()
        if auth_key:
            env["XPRA_PASSWORD"] = auth_key
        xpra_auth = ["--tcp-auth=env"] if auth_key else []

        if host:
            env["DISPLAY"] = host
        else:
            # Headless: let Xpra start its own Xvfb and serve that display.
            env.pop("DISPLAY", None)
            existing = env.get("LD_LIBRARY_PATH", "")
            parts = [p for p in existing.split(":") if p]
            for extra in (BUNDLED_XVFB_LIBS, BUNDLED_GI_LIBS):
                if extra not in parts:
                    parts.insert(0, extra)
            env["LD_LIBRARY_PATH"] = ":".join(parts)
            xvfb = shutil.which("Xvfb") or BUNDLED_XVFB
            command = [
                *interpreter, xpra,
                "start-desktop",
                f":{session.display or 120}",
                f"--xvfb={xvfb} -screen 0 {desktop_session.MAX_SCREEN_WIDTH}x{desktop_session.MAX_SCREEN_HEIGHT}x24 -nolisten tcp -noreset",
                "--daemon=no",
                "--mdns=no",
                "--mmap=no",
                "--html=on",
                "--tray=no",
                "--notifications=no",
                f"--bind-tcp=127.0.0.1:{session.xpra_port}",
                *xpra_auth,
                f"--log-dir={session.profile_dir}",
                "--log-file=xpra.log",
            ]
            log_path = session.profile_dir / "xpra-stderr.log"
            session.processes["xpra"] = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=open(log_path, "wb"),
                env=env,
            )
            try:
                desktop_session._wait_for_port(
                    "127.0.0.1",
                    session.xpra_port,
                    timeout=XPRA_START_TIMEOUT,
                    process=session.processes.get("xpra"),
                )
            except Exception:
                (session.profile_dir / "xpra-cmd.txt").write_text(
                    " ".join(command) + "\n\n" + str(env) + "\n"
                )
                raise
            return

        # The bundle ships Pillow but not the Xpra JPEG module, so the default
        # `--encoding=jpeg` leaves no usable packet encoder. Pillow covers png
        # and webp, which is what the HTML5 client renders.
        command = desktop_session._xpra_shadow_command(xpra, session)
        command = [arg for arg in command if not arg.startswith("--encoding=")]
        anchor = command.index("--speed=80") + 1 if "--speed=80" in command else len(command)
        command.insert(anchor, "--encoding=png")
        if xpra_auth:
            # Xpra appends repeated --tcp-auth values (action="append"), and two
            # `env` modules would challenge the client twice, so exactly one is
            # kept: ours replaces any the upstream command may grow later.
            command = [arg for arg in command if not arg.startswith("--tcp-auth=")]
            command.extend(xpra_auth)
        # The xpra script uses whichever interpreter runs it. Only the
        # framework environment has the gi, cairo and Pillow modules Xpra needs
        # for an HTML5 session, so the interpreter is pinned explicitly.
        command = [*interpreter, *command]
        probe = subprocess.run(
            [xpra, "--version"], capture_output=True, text=True, env=env, timeout=30
        )
        (session.profile_dir / "xpra-cmd.txt").write_text(
            " ".join(command)
            + "\n\nVERSION rc=" + str(probe.returncode) + " out=" + probe.stdout.strip()[:80]
            + " err=" + probe.stderr.strip()[:200]
            + "\n"
        )
        shadow_stderr = open(session.profile_dir / "xpra-stderr.log", "wb")
        session.processes["xpra"] = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=shadow_stderr,
            env=env,
        )
        desktop_session._wait_for_port(
            "127.0.0.1",
            session.xpra_port,
            timeout=XPRA_START_TIMEOUT,
            process=session.processes.get("xpra"),
        )
```

### 「无 key 时行为不变」的证明

改动只涉及三处，且都由 `auth_key` 门控：

1. `env["XPRA_PASSWORD"] = auth_key` 在 `if auth_key:` 里。
2. `xpra_auth = [...] if auth_key else []`，空列表展开（`*xpra_auth`）不产生任何 argv 元素。
3. shadow 分支的「先剔除 `--tcp-auth=`、再 `extend`」整段在 `if xpra_auth:` 里，无 key 时连过滤都不执行，上游命令原样保留。

桩件实测（口卡片段见验证命令 1）：`key=None` 与 `key="  "`（纯空白）时，两个分支的 `--tcp-auth` 计数都是 0、`XPRA_PASSWORD` 都不存在；`key="K3Y"` 时两边计数都是 1。空 key 之所以等价于「未设置」，是因为 `.strip()` 后为空——与 `serve.py:30` 对 `A0_AUTH_KEY` 的处理一致。

## 4. 验证命令

前置：`flatpak override --user --env=A0_AUTH_KEY=... org.agentzero.AgentZero`（或 `flatpak run --env=`），重启应用；旧会话不会自动换环境，必须先让桌面会话重建。

1. **纯代码证明（不需要跑应用）**：把上面的函数贴进 `/tmp` 桩件，对 shadow/headless × 无 key/空白 key/正常 key 各生成一次 argv，统计 `--tcp-auth` 个数与 `XPRA_PASSWORD`。期望：`0/0、0/0、1/1、1/1`（本轮已实测就是这四个结果）。
2. **会话重建**（`/api/plugins/_desktop/desktop_session`，`plugins/_desktop/api/desktop_session.py:25-26`）：
   ```bash
   KEY=...   # 与 A0_AUTH_KEY 相同
   curl -sS -X POST http://127.0.0.1:5080/api/plugins/_desktop/desktop_session \
     -H 'Content-Type: application/json' -H "X-API-Key: $KEY" \
     -d '{"action":"shutdown"}' ; echo
   curl -sS -X POST http://127.0.0.1:5080/api/plugins/_desktop/desktop_session \
     -H 'Content-Type: application/json' -H "X-API-Key: $KEY" \
     -d '{"action":"desktop"}' ; echo
   ```
   期望：第一条 `"shutdown": true`，第二条返回 `available: true` 和 `xpra_port`。
3. **进程实况**：
   ```bash
   PID=$(pgrep -f 'xpra shadow' | head -1); echo "pid=$PID"
   tr '\0' '\n' < /proc/$PID/cmdline | grep -c -- '--tcp-auth=env'      # 期望 1
   tr '\0' '\n' < /proc/$PID/cmdline | grep -c -- '--ws-auth'          # 期望 0
   tr '\0' '\n' < /proc/$PID/environ | grep -c '^XPRA_PASSWORD='       # 期望 1
   ```
   取消 key（`flatpak override --user --unset-env=A0_AUTH_KEY …` 后重启）再跑同样的三条，期望 `0 / 0 / 0`，且第 5 条仍返回 200。
4. **认证真的生效**（"没有密码连不上"）：
   ```bash
   # 浏览器打开 http://127.0.0.1:14500/ 会要求输入密码；密码就是 A0_AUTH_KEY。
   LOG=$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/plugins/_desktop/profiles/agent-zero-desktop/xpra.log
   grep -c "Authentication required by 'env' authenticator module" "$LOG"   # 期望 ≥1
   ```
   再用错误密码连接（原生客户端，证明不是只挡浏览器）：
   ```bash
   XPRA_PASSWORD=wrong xpra attach tcp://127.0.0.1:14500/ 2>&1 | tail -5
   # 期望出现 authentication failed / 断开，而不是进入桌面
   ```
5. **回归**：`curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/` 仍然是 `200`。这是**预期**的：静态客户端页面本身不校验，被校验的是它升级出来的 WebSocket（`server/core.py:1177-1190` + `server/auth.py:141`）。不要把这个 200 当成没修好。

## 5. 风险与副作用

- **浏览器要输一次密码**。这是本缺陷要达到的效果，但会改变现有使用习惯：以前打开 14500 直接进桌面，现在会弹密码框。密码就是 `A0_AUTH_KEY`；档位是 hmac 挑战，不是明文（`auth/env.py` + `auth/sys_auth_base.py:95`）。
- **原生客户端必须带密码**，否则连不上。若有外部脚本用 `xpra attach` 接这个桌面，需要同步设置 `XPRA_PASSWORD`。
- **以 root 运行时的用户名校验**：`auth/sys_auth_base.py:45,52-53,72-77`，当进程以管理员身份运行时 `verify-username` 默认为真，客户端用户名必须等于服务端用户名，否则直接 `ValueError`。headless 分支本来就有这个语义，本次只是让 shadow 分支与之一致；user 安装不受影响。
- **会话需要重建才生效**：`_load_system_desktop_from_manifest_locked`（`desktop_session.py:643-692`）会复用已在跑的 Xpra，只改代码不重启桌面时旧进程仍无认证。验证前必须先 `action=shutdown`。
- **静态页面仍可匿名读取**：`net/websockets/handler.py:96-114` 的 `do_GET` 在处理 upgrade 请求时**不**调用 `handle_authentication`，所以 HTTP Basic（`XPRA_HTTP_AUTH_PASSWORD`）只能挡普通 GET，挡不住 WebSocket 升级——这条路不走，正确做法是 `--tcp-auth`（覆盖到 ws 升级后的 `tcp` socktype）。不要把「页面 200」误判成「会话开放」。
- **重复选项**：若上游将来在 `_xpra_shadow_command` 里加入 `--tcp-auth`，`if xpra_auth:` 的分支会先剔除再追加，保证恰好一个。

## 6. 是否影响镜像

**需要重建主包**：改的是 `flatpak/a0flatpak/desktop.py`，它随主包安装进 `/app/share/agent-zero/flatpak/a0flatpak/`。

---

# D2（功能）沙盒内找不到宿主 Chrome

## 1. 证据

先纠正一个前提：**`/usr/bin/google-chrome` 在沙盒里永远不会出现**，不是权限没生效的问题。

已安装的 build 确实是旧清单（`flatpak info` 实测）：

```
$ flatpak info --show-permissions org.agentzero.AgentZero
[Context]
shared=ipc;network;
sockets=pulseaudio;x11;
devices=dri;
filesystems=home;/run/udev:ro;
```

```
Commit: 44c0ae8315893f0ee43b867d3cc1d31219c29e24a7a9b8e0666501d9563bf96b
Date:   2026-11-01 11:30:12 +0000
```

而仓库里的 `flatpak/org.agentzero.AgentZero.yml:15-21` 已经是 `--filesystem=host`、`host-etc:ro`、`host-os:ro`。所以「manifest 写了但沙盒看不见」的原因是**这份 build 早于清单改动**，不是清单写错（`functional-probes.md:808` 的观察是同一件事）。

用一次性的 `--filesystem=` 覆盖（`flatpak run` 的临时参数，不改安装）实测权限生效后的真实布局：

```
$ flatpak run --user --command=sh --filesystem=host --filesystem=host-os:ro \
    --filesystem=host-etc:ro org.agentzero.AgentZero -c '...'
--- /opt ---
-rwxr-xr-x 1 nfsnobody nfsnobody 1034 Oct 29 04:20 /opt/google/chrome/google-chrome
--- /usr/bin ---
ls: cannot access '/usr/bin/google-chrome': No such file or directory
ls: cannot access '/usr/bin/google-chrome-stable': No such file or directory
--- /run/host/usr/bin ---
/run/host/usr/bin/google-chrome -> /etc/alternatives/google-chrome
/run/host/usr/bin/google-chrome-stable -> /opt/google/chrome/google-chrome
--- which ---
none
--- ldd missing ---
no missing libs
```

结论三条，都能复核：

1. `--filesystem=host` 把宿主 `/opt` 暴露在 `/opt`；`--filesystem=host-os:ro` 把宿主 OS 暴露在 `/run/host`，**不替换 `/usr`**。所以 `/usr/bin` 里只有 runtime 的东西。
2. `shutil.which("google-chrome*")` 依赖 `PATH`，而 `/opt/google/chrome` 与 `/run/host/usr/bin` 都不在 `PATH` 里 —— 即使权限全开，`which` 也一定返回 `None`。
3. Chrome 本体能跑：`ldd /opt/google/chrome/chrome | grep -c "not found"` = **0**；`/opt/google/chrome/google-chrome --version` → `Google Chrome 156.0.8078.79`；`--headless=new --dump-dom "data:text/html,<title>A0 Probe</title>"` → `rc=0` 并回显 DOM。宿主 Chrome 的 `/usr/bin/google-chrome-stable` 只是指向 `/opt/google/chrome/google-chrome` 的符号链接（`target-prep.md:219-220`），所以 `/opt` 那条才是真路径。

现状代码用桩件复核（`--filesystem=host` + `host-os`，不设 `A0_BROWSER_CHROME`）：

```
chrome (no env): None
```

设了 `A0_BROWSER_CHROME=/opt/google/chrome/google-chrome` 则：

```
chrome: /opt/google/chrome/google-chrome
```

即：**当前只能靠环境变量兜底**，而 `_CHROME_NAMES` 全是裸名字。

另外，Patchright 默认会加 `--no-sandbox`（`patchright/driver/package/lib/coreBundle.js`：`if (options.chromiumSandbox !== true) chromeArguments.push("--no-sandbox")`；全仓 `grep chromiumSandbox` 无结果，默认 false）。这一点很重要：沙盒里不带 `--no-sandbox` 启动 Chrome 会直接 FATAL：

```
FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:172] The SUID sandbox helper binary was found, but is not configured correctly. ... You need to make sure that /opt/google/chrome/chrome-sandbox is owned by root and has mode 4755.
```

也就是说，`/opt/google/chrome/chrome-sandbox` 在宿主上不是 setuid（或沙盒内不可用），而 Patchright 的默认参数正好绕开了它 —— 这条路径不需要改代码，只要别自己加 `chromiumSandbox=True`。

## 2. 当前代码

`flatpak/a0flatpak/browser.py:30-54`：

```python
CHROME_ENV = "A0_BROWSER_CHROME"

# Order matters: prefer the branded stable build, then the generic names.
_CHROME_NAMES = (
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "microsoft-edge-stable",
    "brave-browser",
)


def find_system_chrome() -> Path | None:
    """Return the host Chrome binary, or None when none is installed."""
    override = os.environ.get(CHROME_ENV, "").strip()
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_file() else None

    for name in _CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)
    return None
```

模块 docstring `flatpak/a0flatpak/browser.py:20-22` 也写着「then through the usual command names」，需要同步一句。

## 3. 建议改动

替换 `flatpak/a0flatpak/browser.py:32-54`（`CHROME_ENV` 保留在 `:30`），并把 docstring 的 `:20-22` 改成下面的句子：

docstring 原句：

```
Chrome is located through ``A0_BROWSER_CHROME`` first, then through the usual
command names. When no Chrome is found the original behaviour returns, so the
plugin reports its normal missing-binary error instead of crashing.
```

改后：

```
Chrome is located through ``A0_BROWSER_CHROME`` first, then through the usual
command names, then through the paths the sandbox exposes: ``/opt`` from
``--filesystem=host`` and ``/run/host`` from ``--filesystem=host-os``. The
sandbox keeps the runtime's ``/usr``, so a host ``/usr/bin/google-chrome`` is
never on ``PATH``. When no Chrome is found the original behaviour returns, so
the plugin reports its normal missing-binary error instead of crashing.
```

代码（已 `py_compile`）：

```python
# Order matters: prefer the branded stable build, then the generic names.
_CHROME_NAMES = (
    "google-chrome-stable",
    "google-chrome",
    "chromium",
    "chromium-browser",
    "microsoft-edge-stable",
    "brave-browser",
)

# Names on PATH are not enough inside the sandbox: /usr belongs to the runtime,
# so a host browser is reachable only where --filesystem=host and host-os mount
# it. /opt is the host's own tree; /run/host is where host-os appears. The
# branded launcher is a symlink into /opt, so both forms are listed.
_CHROME_PATHS = (
    "/opt/google/chrome/google-chrome",
    "/run/host/opt/google/chrome/google-chrome",
    "/run/host/usr/bin/google-chrome-stable",
    "/run/host/usr/bin/google-chrome",
    "/usr/lib/chromium/chromium",
    "/usr/lib/chromium-browser/chromium-browser",
    "/snap/bin/chromium",
)


def find_system_chrome() -> Path | None:
    """Return the host Chrome binary, or None when none is installed."""
    override = os.environ.get(CHROME_ENV, "").strip()
    if override:
        candidate = Path(override).expanduser()
        return candidate if candidate.is_file() else None

    for name in _CHROME_NAMES:
        found = shutil.which(name)
        if found:
            return Path(found)

    for candidate in _CHROME_PATHS:
        path = Path(candidate)
        if path.is_file():
            return path
    return None
```

`_patch_plugin_hooks()` 与 `apply()` 不动。

## 4. 验证命令

1. **权限到底生效没有**（重建之后的第一条）：
   ```bash
   flatpak info --show-permissions org.agentzero.AgentZero
   ```
   期望 `[Context]` 段里出现 `filesystems=host;host-etc:ro;host-os:ro;/run/udev:ro;`（顺序以 flatpak 输出为准）；并核对 `flatpak info org.agentzero.AgentZero | grep Commit` 已不是 `44c0ae83…`。
2. **沙盒内真实布局**：
   ```bash
   flatpak run --user --command=sh org.agentzero.AgentZero -c '
     command -v google-chrome google-chrome-stable || echo "not-on-path"
     ls -l /opt/google/chrome/google-chrome
     ls -l /run/host/usr/bin/google-chrome-stable
     ls -d /opt || echo "no /opt"'
   ```
   期望：`not-on-path`；`/opt/google/chrome/google-chrome` 存在（1034 B 的启动脚本）；`/run/host/usr/bin/google-chrome-stable -> /opt/google/chrome/google-chrome`。
3. **发现函数**（用应用自己的 venv，避免 import 不到依赖）：
   ```bash
   flatpak run --user --command=sh org.agentzero.AgentZero -c '
     export GIT_PYTHON_REFRESH=quiet
     V=$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv
     $V/bin/python - <<PY
   import sys; sys.path.insert(0, "/app/share/agent-zero/flatpak")
   from a0flatpak import browser
   print("chrome:", browser.find_system_chrome())
   PY'
   ```
   期望 `chrome: /opt/google/chrome/google-chrome`。**不设** `A0_BROWSER_CHROME` 也要是这个结果，否则就是没修好（改前实测为 `None`）。
4. **Chrome 在沙盒里能不能执行**（库与沙箱两件事一起验证）：
   ```bash
   flatpak run --user --command=sh org.agentzero.AgentZero -c '
     ldd /opt/google/chrome/chrome | grep "not found" || echo "no missing libs"
     /opt/google/chrome/google-chrome --version
     rm -rf /tmp/cprof
     /opt/google/chrome/google-chrome --headless=new --no-sandbox --disable-gpu \
       --user-data-dir=/tmp/cprof --dump-dom "data:text/html,<title>A0 Probe</title>" | tail -1'
   ```
   期望：`no missing libs`；`Google Chrome 156.0.8078.79`；最后一行是 `<html><head><title>A0 Probe</title></head>...`。
5. **端到端**：跑 `test-matrix.md:562-563` 的 C40/C41（`chrome: …` + `title: 'A0 Probe Title'`）。C41 要真的起 Chrome，属于会改状态的用例，按验收流程执行。

## 5. 风险与副作用

- **`--filesystem=host` 的语义**：它把宿主文件系统按真实路径暴露（`/opt` 直接可见），但 `/usr` 仍是 runtime 的。所以「更多 `--filesystem`」不能解决 `which` 的问题，只有绝对路径能。`host` 同时意味着工作区可以读写宿主文件 —— 这是本包的设计（`org.agentzero.AgentZero.yml:13-15` 的注释），不是本次引入的。
- **不应为此再加 `--filesystem=/opt/google/chrome:ro`**：清单已经用 `host` 覆盖；加窄路径只会在 build 上再挖一个定制点。旧文档（`functional-probes.md:812-832`）里那条 override 是旧 build 的临时绕行，重建后应撤掉。
- **`chrome-sandbox` 不是 setuid**：直接手跑 Chrome 必须 `--no-sandbox`，而 Patchright 默认就加（证据见上）。如果以后有人为了"安全"设 `chromiumSandbox=True`，浏览器会立刻起不来。
- **Chrome 的 dbus 噪音**：实测会打印 `Failed to connect to the bus`，不影响 `--dump-dom`；不要据此判定失败。
- **`is_file()` 会跟随符号链接**：`/run/host/usr/bin/google-chrome-stable` 只有在 `/opt` 也可达时才算命中；两条路径都列了，顺序保证优先用 `/opt`。
- **没改 `A0_BROWSER_CHROME` 的语义**：指向不存在的文件仍返回 `None` 并回落到原始行为，不新增静默回退。

## 6. 是否影响镜像

**需要重建主包**，而且是两件事一起：`a0flatpak/browser.py` 的代码，以及清单里的 `--filesystem=host*`（已安装 build 还没有）。只改代码不重建，`/opt` 仍不可见。

---

# D3（功能）`xiaomi-ocr` 没有 manifest —— 已排除，不是缺陷

## 1. 结论

`xiaomi-ocr:latest` 在 Models 扩展里有完整、可校验的 manifest。之前「manifests 下只有两个模型」的判断是**盘点方法**错了：只跑了 `find models/manifests -type f`，漏掉了 `manifests-v2` 新布局，而新布局的条目是**符号链接**，`-type f` 看不见。

`A0_OCR_MODEL` 的默认值 `xiaomi-ocr`（`flatpak/a0flatpak/ocr.py:26`、`flatpak/a0flatpak/parsers.py:30`）是**正确**的，不需要改，也不需要补 manifest。

## 2. 证据链

全部来自 `docs/manual-acceptance/a0lite-deploy/models-inventory.md`（只读核验，本机 Models commit `f011ae9b…`，5.4 GB）：

```
$ ls -la $M/models/manifests-v2/ollama.com/library/xiaomi-ocr
lrwxrwxrwx ... latest -> ../../../../blobs/sha256-a3420f7b17e0827c9a477ff4395172e2e582fdc62b606044b6ca7c08e378c79a
```

- manifest 本体 824 B，`schemaVersion: 2`，`runner: llamacpp`，`format: gguf`；引用 config 120 B、模型层 529,297,664 B、投影层 207,346,624 B、参数层 33 B。
- 四层的声明体积与实际文件体积逐条相等；文件名摘要与内容 `sha256` 逐字节吻合（含 `1e497ff0…`、`634d6bc9…` 两个 GGUF）。
- 两个 GGUF 的文件头：主模型 `general.architecture=qwen35`、`general.name="Xiaomi OCR 0"`；投影器 `general.architecture=clip`、`general.type=mmproj`。
- ollama 0.40.13 的 `manifest/paths.go:resolveManifestPath` 先查 `manifests-v2`（`os.Stat` 跟随符号链接），未命中才回落 `manifests/`；`manifest/manifest.go:openManifestFileLocked` 对「symlink → `blobs/sha256-*`」有专用分支（`sameFile` + 内容摘要校验），并且该分支在「禁止解析到目录外」的检查之前 `return`。
- `namedManifestRefs` 用 `os.Lstat` 收集条目，`!fi.IsDir()` 即视为文件条目，所以 `/api/tags` 会列出 `xiaomi-ocr:latest`。
- 二进制 `strings` 里 `qwen35` 49 处、`qwen3vl_merger` 1 处，说明后端认识这两个架构。
- 目标机的既有记录一致：`recon-target.md:324` 的 `/api/tags` 有 `xiaomi-ocr:latest`，`target-prep.md:171` 的 `ollama list` 是 `0.74 GB`。

## 3. 以后怎么正确检查（这条方法论有复用价值）

1. 先看**两套** manifest 目录，且要看链接：
   ```bash
   M=~/.local/share/flatpak/runtime/org.agentzero.AgentZero.Models/x86_64/1.0/active/files/models
   ls -laR "$M/models/manifests-v2/ollama.com/library" 2>/dev/null
   ls -la  "$M/models/manifests/registry.ollama.ai/library" 2>/dev/null
   find "$M/models" -type l -printf '%p -> %l\n'     # 符号链接条目
   find "$M/models" -xtype l                          # 断链（期望为空）
   ```
2. 运行中的 Ollama 上做一次真实问询（这条才是最终判据，因为 `manifests-v2` 也参与解析）：
   ```bash
   curl -sS http://127.0.0.1:11434/api/tags \
     | python3 -c 'import json,sys; print([m["name"] for m in json.load(sys.stdin)["models"]])'
   curl -sS -o /dev/null -w 'show=%{http_code}\n' http://127.0.0.1:11434/api/show \
     -d '{"model":"xiaomi-ocr"}'
   curl -sS -o /dev/null -w 'gen=%{http_code}\n' http://127.0.0.1:11434/api/generate \
     -d '{"model":"xiaomi-ocr","prompt":"hi","stream":false,"options":{"num_predict":1}}'
   ```
   判据：`show`/`gen` 都是 200 且 `gen` 的响应体有非空 `response` 字段 = 可加载、可推理；404 或 `{"error":"model ... not found"}` = 名称解析失败；500 = manifest 存在但加载失败（那是资源/后端问题，与清单无关）。`ocr.py` 实际走的是 `/api/chat`（`ocr.py:48`），也可以用同样的方式打一次。
3. 不要用 `find ... -type f` 单独下结论，也不要只依据文件体积。

## 4. 风险与副作用

无。D3 不改代码、不改数据、不重建任何包。

唯一仍未验证的是**一次真实推理**（加载权重、建 KV cache、出字）。`models-inventory.md` 第 5.4 节明确写了这一条边界；它属于 D4 的验证范围（D4 的探针会实际打 `/api/chat`）。如果那时 OCR 返回非 200，应按上面的判据区分「清单/名称」与「资源」。

## 5. 是否影响镜像

否。

---

# D4（功能/超时）文档解析的 60 秒 vs OCR 的 300 秒

## 1. 证据：真实的机制

- `plugins/_document_query/helpers/document_query.py:468`：`per_doc_timeout = self.config.get("per_document_timeout", 60)`；`:470-475` 传给 `_parse_document`；`:509-514` 再传给 `parser.parse(..., timeout=timeout, ...)`。
- `plugins/_document_query/helpers/parsers/base.py:40`：`timeout: float = 60.0`；`:45-48` 用 `asyncio.wait_for(asyncio.to_thread(self._parse_sync, document, config), timeout=timeout)`；`:54-58` 把 `asyncio.TimeoutError` 转成 `ValueError("Document parsing timed out after {timeout}s: ...")`。
- `document_query.py:505-525`：`_parse_document` 逐个 parser `try/except Exception`，超时只记入 `errors_seen` 并**换下一个 parser**；全部失败后 `:522-525` 抛 `No parser succeeded for mimetype '…' (uri): <每个 parser 的错误>`。
- 所以 `wait_for` 包的是**单个 parser 的一次调用**，不是整份文档的多 parser 流程 —— 但它包住了我们 `_parse_sync` 里的**整个页循环**（`flatpak/a0flatpak/ocr.py:108`），这才是关键。
- `flatpak/a0flatpak/ocr.py:27`：`OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "300"))`，`:61` 作为 httpx 的 `timeout`。`flatpak/a0flatpak/parsers.py:31`、`:134` 有同样的 300。
- 结论：**300 s 的 httpx 超时永远不会被用到**。一次视觉请求只要超过 60 s，外层就先抛 `ValueError`；线程还在跑（`to_thread` 不可取消），`async with semaphore` 也已经退出 —— 于是"并发上限"在最坏情况下失效，而用户看到的是一句 `Document parsing timed out after 60s`。
- PDF 还有一层：`parsers/__init__.py:10-17` 的顺序是 `LiteParseParser` → `PdfParser` → … → `UnstructuredParser`；`liteparse.py:82` 自己也读 `per_document_timeout` 当子进程超时。所以一份扫描件在 `PdfParser` 之前还可能先被 LiteParse 吃掉一个 60 s（`liteparse_enabled` 默认 true，`liteparse.py:46-47`）。
- 配置落点：`plugins/_document_query/default_config.yaml:8`（`per_document_timeout: 60`）、`:9`（`gather_timeout: 120`）、UI 在 `webui/config.html:12`（默认值）与 `:105-111`（输入框，标题 "Per-document timeout"）。按 `plugin.yaml` 的 `per_project_config: true`，值存在插件配置里，运行时改，不需要重建。

## 2. 当前代码

`flatpak/a0flatpak/ocr.py:20-27`：

```python
import base64
import io
import os
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
OCR_MODEL = os.environ.get("A0_OCR_MODEL", "xiaomi-ocr")
OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "300"))
```

`flatpak/a0flatpak/ocr.py:44-66`（单次请求，超时是 300）：

```python
def _vision_markdown(image_bytes: bytes, prompt: str = WHOLE_PAGE_PROMPT) -> str:
    import httpx

    response = httpx.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": OCR_MODEL,
            "stream": False,
            "options": {"temperature": 0},
            "messages": [
                {
                    "role": "user",
                    "content": prompt,
                    "images": [_encode_image(image_bytes)],
                }
            ],
        },
        timeout=OCR_TIMEOUT,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload.get("message") or {}
    return str(message.get("content") or "").strip()
```

`flatpak/a0flatpak/ocr.py:105-109`（一次调用里循环所有页，且先渲染全部页）：

```python
        content = getattr(document, "content", b"") or b""
        if not content:
            return ""
        parts = [_vision_markdown(page) for page in _pdf_pages(content)]
        return "\n\n".join(part for part in parts if part)
```

## 3. 建议改动

**取向**：让 `ocr.py` 自己守住 parser 层的预算，而不是让用户去猜两个超时的关系。

- `A0_OCR_TIMEOUT` 默认 **300 → 45**：单次视觉请求必须显著小于 60 s。
- 新增 `A0_OCR_MAX_PAGES`，默认 **4**：多页扫描件不再无上限。
- 再多一层：从 `config["per_document_timeout"]` 推出**本次文档的截止时间**（留 5 s 余量），每页取 `min(45, 剩余)`。这样 `2 × 45 s > 60 s` 的漏洞也被堵住，而且不需要用户同时调两个旋钮。
- 超时变成**可读返回文本**：已完成的页照常返回，末尾加一行显式说明；一页都没完成时才抛错（没有内容就不伪造内容）。
- 渲染也只渲染上限内的页（`document.page_count` 另取），避免为 200 页的 PDF 先渲染 200 张 PNG。

替换 `flatpak/a0flatpak/ocr.py:18-111`（从 `from __future__` 到 `_parse_pdf_with_fallback` 结束，`apply()` 不动）。已 `py_compile`，并验证了 `_document_budget` 的三个分支（60 → 55、缺省 → 55、非法值 → 55）：

```python
from __future__ import annotations

import base64
import os
import time
from typing import Any

OLLAMA_URL = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434").rstrip("/")
OCR_MODEL = os.environ.get("A0_OCR_MODEL", "xiaomi-ocr")
# One vision request. The parser layer gives a whole document 60 s by default
# (``per_document_timeout``), so a single request must stay well below it.
OCR_TIMEOUT = float(os.environ.get("A0_OCR_TIMEOUT", "45"))
# Pages sent from one document. The page loop runs inside a single parser
# call, so this cap and the deadline below keep it inside that call's budget.
OCR_MAX_PAGES = int(os.environ.get("A0_OCR_MAX_PAGES", "4"))
# Seconds kept back for rendering, transport and the response itself.
OCR_MARGIN = 5.0

WHOLE_PAGE_PROMPT = (
    "Extract all information from the main body of the document image and "
    "represent it in markdown format, ignoring headers and footers. "
    "Tables should be expressed in OTSL format, formulas in LaTeX."
)

# Rendered page width in pixels. Higher values keep small text legible at the
# cost of more vision tokens.
PAGE_RENDER_WIDTH = int(os.environ.get("A0_OCR_PAGE_WIDTH", "1600"))


def _encode_image(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def _document_budget(config: dict) -> float:
    """The caller's own limit for this document, minus room to return."""
    try:
        limit = float(config.get("per_document_timeout", 60))
    except (TypeError, ValueError):
        limit = 60.0
    return max(limit - OCR_MARGIN, OCR_MARGIN)


def _vision_markdown(
    image_bytes: bytes,
    prompt: str = WHOLE_PAGE_PROMPT,
    timeout: float = OCR_TIMEOUT,
) -> str:
    import httpx

    response = httpx.post(
        f"{OLLAMA_URL}/api/chat",
        json={
            "model": OCR_MODEL,
            "stream": False,
            "options": {"temperature": 0},
            "messages": [
                {
                    "role": "user",
                    "content": prompt,
                    "images": [_encode_image(image_bytes)],
                }
            ],
        },
        timeout=timeout,
    )
    response.raise_for_status()
    payload = response.json()
    message = payload.get("message") or {}
    return str(message.get("content") or "").strip()


def _pdf_pages(content: bytes) -> tuple[list[bytes], int]:
    """Render the pages this module will send, and report the real page count."""
    import pymupdf

    pages: list[bytes] = []
    document = pymupdf.open(stream=content, filetype="pdf")
    try:
        total = document.page_count
        for index in range(min(total, OCR_MAX_PAGES)):
            page = document[index]
            rect = page.rect
            zoom = PAGE_RENDER_WIDTH / max(rect.width, 1)
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom))
            pages.append(pixmap.tobytes("png"))
    finally:
        document.close()
    return pages, total


def _ocr_pages(pages: list[bytes], total: int, config: dict) -> str:
    """Send pages to the vision model, never past the caller's deadline."""
    budget = _document_budget(config)
    deadline = time.monotonic() + budget
    parts: list[str] = []
    processed = 0
    stopped = ""
    for index, page in enumerate(pages):
        remaining = deadline - time.monotonic()
        if remaining <= OCR_MARGIN:
            stopped = f"the {budget:.0f}s document budget ran out"
            break
        try:
            text = _vision_markdown(page, timeout=min(OCR_TIMEOUT, remaining))
        except Exception as exc:
            stopped = f"{type(exc).__name__}: {exc}"
            break
        processed += 1
        if text:
            parts.append(text)
    if processed == 0:
        reason = stopped or "no page was sent"
        raise ValueError(f"OCR processed no page of {total} ({reason})")
    if processed < total:
        reason = stopped or f"A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
        parts.append(
            f"> OCR incomplete: {processed} of {total} pages processed ({reason})."
        )
    return "\n\n".join(parts)


def _parse_image(document: Any, config: dict) -> str:
    content = getattr(document, "content", b"") or b""
    if not content:
        return ""
    budget = _document_budget(config)
    try:
        return _vision_markdown(content, timeout=min(OCR_TIMEOUT, budget))
    except Exception as exc:
        raise ValueError(
            f"OCR failed within {min(OCR_TIMEOUT, budget):.0f}s: "
            f"{type(exc).__name__}: {exc}"
        ) from exc


def _parse_pdf_with_fallback(original: Any):
    def parse(self, document: Any, config: dict) -> str:
        # The original extractor is the optional strategy here: PyMuPDF and the
        # Tesseract fallback both fail when their native pieces are absent, and
        # that is exactly when the Ollama pass below must take over.
        try:
            text = original(self, document, config)
        except Exception:
            text = ""
        if isinstance(text, str) and text.strip():
            return text
        if not config.get("pdf_ocr_fallback", True):
            return text if isinstance(text, str) else ""
        content = getattr(document, "content", b"") or b""
        if not content:
            return ""
        pages, total = _pdf_pages(content)
        return _ocr_pages(pages, total, config)

    return parse
```

注意两处语义变化，都是有意为之：

- 数字型 PDF 仍先走原提取器；只有「无文本层」或「原提取器异常」才进视觉回退（与 `pdf.py:14-23` 的语义一致）。
- 部分失败时返回的是**真实识别文本 + 一行显式说明**，不是空串，也不是伪造内容。说明用英文，和 `WHOLE_PAGE_PROMPT`、上游 `Document parsing timed out…` 的语言保持一致。

`flatpak/a0flatpak/parsers.py:31`、`:119-141` 的兜底 OCR 有同样的 300 s 与无页数上限。它排在 `PdfParser` 之后，只在 `PdfParser` 失败/返回空时才跑；建议同批把 `OCR_TIMEOUT` 默认改成 45，并给它的页循环加同一个上限（可以复用 `ocr.py` 的常量），否则第二条路还会再吃一个 60 s。本次不强制，但它不是死代码，`UnstructuredParser` 对任意 mimetype 都兜底。

地方上要不要同时调 `per_document_timeout`？**默认不要动**。上面这版已经把行为收进 60 s；只有当用户确实要让 8 页扫描件做完时，才在 Document Query 的插件设置里把 "Per-document timeout" 调到 300（或 `gather_timeout` 相应放大），这是运行时配置，不需要重建。

## 4. 验证命令

前置：需要一个**没有文本层**的 PDF，且必须放在 `$HOME` 下（沙盒的 `/tmp` 是私有目录，宿主写进去的沙盒看不到——`functional-probes.md:1158` 已实测）。

1. **生成 3 页扫描件**（宿主上执行）：
   ```bash
   python3 - <<'PY'
   import pymupdf
   src = pymupdf.open()
   for i in range(3):
       page = src.new_page(width=595, height=842)
       page.insert_text((72, 120), f"Page {i+1}: invoice 42", fontsize=18)
   src.save("/tmp/scan-src.pdf"); src.close()

   text_pdf = pymupdf.open("/tmp/scan-src.pdf")
   out = pymupdf.open()
   for page in text_pdf:
       pix = page.get_pixmap(dpi=150)
       rect = pymupdf.Rect(0, 0, pix.width, pix.height)
       out.new_page(width=rect.width, height=rect.height).insert_image(rect, pixmap=pix)
   text_pdf.close()
   out.save("/home/kunweiz/scan-3p.pdf"); out.close()
   print("pages:", pymupdf.open("/home/kunweiz/scan-3p.pdf").page_count)
   PY
   ```
   期望 `pages: 3`；`pdftotext /home/kunweiz/scan-3p.pdf -` 输出为空（确认没有文本层）。
2. **计时解析（parser 层，最短路径）**：
   ```bash
   flatpak run --user --command=sh org.agentzero.AgentZero -c '
   export GIT_PYTHON_REFRESH=quiet
   export PYTHONPATH=/app/share/agent-zero/flatpak:/app/share/agent-zero
   V=$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero/venv
   $V/bin/python - <<PY
   import asyncio, time
   from a0flatpak import ocr, parsers
   ocr.apply(); parsers.apply()
   from plugins._document_query.helpers.fetch import FetchedDocument
   from plugins._document_query.helpers.parsers.pdf import PdfParser
   path = "/home/kunweiz/scan-3p.pdf"
   data = open(path, "rb").read()
   doc = FetchedDocument(uri=path, source_uri="file://" + path, scheme="file",
                         mimetype="application/pdf", content=data, local_path=path)
   t0 = time.monotonic()
   try:
       text = asyncio.run(PdfParser().parse(doc, {"per_document_timeout": 60}, timeout=60))
       print("OK", round(time.monotonic() - t0, 1), "s ->", text[:200].replace("\n", " "))
   except Exception as e:
       print("FAIL", round(time.monotonic() - t0, 1), "s ->", type(e).__name__, e)
   PY'
   ```
   改前期望：`FAIL ~60.0 s -> ValueError Document parsing timed out after 60s: /home/kunweiz/scan-3p.pdf`（与 `base.py:58` 的文案一致）。
   改后期望：`OK <55> s -> ...`，且返回文本里能看到页面文字；若模型偏慢，返回文本末尾出现 `> OCR incomplete: N of 3 pages processed (…)`，仍然是 `OK`，不再整份失败。
3. **工具层的同一现象**：走 `document_query` 工具时，日志里先出现 `Document parser failed: PdfParser: Document parsing timed out after 60s`（`base.py:55-57`），随后工具返回 `No parser succeeded for mimetype 'application/pdf' (…): PdfParser: …; UnstructuredParser: …`（`document_query.py:522-525`）。改后这两条都应消失，或只剩一条明确的 `> OCR incomplete` 说明。
4. **环境变量确实生效**：`A0_OCR_TIMEOUT` 在模块导入时求值（`ocr.py:27`），所以要改就改在进程启动之前。三种来源都行：`flatpak run --env=A0_OCR_TIMEOUT=45`、`flatpak override --user --env=A0_OCR_TIMEOUT=45`、`usr/.env` 里的同名键。最后一种之所以有效，是因为 `a0flatpak/__init__.py:34-36` 的 `dotenv.load_dotenv()` 排在 `:58` 的 `from a0flatpak import ocr` 之前。已经跑起来的进程不受影响——改完 `.env` 必须重启应用。

## 5. 风险与副作用

- **慢机器上单页可能真的超过 45 s**：那时该页会被判超时，返回 `> OCR incomplete: 0 of N`（若第一页就超时则抛错）。用户可以用 `A0_OCR_TIMEOUT` 调大到 55（仍要小于 `per_document_timeout`），或者直接把插件设置里的 "Per-document timeout" 调大 —— 后者才是正确的旋钮。
- **页数上限会截断长文档**：默认 4 页，超出部分不解析，返回文本里显式写明。要全量解析就调大 `A0_OCR_MAX_PAGES`，同时把 `per_document_timeout` 一起调大，否则会在预算处停下（同样有说明）。这是有意的取舍：宁可给出前几页 + 一句真话，也不要静默丢弃或让整份失败。
- **改变了返回值形态**：以前超时就抛错；现在"部分成功"会返回带 `>` 引用的 Markdown。这会进入索引（`document_query.py:476-486`），检索时会看到那行说明。它是真话，不是噪音，但需要知道。
- **`to_thread` 不可取消的老问题仍在**：即使我们提前返回，正在进行的那个 HTTP 请求仍会跑到 `min(45, 剩余)` 为止；`async with semaphore` 在返回时就释放，所以并发上限在这段时间内是"名义上的"。这是 `base.py:45-47` 的既有语义，本补丁只能缩短窗口（300 → 45），不能消除。
- **`parsers.py` 的第二条 OCR 路径**：如不同批改，`UnstructuredParser` 兜底仍会再花最多 60 s 并同样失败。功能上不会更坏，但会拖长失败时间。
- **`A0_OCR_TIMEOUT` 的旧值 300 不会自动迁移**：如果有人已经在 override 或 `usr/.env` 里写了 300，它会覆盖新默认值，需要一并清掉。

## 6. 是否影响镜像

**需要重建主包**：改的是 `flatpak/a0flatpak/ocr.py`（以及可选的 `parsers.py`）。

---

# D5（文档/配置）WPS MCP 配置与真实安装不符

## 1. 当前文件原文

`flatpak/wps-mcp-config.json`（10 行，全文）：

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

## 2. 证据

- 本机 WPS 扩展是 **user 安装**（`flatpak list` 的 Installation 列是 `user`），`/var/lib/flatpak/app/org.agentzero.AgentZero.Wps` 不存在（`functional-probes.md:1020` 已实测）。
- 扩展的 `files/bin/` 下**只有 `bun` 与 `wps-mcp`，没有 `node`**（`:1020`；本轮 `ls` 复核一致）。
- `flatpak/wps-mcp.sh:15-17`：`EXT_ROOT="/app"`、`BUN="$EXT_ROOT/bin/bun"`、`SERVER="$EXT_ROOT/wps-skills/wps-office-mcp/dist/index.js"`；`:29` `exec "$BUN" "$SERVER" "$@"`。**用 bun，不用 node**；而 `EXT_ROOT="/app"` 只在 `flatpak run --command=wps-mcp` 的挂载命名空间里成立。
- 因此**直接执行 `files/bin/wps-mcp` 会失败**（本轮实测）：
  ```
  $ ~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/wps-mcp </dev/null
  wps-mcp: bun is missing from the extension
  rc=1
  ```
  这条要一并纠正 `functional-probes.md:1037-1040` 里的建议写法：那不是可用配置，只适合 `flatpak run --command=wps-mcp`。
- `flatpak run --user --command=wps-mcp org.agentzero.AgentZero.Wps </dev/null` 正常退出（`rc=0`），说明入口本身在挂载命名空间里是对的。
- 宿主没有 WPS Office 时的握手：本轮实测 `initialize` + `tools/list` 成功，`rc=0`，`tools/list` 返回 **250** 个工具（`serverInfo.name = wps-office-mcp`，`protocolVersion = 2024-11-05`）。
- 但依赖 add-in 的调用会**阻塞**，不是立刻报错：`wps_check_connection` 单独调用 20 s 内没有任何 JSON-RPC 响应；`wps_check_connection` + `wps_get_active_document` 两个调用 80 s 仍未返回。源码侧对应 `dist/client/mac-poll-server.js:415`（`executeCommand(action, params, timeout = 30000)`）与 `:436-441`（30 s 后 `reject("Command timeout after 30000ms: …")`），轮询端口 58891（`dist/client/wps-client.js:66`）。
- 结论：**没有 WPS 时，MCP server 能 initialize、能列工具；依赖 add-in 的工具会阻塞**。`tools/list` 实测 250 个；其中只有 4 个缓存类工具（`wps_cache_data` / `wps_get_cached_data` / `wps_list_cache` / `wps_clear_cache`）按名称与职责不碰 58891，其余（含 `wps_check_connection`，实测 20 s 内无响应）都走 `execMacPoll` → 58891。按源码，这类调用应在 30 s 后以 `Command timeout after 30000ms` 返回（[INFERENCE]：实测只到 20 s / 80 s 两个观察点，没有取到那条错误的原文）。

## 3. 建议改动

`flatpak/wps-mcp-config.json` 整文件替换为 **user 安装**的写法（`kunweiz` 是当前用户名；文档里用 `$HOME` 的展开值，不要留 `~`，MCP 客户端不会替你展开）：

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

system 安装把同一前缀换成 `/var/lib/flatpak`：

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
      "args": [
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

第三种写法（不关心安装路径时更省事，但**只能由沙盒外、能访问会话总线的客户端**使用）：

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/usr/bin/flatpak",
      "args": ["run", "--user", "--command=wps-mcp", "org.agentzero.AgentZero.Wps"]
    }
  }
}
```

`command`/`args` 的配对原则：`command` 必须是**真正可执行**的那个；`args` 只放脚本路径，不要把 `bin/wps-mcp` 当 command 再传 `dist/index.js`（那会变成 `bun` 的两个位置参数，第二个被当成脚本参数，入口脚本本身也不接受它）。

README 里对应的一句（`flatpak/README.md:238-240`）也要一起改，否则读者仍会按旧的 system 路径理解：

- 原句：``Then register the server with Agent Zero by pasting `flatpak/wps-mcp-config.json` into the MCP settings, replacing `/var/lib/flatpak` when the installation lives elsewhere.``
- 改后：``Then register the server with Agent Zero by pasting `flatpak/wps-mcp-config.json` into the MCP settings; the file uses the per-user path (`~/.local/share/flatpak`), so replace it with `/var/lib/flatpak` only for a system-wide install.``

**不需要重建任何包**：`wps-mcp-config.json` 没有被安装进 bundle（`flatpak/org.agentzero.AgentZero.yml:165-168` 只装了 launcher、desktop、metainfo、icon；全仓 grep 也没有把它拷进 `/app`），它是给人粘贴的片段。改完重新粘贴到 Settings → MCP 即可。

## 4. 验证命令

1. **确认路径与可执行体**：
   ```bash
   R=~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files
   ls -l "$R/bin" "$R/wps-skills/wps-office-mcp/dist/index.js"
   command -v node; echo "node-rc=$?"      # 期望非 0：宿主也不该依赖它
   ```
2. **用粘进设置的那对 command/args 做一次握手**（不改任何状态）：
   ```bash
   python3 - <<'PY'
   import json, os, subprocess
   ROOT = os.path.expanduser("~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files")
   msgs = [
       {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"mcp-probe","version":"0"}}},
       {"jsonrpc":"2.0","method":"notifications/initialized"},
       {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}},
   ]
   p = subprocess.run([os.path.join(ROOT,"bin","bun"), os.path.join(ROOT,"wps-skills/wps-office-mcp/dist/index.js")],
                      input="".join(json.dumps(m)+"\n" for m in msgs),
                      capture_output=True, text=True, timeout=90)
   print("rc:", p.returncode)
   first = json.loads(p.stdout.splitlines()[0])
   second = json.loads(p.stdout.splitlines()[1])
   print(first["result"]["serverInfo"], first["result"]["protocolVersion"])
   print("tools:", len(second["result"]["tools"]))
   PY
   ```
   期望：`rc: 0`；`{'name': 'wps-office-mcp', 'version': '1.0.0'} 2024-11-05`；`tools: 250`（本轮实测值）。
3. **确认那条错误的写法确实失败**（防止有人再抄回去）：
   ```bash
   ~/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/wps-mcp </dev/null; echo "rc=$?"
   ```
   期望 `wps-mcp: bun is missing from the extension` + `rc=1`。
4. **在 Agent Zero 里真正挂上**：Settings → MCP 里保存后，重启应用，工具列表里出现 `wps_*`；宿主没有 WPS 时，`wps_check_connection` 会阻塞到命令超时（30 s，按 `mac-poll-server.js:436-441`；实测 20 s 内无响应），这是预期，不是配置错。

## 5. 风险与副作用

- **没有 WPS 时业务工具会阻塞约 30 s**：这不是配置问题，是 server 的轮询设计（`mac-poll-server.js:415,436-441`）。验收时不要把这段等待记成配置错误；也不要把它放到会被反复调用的自动流程里。
- **user 路径硬编码了用户名**：换用户/换机器要改。system 安装用 `/var/lib/flatpak` 那份。
- **`flatpak run` 那种写法依赖会话总线**：Agent Zero 自己跑在主包沙盒里时，`/usr/bin/flatpak` 不在 runtime 里、也没有 `org.freedesktop.Flatpak` 端口权限，所以**不要**把它填进 Agent Zero 的 MCP 设置；它只适合宿主上的客户端。
- **路径会随扩展更新而变化？** 不会：`current/active` 是稳定入口，更新后仍指向新 commit。

## 6. 是否影响镜像

**不影响**。只改仓库里的片段与 README 一句话，重新粘贴到 MCP 设置即可。

---

# D6（文档）README 两处与实际不符

## 1. 现状核对

- `flatpak/README.md:185-186`（当前全文）：
  ```
  The desktop inherits the same key: the launcher passes it to Xpra as
  `XPRA_PASSWORD` and adds `--tcp-auth=env`, so Xpra validates logins itself.
  ```
  与 D1 的现状冲突：shadow 分支**没有**这两个东西。这句话在 D1 合入之后才成立，而且「the launcher」也不准确（是 `a0flatpak/desktop.py`，不是 `agent-zero.sh`）。
- `flatpak/README.md:254`：`| prompts/ | environment prompt override |` —— **已经是 `prompts/`**，上一轮改过了，`grep -n "plugin/" README.md` 无命中。这一条**不需要再改**。

## 2. 建议改动（只列句子）

改 `flatpak/README.md:185-186`：

- 原句：
  ```
  The desktop inherits the same key: the launcher passes it to Xpra as
  `XPRA_PASSWORD` and adds `--tcp-auth=env`, so Xpra validates logins itself.
  ```
- 改后（与 D1 合入后的实现一致）：
  ```
  The desktop inherits the same key on both paths: `a0flatpak/desktop.py` sets
  `XPRA_PASSWORD` from it and adds `--tcp-auth=env` for the host-display session
  and for the headless one, so Xpra asks for the key before it accepts a desktop
  connection. The HTML page itself is served without a key; the session behind
  it is not.
  ```

改 `flatpak/README.md:254`：**不改**（已是 `prompts/`）。

另有一句同属「与实际不符」，建议同批改（不在原始六条里，但就在同一节，改动成本一句话）：

- `flatpak/README.md:173-175` 原句：
  ```
  `A0_AUTH_KEY` turns on the check that the framework lacks. It is applied inside
  the process, at `UiServerRuntime.build_asgi_app`, so it covers the Flask routes,
  the MCP and A2A mounts and the socket.io channel at once:
  ```
  现状是 `flatpak/a0flatpak/serve.py:1-15,29-44` 把 `run_uvicorn_with_retries` 包起来，在 `build_asgi_app` 这个 kwarg 上做包装；`build_asgi_app` 本身是实例方法，直接补类方法会漏。改后：
  ```
  `A0_AUTH_KEY` turns on the check that the framework lacks. It is applied inside
  the process, where the serving stack is handed to uvicorn
  (`helpers.server_startup.run_uvicorn_with_retries`), so it covers the Flask
  routes, the MCP and A2A mounts and the socket.io channel at once:
  ```

## 3. 验证命令

```bash
cd /home/kunweiz/Desktop/a0lite
grep -n "tcp-auth\|XPRA_PASSWORD" flatpak/README.md
grep -n "plugin/" flatpak/README.md || echo "no stale plugin/ reference"
grep -n "build_asgi_app\|run_uvicorn_with_retries" flatpak/README.md
```
期望：第一条只命中改后那一段（`XPRA_PASSWORD` + `--tcp-auth=env`，且同段出现 "both paths"）；第二条输出 `no stale plugin/ reference`；第三条不再出现 `UiServerRuntime.build_asgi_app`。

## 4. 风险与副作用

无。文档句子与 D1 的实现是同一次改动，**D1 不合入就不要改成"两个分支都有"**——否则文档又说谎了。

## 5. 是否影响镜像

否。

---

# 优先级与合入顺序

## 必须改代码（三条，一次重建覆盖）

1. **D1（安全）**：无认证的远程桌面是这六条里唯一的安全问题，且 14500 有过被 frp 转发到公网的记录。先合。
2. **D4（功能）**：OCR 现在在真机上表现为"整份解析失败"，直接决定扫描件能不能用。与 D1 同批。
3. **D2（功能）**：浏览器工具当前只能靠 `A0_BROWSER_CHROME` 兜底；代码 + 清单权限都要重建才生效，正好与上面两条共用一次构建。

顺序建议：**D1 → D4 → D2（同一次重建）**。三者的改动互不相交（`desktop.py` / `ocr.py` / `browser.py`），可以并行改、一起验；但验证必须用**新 build**，因为 D2 依赖清单权限，旧 build 看不到 `/opt`。

## 只需改运行时/配置

4. **D5（WPS 配置）**：改片段 + 重贴 Settings → MCP。与重建无关，可在重建窗口之外随时做；注意宿主无 WPS 时业务工具会卡 30 s。

## 只需改文档

5. **D6（README）**：与 D1 同批改那两句（Authentication 那句依赖 D1 落地）；`prompts/` 那行已正确，不动。

## 已排除

6. **D3（xiaomi-ocr manifest）**：不成立。`manifests-v2/ollama.com/library/xiaomi-ocr/latest` 存在且可校验；默认模型名不改、不补数据、不重建 Models。要留下的只有方法论：以后核实 Ollama 模型必须同时看 `manifests/` 与 `manifests-v2/`，并用 `ls -la` / `find -type l` 看符号链接。

## 合入前的最后一道检查

- 三条代码改动都只碰 `flatpak/a0flatpak/` 下的单个模块，`py_compile` 已过；重建前再跑一次 `python3 -m py_compile flatpak/a0flatpak/{desktop,ocr,browser}.py`。
- D1 与 D6 必须同进同出（文档描述的是合入后的行为）。
- D2 的验收要看 `flatpak info --show-permissions` 的 `filesystems` 行，不是只看代码是否合并。
