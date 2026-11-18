# I / J / K 收尾验收：WPS MCP、systemd、资源与清理

执行时间：2026-11-18 01:30–01:36（Asia/Shanghai）
执行者：probe-ijk（收尾验收员）
对象：`org.agentzero.AgentZero` master，commit `0e6c5082…d456a4`（v8），user 安装；`org.agentzero.AgentZero.Wps` 1.0，user 安装。
约束遵守：未改仓库源码、未改 `conf/`、未改运行中的 `settings.json`；`flatpak kill` + 重启只做一次；未删 `chromium-1228`；临时文件在 `~/a0-local-backup/probe-ijk/`。

---

## 0. 结论摘要

| 类别 | 能判通过 | 不能判 / 环境不具备 | 关键结论 |
|---|---|---|---|
| I（WPS MCP） | 3 条（I.2 握手、I.3 列表缓存、I.5 影响面） | I.1 的 `test -x` 判据对 JS 入口不成立；I.4 运行实例未加载配置 | 沙盒内能启动并握手；250 工具；无 WPS 时文档类工具 30 s 超时；`usr/settings.json` 不存在，配置未进入运行时 |
| J（systemd） | 3 条（J.1 字段与实际一致、J.2 root 替换正确、J.3 应用层重启） | C53–C57 的 systemd 本体（enabled/restart/crash/reboot/journal） | 模板与 sed 逻辑正确；root 下路径替换逐项正确；手工重启 10 s 回到 health 200，但 xpra 不恢复；无 sudo、无 unit，systemd 本体未验 |
| K（资源与清理） | 5 条（K.1 核心进程、K.2 端口、K.3 目录、K.4 日志/OOM、K.6 磁盘） | K.5 仅验证“数据仍在”，未重装 | 无应用 OOM；最大非模型项是 `chromium-1228` 379 MB；`flatpak ps` 条目数不能当实例数 |

---

## 1. I 类：WPS MCP

### I.1 命令层：配置 JSON 与宿主路径

**目的**：确认 `flatpak/wps-mcp-config.json` 语法正确、`command` 与 `args` 指向真实存在的宿主路径。

**命令**：

```sh
cd /home/kunweiz/Desktop/a0lite
jq . flatpak/wps-mcp-config.json
H=$HOME/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files
test -x "$H/bin/bun" && echo 'bun OK'
test -x "$H/wps-skills/wps-office-mcp/dist/index.js" && echo 'dist OK'
ls -l "$H/bin/bun" "$H/wps-skills/wps-office-mcp/dist/index.js"
readlink -f "$H/bin/bun"
readlink -f "$H/wps-skills/wps-office-mcp/dist/index.js"
```

**原始输出（摘要）**：

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/usr/bin/flatpak-spawn",
      "args": [
        "--watch-bus",
        "--host",
        "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
        "/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

```text
bun OK
-rwxr-xr-x 2 kunweiz kunweiz 107260472 Jan  1  1970 .../files/bin/bun
-rw-r--r-- 2 kunweiz kunweiz      5186 Jan  1  1970 .../files/wps-skills/wps-office-mcp/dist/index.js
readlink bun -> .../x86_64/1.0/184cc3776f17b1fd5883cdbf0a3316c04f7e9535004b1c2067785fac37a23380/files/bin/bun
readlink dist -> .../x86_64/1.0/184cc3.../files/wps-skills/wps-office-mcp/dist/index.js
```

补测可读性与可执行性：

```text
dist: -r OK, -f OK, -x FAIL  (mode 644)
bun:  -x OK, -r OK
bun --version -> 1.4.4
```

**期望**：JSON 合法；两个路径存在；`command` 能被 MCP 客户端解析。

**实际**：
- `jq -e .` 通过，配置合法。
- `bun` 可执行（107 MB，bun 1.4.4）。
- `dist/index.js` 是 **644 的普通文件**，`test -x` **失败**；它是 bun 的入参，不需要可执行位，`test -r`/`-f` 成功。
- 两个路径经 `current/active` 解析到扩展的 `x86_64/1.0/184cc3…/files`，与扩展 commit 一致。
- 宿主 **没有** `/usr/bin/flatpak-spawn`（`command -v flatpak-spawn` 为空，`ls /usr/bin/flatpak-spawn` 报 No such file）；沙盒内 `ls -l /usr/bin/flatpak-spawn` 存在（49216 B，来自 `org.freedesktop.Platform`）。

**结论**：**部分通过**。配置本身可被沙盒内的 Agent Zero 解析；`test -x` 对 `dist/index.js` 是错误判据（应改 `test -r` 或 `test -f`）。若在宿主直接执行该配置会失败，因为宿主没有 `flatpak-spawn`；该配置的语义就是“在 A0 沙盒内调用宿主命令”。

---

### I.2 沙盒内握手（v8 talk-name 的关键验收点）

**目的**：证明主包沙盒内可以经 `flatpak-spawn --host` 启动 WPS MCP server 并完成 MCP 握手。

**命令**（`~/a0-local-backup/probe-ijk/mcp_probe.py`，核心）：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
  /usr/bin/flatpak-spawn --watch-bus --host \
    /home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun \
    /home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js'
```

stdin 依次写：`initialize`（protocolVersion `2024-11-05`）→ `notifications/initialized` → `tools/list`。

**原始输出**：

```text
== initialize (cold, 0.48s from spawn) ==
{
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {"tools": {}},
    "serverInfo": {"name": "wps-office-mcp", "version": "1.0.0"}
  },
  "jsonrpc": "2.0",
  "id": 1
}
== tools/list (0.004s) ==
tool_count=250
```

`tools/list` 的 `result` 只含 `tools`，不含 `serverInfo`/`protocolVersion`（MCP 规范如此）；`serverInfo` 取自 `initialize`。250 个工具含 `wps_check_connection`、`wps_get_active_document`、`wps_insert_text`、`wps_list_cache` 等。

**期望**：`serverInfo.name == "wps-office-mcp"`；`tools` 长度 > 0；打印协议版本。

**实际**：冷启动 **0.48 s**（从 `flatpak run` 进程启动到收到 `initialize` 响应）；协议 `2024-11-05`；工具 **250** 个；无 stdout 噪声行。进程在脚本 `kill` 后以 `exit=-9` 结束。

**结论**：**通过**。v8 主包的 `--talk-name=org.freedesktop.Flatpak` 足以让沙盒内的 A0 经 D-Bus 调用宿主 `flatpak-spawn`，扩展的 bun 与 MCP server 能在宿主启动并完成 stdio 握手。`flatpak info --show-permissions` 也确认 `org.freedesktop.Flatpak=talk` 已生效。

---

### I.3 两个工具调用

**目的**：验证缓存工具即时成功、连接检查在无 WPS 时的行为，并记录 `isError`。

**命令**：同一 stdio 会话内 `tools/call`：

```json
{"name":"wps_list_cache","arguments":{}}
{"name":"wps_check_connection","arguments":{}}
```

**原始输出**：

```text
== tools/call wps_list_cache (0.003s) ==
{"result":{"content":[{"type":"text","text":"{\"success\":true,\"count\":0,\"caches\":[]}"}],"isError":false},"jsonrpc":"2.0","id":3}

== tools/call wps_check_connection (30.01s) ==
{"result":{"content":[{"type":"text","text":"{\"connected\":false,\"status\":{\"connected\":false,\"error\":\"Connection check failed\"}}"}],"isError":false},"jsonrpc":"2.0","id":4}
```

**期望**：`wps_list_cache` 约 3 ms 内返回 `{"success":true,…}`；`wps_check_connection` 无 WPS 时约 30 s 返回 `connected:false`；记录 `isError`。

**实际**：
- `wps_list_cache` 0.003 s，`success:true`，`isError:false`。
- `wps_check_connection` 30.01 s，`connected:false`，`error:"Connection check failed"`，`isError:false`。
- 任务说“上游对前者不置 `isError`”；本轮实测 `wps_list_cache` 的 `isError` 字段**存在且为 `false`**，不是缺失。若别的上游版本确实缺失该字段，Agent Zero 的 MCP 客户端会按成功处理；真正需要记录的不一致是下一条。
- **已知不一致**：业务失败（`connected:false`）没有置 `isError:true`；而文档类工具（见 I.5）超时会置 `isError:true`。Agent Zero 侧无法只靠 `isError` 区分“业务未连接”和“工具失败”。

**结论**：**通过**（按用例的“能返回结构化结果”判据）。`wps_list_cache` 的 `isError:false` 是成功的正常值；真正的不一致在 `wps_check_connection`。

---

### I.4 配置解析层：Agent Zero 如何解析 `mcpServers`

**目的**：确认 `flatpak/wps-mcp-config.json` 的形态能否被 Agent Zero 正确解析。

**原始输出（关键源码）**：`/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero/helpers/mcp_handler.py`

关键行为：

```python
# line 118
def _split_stdio_command(command):
    text = str(command or "").strip()
    parts = shlex.split(text)
    return parts[0], parts[1:]

# line 145
def _normalize_stdio_args(value):
    for item in value:
        args.extend(_split_stdio_arg_fragment(str(item).strip()))

# line 1564
if not server.command:
    raise ValueError("Command not specified")
if not which(server.command):                 # shutil.which
    raise ValueError(f"Command '{server.command}' not found")
server_params = StdioServerParameters(
    command=server.command, args=server.args, env=server.env, ...)
```

并且 `helpers/settings.py`：

```python
SETTINGS_FILE = files.get_abs_path("usr/settings.json")
mcp_servers=get_default_value("mcp_servers", '{\n    "mcpServers": {}\n}')
```

解析过程的实际语义：

1. `command` 先 `shlex.split`；当前值 `/usr/bin/flatpak-spawn` 是单 token，结果不变。
2. `args` 逐项 `shlex.split`；`--watch-bus`、`--host` 与两个绝对路径都无空格、无引号、无 `~`，逐项原样保留。
3. 启动前用 `shutil.which(server.command)` 在当前进程的 `PATH` 中查；A0 在沙盒内运行，`/usr/bin/flatpak-spawn` 存在（I.1 已实测），**解析成功**。
4. `StdioServerParameters` 直接 `exec`，**不经 shell**；`env=None` 时继承 A0 进程环境；不展开 `~`、不做 `$VAR` 替换。当前配置全部是绝对路径，因此不受影响。
5. `mcp_servers` 是 **字符串** 字段（C49 用 `fromjson` 二次解析），不是对象。

**运行实例的实际状态（关键）**：

```sh
ls -l ~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/settings.json
# ls: cannot access '.../usr/settings.json': No such file or directory

jq -r '.mcp_servers | fromjson | .mcpServers["wps-office"].command' \
  ~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/settings.json
# jq: error: Could not open file .../usr/settings.json: No such file or directory
# RC=2
```

**期望**：配置 JSON 能被 `shlex.split` + `which` 正确处理，路径在 `~/.local/share/flatpak`。

**实际**：配置形态本身**能被正确解析**（command 是沙盒内存在的绝对路径；args 无空格、无 `~`；不经 shell）。但当前运行的 v8 实例 **没有 `usr/settings.json`**，因此 `get_settings()` 使用默认 `{"mcpServers": {}}`，WPS MCP **没有被运行时加载**。I.2/I.3 是“按该配置形态在沙盒内手工启动”的验证，不等于 A0 已注册该 server。

**结论**：**配置层通过，运行时注册未通过**。目标机需要把如下值写入 `$DATA/usr/settings.json` 的 `mcp_servers`（值必须是转义后的 JSON 字符串，而非对象）：

```json
{
  "mcp_servers": "{\"mcpServers\":{\"wps-office\":{\"command\":\"/usr/bin/flatpak-spawn\",\"args\":[\"--watch-bus\",\"--host\",\"<bun>\",\"<dist>\"]}}}"
}
```

本轮未改运行中的 `settings.json`，故未验证“写入后 A0 自动加载”的端到端路径；这属于目标机执行项。

---

### I.5 无 WPS 的影响面

**目的**：统计工具总数，说明“能握手但文档操作必然失败”的具体表现。

**命令**：同 I.2/I.3 的 stdio 会话，另调用：

```json
{"name":"wps_get_active_document","arguments":{}}
{"name":"wps_insert_text","arguments":{"text":"probe"}}
{"name":"wps_common_get_app_info","arguments":{}}
```

**原始输出**：

```text
== wps_get_active_document (69.78s) ==
{"result":{"content":[{"type":"text","text":"Command timeout after 30000ms: getActiveDocument"}],"isError":true},...}

== wps_insert_text (30.02s) ==
{"result":{"content":[{"type":"text","text":"Command timeout after 30000ms: insertText"}],"isError":true},...}

== wps_common_get_app_info (30.02s) ==
{"result":{"content":[{"type":"text","text":"获取应用信息出错: Command timeout after 30000ms: getAppInfo"}],"isError":true},...}
```

**期望**：工具总数 > 0；4 个跨应用缓存工具可立即成功；文档类工具在无 WPS 时超时但返回结构化错误，进程不崩溃、不挂起 > 90 s。

**实际**：总数 250；4 个缓存工具可用；抽取的 3 个文档工具分别在 69.78 s / 30.02 s / 30.02 s 后返回 `isError:true`；无崩溃、无 > 90 s 挂起。

**工具总数与分类**：
- 总数 **250**。
- 无 WPS 时能立即成功的是 4 个跨应用缓存工具：`wps_cache_data`、`wps_get_cached_data`、`wps_list_cache`、`wps_clear_cache`。
- 其余 246 个（Word/Excel/PPT/转换/通用）都通过 `127.0.0.1:58891` 等待 WPS 加载项；没有宿主 WPS 时，每个调用等待 **30 s**，返回可读错误，不崩溃、不无限挂起。
- `wps_check_connection` 单独 30.01 s 返回 `connected:false`。
- `wps_get_active_document` 实测 **69.78 s**（内部 30 s 超时后仍有重试/清理），仍 < 90 s，未触发 C52 的“挂起 > 90 s”失败判据。

**“能握手但文档操作必然失败”的具体表现**：
1. `initialize`/`tools/list` 完全正常，Agent Zero 会把 250 个工具注册进提示词与工具列表。
2. 模型一旦调用 `wps_word_*`/`wps_excel_*`/`wps_ppt_*`，会先卡 30 s，再收到 `isError:true` 的文本错误；对用户表现为“工具存在但每次都超时”。
3. 只有缓存 4 件套可用；它们与文档内容无关，不能替代文档操作。

**结论**：**通过（影响面已量化）**。在无 WPS 的机器上部署该扩展，应在提示词/文档中明确“仅握手与缓存可用，文档工具必然 30 s 超时”，或把 WPS 安装作为前置条件。

---

## 2. J 类：systemd 与重启自恢复

### J.1 静态核对

**目的**：核对两份 unit、`a0-desktop-start`、`install-services.sh` 与实际环境是否一致。

**命令**：

```sh
cat systemd/agent-zero.service systemd/agent-zero-desktop.service systemd/a0-desktop-start
cat scripts/install-services.sh
sh -n systemd/a0-desktop-start && echo OK
sh -n scripts/install-services.sh && echo OK
systemd-analyze verify systemd/agent-zero.service systemd/agent-zero-desktop.service
ls -l /etc/systemd/system/agent-zero*
systemctl --user list-unit-files 'agent-zero*'
journalctl -u agent-zero -n 5 --no-pager
```

**原始输出（关键）**：

```text
systemd/a0-desktop-start: OK
scripts/install-services.sh: OK
agent-zero-desktop.service: Command /usr/local/bin/a0-desktop-start is not executable: No such file or directory
（agent-zero.service 无其他输出）

ls: cannot access '/etc/systemd/system/agent-zero*': No such file or directory
0 unit files listed.
-- No entries --
```

**期望**：unit 的 `User`/`Group`/`Environment`/`RequiresMountsFor`/`Restart`/`RemainAfterExit` 与本机用户、运行目录、显示一致；两个脚本 `sh -n` 通过；`systemd-analyze verify` 只允许“未安装的可执行文件”一类错误。

**实际**：见下表；除 `/usr/local/bin/a0-desktop-start` 尚未安装外，无语法错误。另：`flatpak override --user --show org.agentzero.AgentZero` 输出为空，没有 `A0_AUTH_KEY`/模型 override；当前 `/api/health` 不要求 key，但 C54/C55 若通过受保护的 API 断言，需要先补这个前置。

**逐项核对**：

| 项目 | 模板值 | 本机实际 | 判断 |
|---|---|---|---|
| `User` / `Group` | `kunweiz` / `kunweiz` | UID 1000，GID 1001，组名 `kunweiz` | 一致 |
| `XDG_RUNTIME_DIR` | `/run/user/1000` | `/run/user/1000` 存在，`bus` 存在 | 一致 |
| `DBUS_SESSION_BUS_ADDRESS` | `unix:path=/run/user/1000/bus` | socket 存在 | 一致 |
| `DISPLAY` | `:0` | 应用进程 `DISPLAY=:0.0`；`/tmp/.X11-unix/X0` 存在 | 等价（`:0` 可连 `:0.0`） |
| `XAUTHORITY` | `/home/kunweiz/.Xauthority` | 文件存在（156 B，0600）；flatpak 运行时会改写成 `/run/flatpak/Xauthority` | 外层有效，内层由 flatpak 覆盖 |
| `WorkingDirectory` | `/home/kunweiz` | 存在 | 一致 |
| `RequiresMountsFor` | `/home/kunweiz` | `findmnt /home/kunweiz` 无独立挂载（btrfs subvol `/@`） | 无冲突，实际 no-op |
| `Restart` | `always`（agent-zero）/ `on-failure`（desktop） | 未安装，无法运行 | 静态可接受；desktop 的 `Type=oneshot` + `Restart=on-failure` 未被 `systemd-analyze verify` 报错 |
| `RemainAfterExit` | `yes`（desktop） | 未安装 | 与 oneshot 语义匹配 |
| `WantedBy` | `graphical.target` | 目标机需图形目标 | 与环境一致 |

**`install-services.sh` 的 root 替换（重点）**：

```sh
USER_NAME=${1:?usage: install-services.sh <user>}
UID_N=$(id -u "$USER_NAME")
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
sed -e "s|^User=kunweiz$|User=$USER_NAME|" \
    -e "s|^Group=kunweiz$|Group=$USER_NAME|" \
    -e "s|/run/user/1000|/run/user/$UID_N|g" \
    -e "s|/home/kunweiz|$HOME_DIR|g" ...
```

`root` 下：`id -u root` = `0`；`getent passwd root` = `root:x:0:0::/root:/usr/bin/bash`，`HOME_DIR=/root`。替换结果见 J.2。

**`a0-desktop-start` 的 `$HOME` 展开**：

```sh
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
...
"$B/venv/bin/python" -c 'import a0flatpak; a0flatpak.apply() ...'
```

- 若服务以 `User=root` 运行，systemd 为它设置 `HOME=/root`，因此 `B=/root/.var/app/org.agentzero.AgentZero/data/agent-zero`，`"$B/venv/bin/python"` 展开为 `/root/.var/app/.../venv/bin/python`。
- 这只有在 **应用也由 root 的 user 安装并跑过**（数据在 `/root/.var/app/...`）时才正确。
- 本机应用是 `kunweiz` 的 user 安装，数据在 `/home/kunweiz/.var/app/...`；root 服务会找不到 venv。**本机无法验证 root 形态**。

**结论**：**静态通过**（语法、字段、替换逻辑）；`systemd-analyze verify` 唯一的错误是 `/usr/local/bin/a0-desktop-start` 尚未安装（预期，因为本机没跑 `install-services.sh`）。本机没有 `/etc/systemd/system/agent-zero*.service`，没有 root 的 flatpak user 安装，也没有 `/run/user/0`，因此 systemd 本体未验。

---

### J.2 模拟安装（不写 `/etc`）：root 版 unit 与模板逐行 diff

**目的**：验证 `install-services.sh` 在 `root` 用户下的 sed 替换是否逐行正确。

**命令**：

```sh
T=$(mktemp -d)
for unit in agent-zero.service agent-zero-desktop.service; do
  sed -e 's|^User=kunweiz$|User=root|' \
      -e 's|^Group=kunweiz$|Group=root|' \
      -e 's|/run/user/1000|/run/user/0|g' \
      -e 's|/home/kunweiz|/root|g' systemd/$unit > $T/$unit
done
diff -u systemd/agent-zero.service $T/agent-zero.service
diff -u systemd/agent-zero-desktop.service $T/agent-zero-desktop.service
```

**原始输出（diff）**：

```diff
--- systemd/agent-zero.service
+++ agent-zero.service
@@
-RequiresMountsFor=/home/kunweiz
+RequiresMountsFor=/root
@@
-User=kunweiz
-Group=kunweiz
-Environment=XDG_RUNTIME_DIR=/run/user/1000
-Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
+User=root
+Group=root
+Environment=XDG_RUNTIME_DIR=/run/user/0
+Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
-Environment=XAUTHORITY=/home/kunweiz/.Xauthority
-WorkingDirectory=/home/kunweiz
+Environment=XAUTHORITY=/root/.Xauthority
+WorkingDirectory=/root
```

```diff
--- systemd/agent-zero-desktop.service
+++ agent-zero-desktop.service
@@
-User=kunweiz
-Group=kunweiz
-Environment=XDG_RUNTIME_DIR=/run/user/1000
-Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
+User=root
+Group=root
+Environment=XDG_RUNTIME_DIR=/run/user/0
+Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
-Environment=XAUTHORITY=/home/kunweiz/.Xauthority
+Environment=XAUTHORITY=/root/.Xauthority
```

**期望**：root 下的 `User`/`Group`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`/`XAUTHORITY`/`WorkingDirectory`/`RequiresMountsFor` 全部指向 root 的对应值，且没有残留 `kunweiz`/`/home/kunweiz`/`1000`。

**实际**：diff 见上，逐项结果如下表；无残留。

**结果核对**：

| 替换 | 结果 | 判断 |
|---|---|---|
| `User=kunweiz` → `User=root` | 两份 unit 均为 `User=root` | 正确 |
| `Group=kunweiz` → `Group=root` | 两份 unit 均为 `Group=root` | 正确 |
| `/run/user/1000` → `/run/user/0` | `XDG_RUNTIME_DIR` 与 `DBUS_SESSION_BUS_ADDRESS` 均变为 `/run/user/0` | 正确 |
| `/home/kunweiz` → `/root` | `XAUTHORITY`、`WorkingDirectory`、`RequiresMountsFor` 均变为 `/root` | 正确 |
| `RequiresMountsFor=/root` | 合理；`/root` 通常在根挂载上，实际 no-op；若 `/root` 独立挂载则会等待它 | 合理 |
| `a0-desktop-start` 的 `$HOME` | root 服务下展开为 `/root/.var/app/...` | 若目标机 root 安装应用则正确；本机不适用 |

**模拟 root unit 的 `systemd-analyze verify`**：

```text
agent-zero-desktop.service: Command /usr/local/bin/a0-desktop-start is not executable: No such file or directory
RC=1
```

除“未安装的可执行文件”外无语法错误。

**结论**：**root 替换正确**。`install-services.sh` 的 sed 逐行验证通过。真正的前置不是 sed，而是：目标机必须以 root 完成 Flatpak **user** 安装（或改 unit 用 `--system`/指定 installation），并存在 root 的图形会话（`/run/user/0`、`/root/.Xauthority`、可用的 `:0`）。

---

### J.3 重启自恢复的可执行部分

**目的**：验证“应用可被 kill 并手动重启回 health 200”。这是应用层可重启性，不是 systemd 的 `Restart=always`。

**命令**（只做一次；脚本 `~/a0-local-backup/probe-ijk/restart.sh`）：

```sh
flatpak kill org.agentzero.AgentZero
setsid flatpak run --user \
  --env=OLLAMA_MAX_LOADED_MODELS=1 --env=OLLAMA_KEEP_ALIVE=10m \
  org.agentzero.AgentZero < /dev/null &
# 每 2 s 轮询 http://127.0.0.1:5080/api/health，最多 240 s
```

**原始输出**：

```text
=== before 2026-11-18 01:34:39 ===
old_pid=1716379
1716379 ... run_ui.py --port=5080 --host=127.0.0.1
before_http=200
=== flatpak kill ===
after_kill_pid=
=== start ===
Initializing Python framework...
Starting UI/API server...
INFO:     Application startup complete.
INFO:     Uvicorn running on http://127.0.0.1:5080
Agent Zero is running.
http=200 elapsed=10s
new_pid=1838580
=== flatpak ps ===
3802918545	1838712	org.agentzero.AgentZero	org.freedesktop.Platform
573917191	1838567	org.agentzero.AgentZero	org.freedesktop.Platform
=== ports ===
127.0.0.1:11434  ollama pid=1838605
127.0.0.1:5080   python pid=1838580
=== after 2026-11-18 01:34:50 ===
```

**期望**：kill 后能重启；health 200；耗时 < 120 s。

**实际**：旧 PID 1716379 被 kill；新 PID 1838580；**10 s** 内 health 200；ollama（1838605）随应用重启并在 11434 监听；**14500 没有监听，xpra 未启动**。`flatpak ps` 显示 2 条：一条是本次 launcher（1838567），另一条（1838712）是另一个 agent 的 `e_tts.py` 探针会话，不是本应用的第二实例。

启动参数已从新 ollama 进程的环境核实：

```text
OLLAMA_HOST=127.0.0.1:11434
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_KEEP_ALIVE=10m
```

重启后 `usr/settings.json` 仍不存在；`conf`/`prompts`/`usr` 保留；`kw92` 计数 1；`sessions/agent-zero-desktop.json` 仍是旧文件（`started_at` 未更新），说明桌面会话没有被重新创建。

**结论**：**应用重启通过（10 s，health 200）**；**桌面会话自恢复未通过/未执行**：`agent-zero-desktop.service` 与 `/usr/local/bin/a0-desktop-start` 未安装，xpra 不会自动起，14500 不监听。此项要由目标机的 systemd unit 负责，本轮不能用 systemd 验证。

---

### J.4 必须在具备 sudo 的目标机上做的用例

**目的**：明确哪些 J 类用例在本机只能判“环境不具备”，必须在目标机补做。

| 用例 | 需要 | 本机为何不能做 |
|---|---|---|
| C53 两个 unit enabled / verify | sudo 写 `/etc/systemd/system`、`systemctl daemon-reload` | 无 `/etc/systemd/system/agent-zero*.service`；`sudo` 需密码，不可用 |
| C54 `systemctl restart agent-zero` 后 health 200 | 已安装的 unit + sudo | 同上；本轮只做了手工 `flatpak kill` + 启动 |
| C55 `kill -9` MainPID 后 `Restart=always` | systemd unit 真在跑 | 无 unit；手工杀进程不等于 systemd 重启 |
| C56 开机自启 | 能 `sudo reboot`，且有 root 图形会话 | 需要重启机器；本机无 root 登录会话、无 `/run/user/0` |
| C57 journal 重启记录 | `journalctl -u agent-zero` 有 unit | `journalctl -u agent-zero` 输出 `-- No entries --` |
| C60 journalctl 日志可读 | 同上 | 同上；只有 `ollama.log`/`xpra-stderr.log` 可读 |
| root 形态的 `a0-desktop-start` | root 的 flatpak user 安装 + `/root/.Xauthority` + `/run/user/0` | `/root/.local/share/flatpak` 不可读（Permission denied）；`/var/lib/flatpak/app` 不存在；`/run/user/0` 不存在；`/root/.Xauthority` 不可读 |

---

## 3. K 类：资源与清理

### K.1 进程与孤儿

**目的**：确认应用进程无孤儿、无重复实例。

**命令**：

```sh
flatpak ps
pgrep -af 'run_ui.py|models/bin/ollama|xpra|chrome'
ps --ppid <每个 flatpak ps 的 PID> -o pid,ppid,stat,etime,cmd
```

**原始输出（重启前，01:34）**：

```text
flatpak ps
827449358	1794722	org.agentzero.AgentZero	org.freedesktop.Platform
4020385321	1717344	org.agentzero.AgentZero	org.freedesktop.Platform
2306042379	1716365	org.agentzero.AgentZero	org.freedesktop.Platform

application procs:
1716379 ... run_ui.py --port=5080 --host=127.0.0.1
1716406 /app/share/agent-zero/models/bin/ollama serve
1717422 ... xpra shadow :0 ... --bind-tcp=127.0.0.1:14500
```

**原始输出（重启后，01:35）**：

```text
flatpak ps
3802918545	1838712	org.agentzero.AgentZero	org.freedesktop.Platform
573917191	1838567	org.agentzero.AgentZero	org.freedesktop.Platform

1838580 ... run_ui.py --port=5080
1838605 ... ollama serve
（无 xpra）
```

**期望**：只有一个 `run_ui.py` 与一个 `ollama serve`；没有重复的 `bwrap … agent-zero`；xpra 数量不超过会话数 + 1；没有 `flatpak-spawn`/MCP server 的宿主残留。

**实际**：
- 应用核心进程只有 1 个 `run_ui.py`、1 个 `ollama serve`；重启前有 1 个 `xpra`，重启后 0 个。
- `flatpak ps` 的条目数 **不等于** 应用实例数：每个 `flatpak run --command=sh` 会话都会产生一条。验证期间（01:33）曾出现 1789914（**Z 僵尸**）与 1717344（无子进程的空壳）；重启前最后一次 `flatpak ps` 为 3 条（1716365、1717344、1794722），其中 1794722 是另一个 agent 的探针（`e_long.py`/`e_tts.py`），其 `bwrap sh -c` 在工作，不是孤儿。
- 我的 MCP 探针曾遗留宿主 `bun`（PID 1789944）监听 58891；父 `flatpak-spawn` 结束后它仍存活。已 `kill 1789944`，58891 释放。第二个探针（1805629/1805674）也已清理。
- 宿主 Chrome 进程（`~/.cache/a0-shots-chrome*`）是 probe-browser 的测试浏览器，不是 A0 的子进程；不属本应用孤儿。
- 重启时 `flatpak kill` 清掉了所有旧入口；新入口 1838712 是另一 agent 的探针，不是本应用第二实例。

**结论**：**通过（应用核心无孤儿）**；但 `flatpak ps` 判据需要改写（见 P10）。验证活动本身会留下 `flatpak run` 入口与 MCP server 的宿主进程，收尾时应按 PID/命令行清理。

---

### K.2 端口

**命令**：

```sh
ss -tlnp | grep -E ':(5080|11434|14500|58891)\b'
```

**原始输出（重启前）**：

```text
127.0.0.1:11434  0.0.0.0:*  users:(("ollama",pid=1716406,fd=3))
127.0.0.1:14500  0.0.0.0:*  users:(("python",pid=1717422,fd=7))
127.0.0.1:5080   0.0.0.0:*  users:(("python",pid=1716379,fd=29))
58891: 由 probe bun pid=1789944 监听
```

**原始输出（重启后）**：

```text
127.0.0.1:11434  ollama pid=1838605
127.0.0.1:5080   python pid=1838580
14500: 无监听
58891: 无监听
```

**期望**：5080 属于 `run_ui.py`；11434 属于 `ollama serve`；14500 属于 xpra；58891 属于 WPS MCP server（等待 WPS 加载项）；四个端口都只绑定 `127.0.0.1`。

**实际**：重启前四个端口均有归属（其中 58891 是本轮 MCP 探针启动的 `bun`，不是常驻服务）；重启后 5080/11434 恢复，14500 缺失（xpra 未启动），58891 无监听（MCP server 未运行）。

**结论**：**通过（能解释每个端口）**；14500 的缺失是 J.3 的桌面会话问题，不是端口冲突。

---

### K.3 数据目录

**命令**：

```sh
A=~/.var/app/org.agentzero.AgentZero
du -sh $A/data $A/cache $A/config
du -sh $A/data/agent-zero/{venv,tmp,webui,plugins}
du -sh $A/data/agent-zero/tmp/playwright/*
du -ah $A/data/agent-zero --exclude=venv --exclude=playwright | sort -h | tail
du -sm $A/data/agent-zero/usr/memory
```

**原始输出**：

```text
1.4G  .../data
4.8M  .../cache
12K   .../config
847M  .../data/agent-zero/venv
387M  .../data/agent-zero/tmp
19M   .../data/agent-zero/webui
11M   .../data/agent-zero/plugins
379M  .../tmp/playwright/chromium-1228
4.9M  .../tmp/playwright/ffmpeg-1011
2.9M  .../tmp/browser
1M    .../usr/memory   (12 files)
```

**期望**：`data` 以 `venv` 与模型为主，没有无法解释的大文件；`tmp/playwright/chromium-1228` 若存在应有明确用途；`usr/uploads` 不应无上限增长。

**实际**：
- `venv` 847 MB 是最大项，正常（Python 3.14 + 依赖）。
- `tmp/playwright/chromium-1228` **379 MB**（任务书写“约 177 MB”，实际已增长）。它只在“没有宿主 Chrome”时才被 Playwright 使用；本机有宿主 Chrome，probe-browser 已证实优先用宿主 Chrome。**可删**，但按约束只报告、不删。
- `tmp/playwright/ffmpeg-1011` 4.9 MB，Playwright 录制用，可保留。
- `tmp/browser` 2.9 MB，是浏览器 profile 残留；可清，但会丢测试会话。
- `usr/uploads` 不存在，无增长项。

**结论**：**通过（无异常增长，除可解释的 Playwright 379 MB）**。

---

### K.4 日志与 OOM

**命令**：

```sh
ls -l $A/data/agent-zero/ollama.log
ls -l $A/data/agent-zero/usr/plugins/_desktop/profiles/agent-zero-desktop/xpra.log
ls -l $A/data/agent-zero/usr/plugins/_desktop/profiles/agent-zero-desktop/xpra-stderr.log
journalctl -k | grep -i 'killed process' | tail
```

**原始输出**：

```text
-rw-r--r-- 1 kunweiz kunweiz 473818 Nov 18 01:34 .../ollama.log
ls: cannot access '.../profiles/agent-zero-desktop/xpra.log': No such file or directory
-rw-r--r-- 1 kunweiz kunweiz 3466 Nov 18 01:22 .../xpra-stderr.log
```

`xpra-stderr.log` 尾部：

```text
2026-11-18 01:16:02,350 Warning: gnome input sources requires the python dbus bindings
2026-11-18 01:16:02,351 the keymap has been changed: pc105
2026-11-18 01:22:14,163 8K packets received (0.4M bytes)
2026-11-18 01:22:14,163 8K packets sent (1.4G bytes)
2026-11-18 01:22:14,169 HTML5 client 1 disconnected.
```

OOM：

```text
Nov 16 19:23:52 7940HS kernel: Out of memory: Killed process 679710 (omp) ...
Nov 17 23:51:47 7940HS kernel: Out of memory: Killed process 886851 (omp) ...
```

**期望**：`ollama.log` 与 xpra 日志可读且非空；内核日志没有 `agent-zero`/`ollama`/`xpra` 的 OOM 记录。

**实际**：
- `ollama.log` 473818 B，可读；重启后文件仍在并增长（重启前 420381 B），没有清空，也不是持续无限增长。
- 任务给的 `xpra.log` 路径不存在；实际文件名是 `xpra-stderr.log`（3.4 KB，最后写入 01:22）。这是路径文档问题，不是缺失证据。
- `journalctl -k` 只有 2 条 OOM，进程名都是 **`omp`**（当前 harness，UID 1000），时间 11-16 与 11-17；**没有** `agent-zero`、`ollama`、`xpra`、`python` 的 OOM 记录。
- `journalctl -u agent-zero` 无条目（unit 未安装）。

**结论**：**通过（无应用 OOM）**；日志路径需按实际 `xpra-stderr.log` 修正。

---

### K.5 重装后数据未丢（只验证“数据仍在”，未执行重装）

**命令**：

```sh
A=~/.var/app/org.agentzero.AgentZero
ls -l $A/data/agent-zero/conf $A/data/agent-zero/usr
grep -c kw92 $A/data/agent-zero/conf/model_providers.yaml
find $A/data/agent-zero/usr/memory -type f | wc -l
```

**原始输出**：

```text
conf: AGENTS.md, model_providers.yaml, projects.default.gitignore, skill.default.gitignore, workdir.gitignore
usr:  agents, api, chats, downloads, knowledge, kvp, memory, plugins, projects, scheduler, ...
kw92 count = 1
usr/memory files = 12
```

**期望**：重装前后 `usr/memory` 文件数、`model_providers.yaml` 哈希不变。

**实际**：`conf`、`prompts`、`usr` 均存在；`kw92` 计数 1；`usr/memory` 12 个文件；`chats` 744 KB。**没有执行真正的重装**：本机 `~/a0-bundles/` 不存在，且重装会替换应用、超出本轮“不改运行实例”的边界。

**结论**：**部分通过**。数据未丢的“现状”成立；完整 C59 需要 bundle 与一次 `flatpak install --reinstall`，本机环境不具备。

---

### K.6 磁盘

**目的**：确认 `/home` 有可用空间、inode 未耗尽。

**命令**：

```sh
df -h /home
df -i /home
```

**原始输出**：

```text
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p2  111G   81G   30G  74% /home
Filesystem      Inodes IUsed IFree IUse% Mounted on
/dev/nvme0n1p2      0     0     0     - /home
```

**期望**：`/home` 有可用空间，inode 不耗尽。

**实际**：`/home` 74% 使用，剩 30 G；inode 显示 0/0 是 btrfs 的正常表现。当前无磁盘压力。

**结论**：**通过**。

---

## 4. “环境不具备”清单（每条给依据）

| # | 项目 | 依据 |
|---|---|---|
| E1 | systemd unit 安装/启用/verify（C53） | `/etc/systemd/system/agent-zero*` 不存在；`systemctl --user list-unit-files 'agent-zero*'` 返回 0；`sudo` 需要密码，本会话不可用 |
| E2 | `systemctl restart` 后 health（C54） | 同上；本轮只能用 `flatpak kill` + 手动 `flatpak run` 替代，已验证 10 s 回到 200，但这不是 systemd 的 `Restart=` |
| E3 | 崩溃后 `Restart=always`（C55） | 无 unit；手工 `kill -9` 无法触发 systemd 重启 |
| E4 | 开机自启（C56） | 需要 `sudo reboot` 与 root 图形会话；本机没有 root 登录会话，`/run/user/0` 不存在 |
| E5 | journal 重启记录（C57） | `journalctl -u agent-zero` 输出 `-- No entries --` |
| E6 | root 形态的 `a0-desktop-start` | `/root/.local/share/flatpak` 不可读（Permission denied）；`/var/lib/flatpak/app` 不存在；`/run/user/0` 不存在；`/root/.Xauthority` 不可读 |
| E7 | C59 的完整重装对比 | `~/a0-bundles/` 不存在；未执行 `flatpak install --reinstall` |
| E8 | C48 强制 headless | 属 H 类、破坏性（清 `sessions`、重启 xpra），不在本轮 I/J/K 范围；本机需在具备可重建会话的环境执行 |
| E9 | C60 的 `journalctl -u` 部分 | 同 E5；只有应用文件日志可读 |
| E10 | 运行中 A0 真实加载 WPS MCP | `$DATA/usr/settings.json` 不存在；未改运行中的 settings，无法验证“写入后自动加载”的端到端路径 |

---

## 5. 发现的问题（按严重度）

| # | 严重度 | 问题 | 证据 | 建议 |
|---|---|---|---|---|
| P1 | **高** | 运行实例没有 `usr/settings.json`，WPS MCP 配置未进入运行时；I.2/I.3 只是手工按配置形态启动的验证 | `ls .../usr/settings.json` → No such file；`jq` RC=2；`settings.py:183` 的 `SETTINGS_FILE` 指向该路径 | 目标机写入 `mcp_servers`（字符串，非对象），重启后确认工具出现在 UI；或把该 JSON 纳入部署脚本 |
| P2 | **高** | root 形态的 systemd 前提未满足：`flatpak run --user` 在 root 下找 `/root/.local/share/flatpak`，本机应用是 `kunweiz` 的 user 安装 | `/root/.local/share/flatpak` Permission denied；`/var/lib/flatpak/app` 不存在；unit `ExecStart=flatpak run --user` | 目标机必须以 root 完成 user 安装，或把 unit 改成 `--system`/`--installation=`；安装脚本应显式检查/选择 installation |
| P3 | **中** | 重启后桌面会话不恢复：14500 无监听，`sessions` 仍是旧文件 | 重启后 `ss` 无 14500；`xpra-stderr.log` 最后写入 01:22；`agent-zero-desktop.service` 未安装 | 在目标机安装并启用 `agent-zero-desktop.service`；`a0-desktop-start` 安装到 `/usr/local/bin` |
| P4 | **中** | C49 的 `test -x` 判据对 `dist/index.js` 不成立（644） | `test -x` FAIL；`test -r`/`-f` OK；`bun` 只需读取它 | 把 C49 的第二个路径判据改为 `test -r`，或只对 `command` 做 `-x` |
| P5 | **中** | `isError` 语义不一致：`wps_check_connection` 业务失败但 `isError:false`；文档工具超时 `isError:true` | I.3/I.5 的原始 JSON | Agent Zero 侧不能只靠 `isError` 判断；在提示词/工具描述中说明 `connected:false`，或让上游统一置错 |
| P6 | 低 | `tools/list` 不含 `serverInfo`/`protocolVersion`，从该响应取会得到 `null` | I.2 的 `tools/list` 结果只有 `tools` | 报告/脚本从 `initialize` 取元数据，或修正验收脚本 |
| P7 | 低 | 任务给的 `xpra.log` 路径不存在，实际是 `xpra-stderr.log` | `ls` 报 No such file；实际文件 3466 B | 修正矩阵/文档中的日志路径 |
| P8 | 低 | `chromium-1228` 实际 379 MB，不是约 177 MB | `du -sh` → 379M | 如不需要 Playwright 自带 Chromium，可删除释放 379 MB；本轮未删 |
| P9 | 观察 | health 200 但 body 含 `error: /home/.../data/agent-zero`（`gitinfo: null`） | `curl /api/health` 的 JSON | 判据只看 HTTP 200 时可接受；若要“语义健康”，应把 `error` 为空的附加条件写清 |
| P10 | 观察 | `flatpak ps` 条目数 ≠ 应用实例数；每个 `flatpak run --command=sh` 都会多一条，且可出现僵尸/空壳条目 | 验证期间最多 4 条（含 1789914 Z、1717344 空壳）；重启前 3 条；重启后 2 条（含另一 agent 的 1838712） | C58 改为按 `run_ui.py` / `bwrap … agent-zero` 判定，并在验收前清理探针入口 |

---

## 6. 对照 `test-matrix.md` 的 C48–C61

| CASE | 本轮状态 | 说明 / 证据 |
|---|---|---|
| **C48** 强制 headless | **未执行（环境不具备/范围外）** | H 类、破坏性；需清 `sessions` 并重启 xpra；本轮只做 I/J/K |
| **C49** 配置语法与可执行 | **不通过（运行时注册缺失）** | `usr/settings.json` 不存在，`jq` RC=2；配置 JSON 本身 `jq -e .` 通过；`bun` 可执行；`dist` 644，`test -x` 失败（应 `-r`） |
| **C50** `initialize` 握手 | **通过** | 沙盒内 0.48 s；`serverInfo.name=wps-office-mcp`；`protocolVersion=2024-11-05` |
| **C51** `tools/list` 非空 | **通过** | 250 个工具，含 `wps_check_connection` |
| **C52** 无宿主 WPS 时调用 | **通过** | `list_cache` 0.003 s 成功；`check_connection` 30.01 s `connected:false`；`getActiveDocument` 69.78 s、`insertText` 30.02 s、`getAppInfo` 30.02 s，均 `isError:true`，无崩溃、无 >90 s 挂起 |
| **C53** 两个 unit enabled | **环境不具备** | 无 `/etc/systemd/system/agent-zero*.service`；无 sudo；`systemctl --user` 0 个；`verify` 只报 `a0-desktop-start` 未安装 |
| **C54** restart 后 health 200 | **部分通过** | 手工 `flatpak kill` + `flatpak run`，10 s 后 200；非 `systemctl restart` |
| **C55** 崩溃后 `Restart=always` | **环境不具备** | 无 unit；无法用 `kill -9` 触发 systemd 重启 |
| **C56** 开机自启 | **环境不具备** | 需 `sudo reboot` 与 root 图形会话；本机无 `/run/user/0` |
| **C57** 重启记录可读 | **环境不具备** | `journalctl -u agent-zero` → `-- No entries --` |
| **C58** 无孤儿进程 | **部分通过** | 应用核心 1×`run_ui.py` + 1×`ollama`；重启前 1×xpra；`flatpak ps` 有探针入口/僵尸，不能按条目数判；MCP 探针的宿主 `bun` 已清理，58891 已释放 |
| **C59** 重装不清数据 | **部分通过** | 数据仍在：`conf`/`prompts`/`usr`、`kw92=1`、`memory` 12 文件、`chats` 744 KB；未执行重装（无 bundle） |
| **C60** 日志可读 | **部分通过** | `ollama.log` 473818 B 可读；`xpra-stderr.log` 3466 B 可读；`journalctl -u` 无条目；未统计 `Permission denied` |
| **C61** 磁盘未异常增长 | **部分通过** | `/home` 74%，30 G 可用；`data` 1.3 G；无基线对比；最大非模型项 `chromium-1228` 379 MB |

---

## 7. 证据文件

| 文件 | 内容 |
|---|---|
| `~/a0-local-backup/probe-ijk/mcp_probe.py` | 沙盒内 MCP 握手 + `list_cache` + `check_connection` 探针 |
| `~/a0-local-backup/probe-ijk/mcp_probe.log` | 上述探针的完整 JSON-RPC 输出（250 工具、0.48 s、30.01 s） |
| `~/a0-local-backup/probe-ijk/mcp_doc_probe.py` | 文档工具失败探针（`getActiveDocument`/`insertText`/`getAppInfo`） |
| `~/a0-local-backup/probe-ijk/mcp_doc_probe.log` | 三个工具的超时原文（69.78 s / 30.02 s / 30.02 s） |
| `~/a0-local-backup/probe-ijk/restart.sh` | 一次 `flatpak kill` + 重启 + health 轮询 |
| `~/a0-local-backup/probe-ijk/restart.log` | 重启前后 PID、10 s、端口、flatpak ps |

复现注意：
- MCP 探针必须经 `flatpak run --command=sh` 在沙盒内启动；宿主直接跑会因宿主没有 `/usr/bin/flatpak-spawn` 失败。
- 读取 `tools/list` 时不要取 `serverInfo`；从 `initialize` 取。
- 清理探针时按 `wps-office-mcp/dist/index.js` 的宿主 `bun` PID 杀，否则 58891 会残留。
- 重启只做了一次；之后未再触碰 5080 实例。
