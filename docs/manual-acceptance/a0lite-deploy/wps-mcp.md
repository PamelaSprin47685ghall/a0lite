# WPS MCP 扩展验收

验收对象：`org.agentzero.AgentZero.Wps` 1.0（user 安装）与 `flatpak/wps-mcp-config.json`。
验收方式：在宿主用 stdio 直接启动 MCP server，不连接、不重启正在运行的 Agent Zero 实例。

## 1. 结论摘要

- MCP server 能启动并完成握手。`initialize` 返回 `serverInfo.name = wps-office-mcp`、`version = 1.0.0`、`protocolVersion = 2024-11-05`；`tools/list` 返回 **250** 个工具，全部带 `name` 与 `inputSchema`。
- 250 个工具里，无 WPS 宿主下只有 4 个跨应用缓存工具能立即成功。其余工具走 `127.0.0.1:58891` 等待加载项，30 秒后返回可读错误。进程不崩溃、不无限挂起。
- `flatpak/wps-mcp-config.json` 的旧内容有两处错误：`bin/node`（扩展不带 node）与 `/var/lib/flatpak`（本机是 user 安装）。最终配置改为 `flatpak-spawn --host` 形态，原因与验证见 §12；README 补了 system 变体。
- 主包沙箱内 `~/.local/share/flatpak` 是一个空目录，直接 exec 宿主 `bun` 的配置在 A0 里起不来。本轮验证了 `flatpak-spawn --host` 方案：只加 `--talk-name=org.freedesktop.Flatpak`，沙盒内即可启动 server、完成 `initialize`、列出 250 个工具并调用 `wps_list_cache`。配置已改为该形态，详见 §12。

## 2. 环境与前置

| 项目 | 值 |
| --- | --- |
| 主机 | `kunweiz`，Manjaro，x86_64 |
| 仓库 | `/home/kunweiz/Desktop/a0lite`，HEAD `058582f`（2026-11-03） |
| 扩展 ID | `org.agentzero.AgentZero.Wps`，branch `1.0`，Installation `user` |
| 扩展 commit | `184cc3776f17b1fd5883cdbf0a3316c04f7e9535004b1c2067785fac37a23380` |
| 扩展大小 | `flatpak info` 报 190.1 MB；`du -sh files` 报 200M（块大小差异） |
| 扩展载荷 | `/home/kunweiz/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files` |
| bun | 扩展自带 `bin/bun`，`--version` 输出 `1.4.4` |
| 宿主 WPS | 未安装：`wps`/`et`/`wpp` 全缺，`/opt/kingsoft/wps-office` 与 `~/.local/share/Kingsoft` 不存在 |
| 宿主 `flatpak-spawn` | 不存在（`flatpak` 包只提供 `/usr/bin/flatpak`） |
| 沙盒 `flatpak-spawn` | `/usr/bin/flatpak-spawn` 存在，由 `org.freedesktop.Platform` 提供 |
| 运行中的 A0 | 主包 `org.agentzero.AgentZero` master，PID 1675732，`A0_BASE_DIR=/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero`；本轮未触碰 |

### 2.1 扩展树实际布局

```text
files/
├── bin/
│   ├── bun          # 107 MB，bun 1.4.4
│   └── wps-mcp      # bash，EXT_ROOT=/app
├── lib/debug/       # 空
├── manifest.json
├── share/licenses/
└── wps-skills/
    ├── skills/
    ├── wps-claude-assistant/
    └── wps-office-mcp/
        ├── dist/    # 入口 dist/index.js
        ├── node_modules/
        └── package.json   # name wps-office-mcp, version 1.0.0
```

任务书写的 `share/wps-office-mcp` **不存在**。`share/` 下只有 `licenses`，MCP server 实际在 `wps-skills/wps-office-mcp`。`bin/wps-mcp` 与 `flatpak/wps-mcp.sh` 也指向这里：

```bash
EXT_ROOT="/app"
BUN="$EXT_ROOT/bin/bun"
SERVER="$EXT_ROOT/wps-skills/wps-office-mcp/dist/index.js"
exec "$BUN" "$SERVER" "$@"
```

因为 `EXT_ROOT=/app`，宿主直接执行 `files/bin/wps-mcp` 会报 `wps-mcp: bun is missing from the extension`。下文所有握手都走 `files/bin/bun` + `wps-skills/wps-office-mcp/dist/index.js`。

## 3. 握手：命令与原始往返

### 3.1 可直接复制的命令

完整探针脚本：`~/a0-local-backup/wps-mcp/wps_mcp_probe.py`（本轮新建，不在仓库）。它依次发送 `initialize`、`notifications/initialized`、`tools/list`，再调用指定工具，并把原始 JSON-RPC 写入 `rpc.jsonl`。

```bash
EXT=$HOME/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files
python3 "$HOME/a0-local-backup/wps-mcp/wps_mcp_probe.py"
# 只做握手与工具列表：
python3 "$HOME/a0-local-backup/wps-mcp/wps_mcp_probe.py" --no-calls
# 只调用一个工具：
python3 "$HOME/a0-local-backup/wps-mcp/wps_mcp_probe.py" --call wps_common_get_app_info
```

等价的精简版本已经写进 `flatpak/README.md` 的 WPS 一节，可以直接复制运行：

```bash
EXT=$HOME/.local/share/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files
python3 - "$EXT" <<'PY'
import json, subprocess, sys

ext = sys.argv[1]
proc = subprocess.Popen(
    [ext + "/bin/bun", ext + "/wps-skills/wps-office-mcp/dist/index.js"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
)

def send(message):
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()

def receive():
    return json.loads(proc.stdout.readline())

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2024-11-05", "capabilities": {},
    "clientInfo": {"name": "probe", "version": "1"}}})
print(receive()["result"]["serverInfo"])
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
tools = receive()["result"]["tools"]
print(len(tools), [tool["name"] for tool in tools[:5]])
proc.stdin.close()
proc.wait()
PY
```

该段从 README 原文抽出后实跑，输出：

```text
{'name': 'wps-office-mcp', 'version': '1.0.0'}
250 ['wps_check_connection', 'wps_get_active_document', 'wps_insert_text', 'wps_get_active_workbook', 'wps_get_cell_value']
real    0m0.195s
```

不需要 `WPS_MCP_PORT`、`DEBUG`、`LOG_LEVEL` 等环境变量。server 只在 `MCP_CONSOLE_LOG` 显式为真时写 stdout，默认写文件 `~/.wps-office-mcp/logs/{combined,error}.log`，所以 stdio 通道干净。

### 3.2 原始 JSON-RPC 往返

请求（探针原文）：

```json
{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "a0lite-acceptance", "version": "1.0"}}}
{"jsonrpc": "2.0", "method": "notifications/initialized"}
{"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
```

`initialize` 响应（原文）：

```json
{"result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "wps-office-mcp", "version": "1.0.0"}}, "jsonrpc": "2.0", "id": 1}
```

`tools/list` 响应（摘要；完整响应 108,791 字节，存于 `run1/rpc.jsonl`）：

```json
{"result": {"tools": [{"name": "wps_check_connection", "description": "检查WPS Office连接状态", "inputSchema": {"type": "object", "properties": {}}}, ... 共 250 条 ...]}, "jsonrpc": "2.0", "id": 2}
```

### 3.3 断言与耗时

| 断言 | 结果 |
| --- | --- |
| `result.serverInfo.name == "wps-office-mcp"` | 通过（`wps-office-mcp`） |
| `result.protocolVersion == "2024-11-05"` | 通过 |
| `len(result.tools) > 0` | 通过（250） |
| 每个 tool 有 `name` 与 `inputSchema` | 通过（缺项 0） |
| 首 5 个工具名 | `wps_check_connection`、`wps_get_active_document`、`wps_insert_text`、`wps_get_active_workbook`、`wps_get_cell_value` |
| 启动到 `initialize` 响应 | 223 ms（run1 冷启动）、158 ms（run2） |
| 退码 | 0；关闭 stdin 后进程自行退出 |

## 4. `tools/list` 统计与分类

### 4.1 总数

`tools/list` 返回 **250** 个工具，名字全部以 `wps_` 开头。按源码模块（`dist/tools/index.js` 的 `excelTools`/`wordTools`/`pptTools`/`commonTools`）精确归属，剩余 12 个是 `mcp-server.js` 里注册的内置工具：

| 类别 | 数量 | 命名样例 |
| --- | ---: | --- |
| 内置（`mcp-server.js`） | 12 | `wps_check_connection`、`wps_list_cache`、`wps_execute_method` |
| Excel | 82 | `wps_excel_read_range`、`wps_excel_set_formula` |
| Word | 32 | `wps_word_insert_text`、`wps_word_get_document_text` |
| PPT | 115 | `wps_ppt_add_slide`、`wps_ppt_set_slide_layout` |
| Common | 9 | `wps_common_ping`、`wps_convert_to_pdf` |
| **合计** | **250** | |

12 个内置工具再分两组：

- 缓存 4 个：`wps_cache_data`、`wps_get_cached_data`、`wps_list_cache`、`wps_clear_cache`。
- 其它 8 个：`wps_check_connection`、`wps_get_active_document`、`wps_insert_text`、`wps_get_active_workbook`、`wps_get_cell_value`、`wps_set_cell_value`、`wps_get_active_presentation`、`wps_execute_method`。

### 4.2 无 WPS 宿主下的可用性

判断依据：handler 是否调用 `wpsClient`（最终 `invokeAction` → `execMacPoll` → 58891）。缓存 4 个读写进程内 `Map`，源码在 `dist/server/mcp-server.js:400/439/484/540`；其余 handler 全部经过 `invokeAction`。抽样读了 `tools/excel/formula.js`、`tools/ppt/presentation.js`、`tools/common/general.js`、`tools/common/convert.js`，并实测了 3 个工具。

| 类别 | 数量 | 能成功？ | 理由 |
| --- | ---: | --- | --- |
| 内置·缓存 | 4 | **能** | 纯内存 `Map`；`wps_list_cache` 实测 3 ms 返回 `{"success":true,"count":0,"caches":[]}` |
| 内置·连接与文档 | 8 | **不能** | 全部走 58891；`wps_check_connection` 实测 30.0 s 后返回 `connected:false` |
| Excel | 82 | **不能** | 每个 handler 都 `executeMethod`/`invokeAction`；`wps_excel_generate_formula` 也先取 `getContext` |
| Word | 32 | **不能** | 同上 |
| PPT | 115 | **不能**（1 个例外分支） | 同上；`wps_ppt_set_active_target` 在 `clear=true` 或缺 `name` 时只改进程内变量，可立即成功 |
| Common | 9 | **不能** | 全部 `executeMethod`；`wps_common_get_app_info` 实测 30.0 s 后返回可读错误 |

[INFERENCE] Excel/Word/PPT/Common 的"全部不能"来自模块级统一模式加抽样，不是 250 个工具逐一调用。唯一确认的非 WPS 分支是缓存 4 个与 `wps_ppt_set_active_target` 的 clear 分支。

### 4.3 命名与源码注释不一致

`dist/tools/index.js` 头注释写"共 235 个，另有 12 个内置，全局共 247 个"，并写 PPT 112 个。实测 250 个，其中 PPT 115 个。差 3 个来自 PPT 模块新增的工具，注释未同步。

## 5. 实际工具调用与错误可读性

三轮独立 stdio 会话，均 rc=0、进程自行退出。原始响应如下。

### 5.1 `wps_list_cache`（非 WPS 工具）

```json
{"result": {"content": [{"type": "text", "text": "{\"success\":true,\"count\":0,\"caches\":[]}"}], "isError": false}, "jsonrpc": "2.0", "id": 3}
```

耗时 3 ms。内容可读，结构稳定。

### 5.2 `wps_check_connection`（连接探测）

```json
{"result": {"content": [{"type": "text", "text": "{\"connected\":false,\"status\":{\"connected\":false,\"error\":\"Connection check failed\"}}"}], "isError": false}, "jsonrpc": "2.0", "id": 4}
```

耗时 **30,012 ms**。返回的是结构化 JSON，不是崩溃或空响应。缺点见 §8 P2-1：连接失败却 `isError=false`。

### 5.3 `wps_common_get_app_info`（文档类）

```json
{"result": {"content": [{"type": "text", "text": "获取应用信息出错: Command timeout after 30000ms: getAppInfo"}], "isError": true}, "jsonrpc": "2.0", "id": 3}
```

耗时 **30,010 ms**。错误文本含动作名与超时值，中文可读，无堆栈、无裸异常。

### 5.4 可读性评估

| 工具 | 返回形态 | 可读 | 问题 |
| --- | --- | --- | --- |
| `wps_list_cache` | 成功 JSON | 是 | 无 |
| `wps_check_connection` | 失败语义的 JSON，但 `isError=false` | 是 | MCP 层未标错，模型可能当成成功 |
| `wps_common_get_app_info` | 单行中文错误，`isError=true` | 是 | 需要等 30 s 才拿到 |

三个调用都没有出现"崩溃""空 content 且无 error""挂起超过 90 s"。

## 6. `flatpak/wps-mcp-config.json` 修正

### 6.1 before

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

两处错误：

1. `files/bin/node` 不存在。扩展 `bin/` 只有 `bun` 与 `wps-mcp`；宿主的 `/usr/bin/node` 与此无关。
2. `/var/lib/flatpak` 是 system 安装路径。`flatpak list` 显示本机 WPS 扩展的 Installation 是 `user`，`/var/lib/flatpak` 整个目录都不存在。

### 6.2 after（user 安装 + 沙盒形态，本机实际）

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

验证：

```text
$ jq -r '.mcpServers["wps-office"].command' flatpak/wps-mcp-config.json
/usr/bin/flatpak-spawn
$ test -x "$(jq -r '.mcpServers["wps-office"].args[2]')" && \
  test -f "$(jq -r '.mcpServers["wps-office"].args[3]')" && echo HOST_PATHS_OK
HOST_PATHS_OK
$ flatpak run --command=sh org.agentzero.AgentZero -c 'test -x /usr/bin/flatpak-spawn && echo SANDBOX_SPAWN_OK'
SANDBOX_SPAWN_OK
```

`/usr/bin/flatpak-spawn` 只在沙盒内存在（宿主的 `flatpak` 包不提供它），所以 `command` 不能在宿主用 `test -x` 检查。宿主的两个路径由 `args[2]`、`args[3]` 检查；`command` 由沙盒内的检查覆盖。

### 6.3 system 安装变体

`command` 不变，两个宿主路径换成 `/var/lib/flatpak`：

```json
{
  "mcpServers": {
    "wps-office": {
      "command": "/usr/bin/flatpak-spawn",
      "args": [
        "--watch-bus",
        "--host",
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/bin/bun",
        "/var/lib/flatpak/app/org.agentzero.AgentZero.Wps/current/active/files/wps-skills/wps-office-mcp/dist/index.js"
      ]
    }
  }
}
```

用哪个：仓库的构建命令全部是 `flatpak-builder --user --install`，所以片段默认 user。只有 `flatpak install --system` 的机器才用 system 变体。两种变体都写进了 `flatpak/README.md` 的 WPS 一节。

### 6.4 为什么必须是绝对路径

Agent Zero 的 stdio 客户端不会展开 `~` 或 `$HOME`：

- `helpers/mcp_handler.py:118` 用 `shlex.split(command)` 切分命令。
- `helpers/mcp_handler.py:1566` 用 `shutil.which(server.command)` 检查可执行性。
- `helpers/mcp_handler.py:1569-1575` 把 `command` 原样交给 `StdioServerParameters`，随后由 `stdio_client` 直接 `exec`，不经过 shell。

因此 `~/.local/...` 会得到 `Command '~/...' not found`，`$HOME/...` 会把字面量当路径。必须写绝对路径；README 已说明把 `/home/kunweiz` 换成各自的 home。

`args` 里 `--host` 之后的两个路径同样是宿主路径：它们由宿主的 `flatpak-session-helper` 执行，不经过沙盒的文件系统。写成沙盒内可见的路径（例如复制到 `~/.var/app/...`）反而会找不到。

### 6.5 为什么不能把 `bin/wps-mcp` 当 command

`bin/wps-mcp` 的 `EXT_ROOT=/app` 只在 `flatpak run --command=wps-mcp org.agentzero.AgentZero.Wps` 的挂载命名空间里成立。宿主直接执行会以 rc=1 退出并打印 `wps-mcp: bun is missing from the extension`。同理，把 `bin/wps-mcp` 当 command 再传 `dist/index.js` 也不对：脚本会把多余的参数透传给 server。

### 6.6 沙箱可见性：直接 exec 宿主 bun 不够（P0）

在同一宿主的主包沙箱里实测：

```text
$ flatpak run --command=sh org.agentzero.AgentZero -c 'test -x "$HOME/.local/share/flatpak/app/.../bin/bun" && echo BUN_VISIBLE || echo BUN_MISSING'
BUN_MISSING
$ ... -c 'ls -la "$HOME/.local/share/flatpak"'
total 0
drwxr-xr-x 2 kunweiz kunweiz 40 ... .
drwx------ 1 kunweiz kunweiz 1082 ... ..
```

这些检查用 `flatpak run --command=sh` 启动短命 sandbox，只读文件系统；没有连接 5080、没有改运行实例的状态。

`--filesystem=host` 不覆盖 Flatpak 自己的安装树：`~/.local/share/flatpak` 在沙箱里是空目录。沙箱内也没有 `flatpak` 命令；`flatpak-spawn --host` 报 `Portal call failed: org.freedesktop.DBus.Error.ServiceUnknown`，因为主包没有 `org.freedesktop.Flatpak` talk 权限。system 路径 `/var/lib/flatpak` 同样不可见（本机该目录不存在；Flatpak 对 system 安装树的处理与 user 树一致，这一条为 [INFERENCE]）。

结论（发现时）：直接 exec 宿主 `bun` 的配置在 A0 主包内不可用。修复与实测见 §12：`flatpak-spawn --host` 加一条 talk 权限即可在沙盒内启动。

## 7. 对照 `test-matrix.md` I 类

任务书写的是 C48-C51；`test-matrix.md` 的 I 类实际是 **C49-C52**（C48 属于 H 桌面类）。下表按表内编号逐条标状态。

| CASE | 项目 | 状态 | 依据 |
| --- | --- | --- | --- |
| C49 | 配置语法与可执行 | **按新形态通过；旧判据需更新** | 旧判据检查 `command` 指向 `~/.local/share/flatpak/...`。方案 A 的 `command` 是 `/usr/bin/flatpak-spawn`（沙盒内存在、宿主不存在），旧 `test -x "$CMD"` 在宿主会失败。替代检查：宿主 `test -x args[2]` 与 `test -f args[3]` 通过；沙盒内 `test -x /usr/bin/flatpak-spawn` 通过。A0 的 `usr/settings.json` 当前不存在，"已注册"前置未满足。 |
| C50 | `initialize` 握手 | **通过** | rc=0；`serverInfo = wps-office-mcp 1.0.0`；`protocolVersion = 2024-11-05`；无 `FileNotFoundError`。 |
| C51 | `tools/list` 非空 | **通过** | 250 个工具；含 `wps_check_connection`；全部有 `inputSchema`。 |
| C52 | 无宿主 WPS 时调用 | **通过** | rc=0；3 个调用都返回结构化 `content`；`wps_common_get_app_info` 返回 `isError=true` 可读错误；最慢 30.0 s < 90 s。 |

无 WPS 宿主下可判通过的验收项：**C50、C51、C52 全部通过；C49 的命令层通过，注册层未执行**。C49 的"配置层通过"不等于"A0 内能连上"：§6.6 的沙箱可见性仍是阻断项。

## 8. 发现的问题

### P0-1 原配置指向不存在的 node 与 system 路径（已修）

`bin/node` 不在扩展里；`/var/lib/flatpak` 在本机不存在。已改为 user 安装的 `bin/bun` + `dist/index.js`。

### P0-2 主包沙箱看不见扩展树（已解决）

证据见 §6.6。影响：在 `org.agentzero.AgentZero` 内，MCP 客户端做 `which("/home/kunweiz/.local/share/flatpak/.../bin/bun")` 时该路径不存在，server 无法启动。system 变体不解决。

已用 `flatpak-spawn --host` 解决：主 manifest 加 `--talk-name=org.freedesktop.Flatpak`，配置的 `command` 改为 `/usr/bin/flatpak-spawn`。沙盒内的 `initialize`、`tools/list`（250）与两次 `tools/call` 已实测通过，见 §12。代价是这条权限也允许沙盒在宿主执行任意命令；主包已有 `--filesystem=host`，实际增量有限，但这是真实的边界放宽。

### P1-1 无 WPS 时连接探测要等 30 秒

`wps_check_connection`、`wps_common_ping`、`wps_common_get_app_info` 都先在 58891 排队，30 s 后才超时。A0 的 `tool_timeout` 默认 0（不超时），界面会长时间无反馈。建议把加载项是否在轮询作为前置检查，未连接时立即返回。

### P1-2 `wps-auto.sh` 是 macOS 脚本

`switch_to` 调 `open`（Linux 无此命令）、`/tmp/server.log`（Linux 轮询服务不写这个文件）、`pkill -f wpsoffice`。宿主无 WPS 时 `pkill` 无匹配，不会误杀；但任何触发 `switchApp` 的工具会在失败前多花约 35 s。`COMMAND_APP_MAP` 把 216 个 action 映射到 excel/word/ppt，覆盖了绝大多数文档工具。

### P2-1 `wps_check_connection` 失败却 `isError=false`

handler 无条件 `success: true`，只把 `connected:false` 放进文本。MCP 层看起来是成功调用，模型可能据此继续操作。`wps_common_get_app_info` 在同类失败下返回 `isError=true`，两者语义不一致。

### P2-2 `bin/wps-mcp` 不能在宿主直接使用

`EXT_ROOT=/app` 是设计使然，但文档若建议把它当 MCP `command` 会直接失败。README 已明确禁止这种写法。

### P2-3 文档与源码注释的数量不符

`dist/tools/index.js` 写 247 个、PPT 112 个；实测 250 个、PPT 115 个。

### P2-4 任务书里的路径与实际布局不符

任务书写 MCP server 在 `share/wps-office-mcp`；实际在 `wps-skills/wps-office-mcp`。按任务书给的路径 `ls`、`find` 都会失败。

### P3-1 每个 MCP 客户端实例都写同一份日志

日志固定写 `~/.wps-office-mcp/logs/`，没有清理策略。本轮多次启动后 `combined.log` 已 231 KB。

## 9. 未覆盖项

- WPS Office 安装后的真实文档操作（打开、读、写、转换）。宿主没有 WPS，属于环境不具备。
- 加载项安装与端到端轮询：`bash flatpak/install-wps-addon.sh` 实测在 `command -v wps` 检查处退出，rc=1，未写任何文件。
- 58891 端口上真实加载项的往返、`switchApp` 成功路径。
- Agent Zero UI 内的 MCP 连接状态：需要改运行实例的设置并重启，本轮不触碰。
- system 安装形态的真实路径（本机无 system 安装，只验证了结构）。
- 250 个工具逐一调用（只抽 3 个）。

## 10. 交付与生效范围

本轮改了三个文件：`flatpak/org.agentzero.AgentZero.yml`（权限）、`flatpak/wps-mcp-config.json`、`flatpak/README.md`。

- manifest 改动进入主包，**必须重建并重装主包**才进入产物：
  `flatpak-builder --user --install --force-clean state/main flatpak/org.agentzero.AgentZero.yml`。
- 已安装的主包可以先不重建，用一条 override 获得同等权限：
  `flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero`。
  这条命令本轮实测有效，撤销用 `flatpak override --user --reset org.agentzero.AgentZero`。
- `wps-mcp-config.json` 与 `README.md` 不被安装进任何 bundle。前者要重新粘贴到 Settings → MCP；后者只是文档。

本轮没有修改运行实例的 `settings.json`，也没有注册 MCP server。

## 11. 复现与证据文件

| 文件 | 内容 |
| --- | --- |
| `~/a0-local-backup/wps-mcp/wps_mcp_probe.py` | 探针脚本（握手、工具列表、工具调用） |
| `~/a0-local-backup/wps-mcp/run1/summary.json` | 第一轮：250 工具；`wps_list_cache` 3 ms；`wps_check_connection` 30,012 ms |
| `~/a0-local-backup/wps-mcp/run1/rpc.jsonl` | 第一轮原始 JSON-RPC 往返 |
| `~/a0-local-backup/wps-mcp/run1/tools.json` | 250 个工具的完整 `name`/`description`/`inputSchema` |
| `~/a0-local-backup/wps-mcp/run2/` | 第二轮：`wps_common_get_app_info` 30,010 ms，`isError=true` |
| `~/a0-local-backup/wps-mcp/probe-run.log` | 第一轮 stdout |
| `~/a0-local-backup/wps-mcp/probe-appinfo.log` | 第二轮 stdout |
| `~/a0-local-backup/wps-mcp/readme-handshake.log` | README 精简脚本实跑输出 |
| `~/a0-local-backup/wps-mcp/sandbox-check.sh` | 沙盒内检查 `flatpak-spawn` 与宿主路径 |
| `~/a0-local-backup/wps-mcp/sandbox-handshake.py` | 沙盒内经 `flatpak-spawn --host` 完成握手并调用两个工具 |
| `~/a0-local-backup/wps-mcp/sandbox-handshake.log` | 上述输出（含 30 s 连接探测） |
| `~/a0-local-backup/wps-mcp/sandbox-shutdown.py` | 关闭行为：stdin EOF、SIGTERM、`--watch-bus` |
| `~/a0-local-backup/wps-mcp/sandbox-shutdown-nowatch.log` / `-watch.log` | 两种关闭测试输出 |
| `~/a0-local-backup/wps-mcp/readme-sandbox-handshake.log` | README 沙盒脚本实跑输出 |
| `~/.wps-office-mcp/logs/combined.log` | server 自身日志（含 30 s 超时记录与 SIGTERM 关闭） |

复现主命令：

```bash
python3 "$HOME/a0-local-backup/wps-mcp/wps_mcp_probe.py"
```

预期最后一行 `WPS_MCP_OK`，总耗时约 35 s（含 30 s 连接探测）。

沙盒形态的复现命令：

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero
flatpak run --user --command=/usr/bin/python3 org.agentzero.AgentZero \
  /home/kunweiz/a0-local-backup/wps-mcp/sandbox-handshake.py
flatpak override --user --reset org.agentzero.AgentZero
```

预期：`SANDBOX_WPS_OK`，`tools: 250`，`wps_list_cache` 在 10 ms 内返回。

## 12. 沙箱内能否启动 WPS MCP（方案验证）

§6.6 的发现是：主包沙箱内 `~/.local/share/flatpak` 是空目录，`flatpak` 命令不存在，`flatpak-spawn --host` 因缺少 talk 权限失败。本节验证修复，并给出 A/B/C 三方案的取舍。

### 12.1 试验方法与现场保护

试验前 `~/.local/share/flatpak/overrides/org.agentzero.AgentZero` **不存在**，所以没有其他 override 需要保护。试验只影响新进程；运行中的 A0 实例没有重启，也没有改它的配置。每条测试结束后立即 reset：

```bash
flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero
# 测试
flatpak override --user --reset org.agentzero.AgentZero
ls ~/.local/share/flatpak/overrides/org.agentzero.AgentZero   # 期望：不存在
```

最终状态已确认：override 文件不存在，`flatpak info --show-permissions org.agentzero.AgentZero` 回到 manifest 自带的权限，没有残留。

### 12.2 最小权限集

**只需要 `--talk-name=org.freedesktop.Flatpak`。** 没有添加 `--socket=session-bus`，没有给 WPS 树加 `--filesystem`，也没有添加其他 talk 名。

证据：

- 加权限前：`flatpak-spawn --host ...` → `Portal call failed: org.freedesktop.DBus.Error.ServiceUnknown`。
- 只加这一条后：`flatpak-spawn --host /bin/echo SPAWN_OK` → `SPAWN_OK`；`flatpak-spawn --host <bun> --version` → `1.4.4`。
- 宿主侧 `$HOME` 正确：`flatpak-spawn --host bash -lc 'echo $HOME'` 输出 `/home/kunweiz`。这条用单引号，让 `$HOME` 在宿主 shell 展开；若在沙盒侧展开，本机结果相同，但语义不同。

### 12.3 完整命令与输出

（1）沙盒内路径检查。命令：

```bash
flatpak run --user --command=sh org.agentzero.AgentZero \
  -c 'sh /home/kunweiz/a0-local-backup/wps-mcp/sandbox-check.sh'
```

输出：

```text
--- inside sandbox ---
SANDBOX_HOME=/home/kunweiz
SANDBOX_PATH=/app/bin:/usr/bin
SPAWN_BIN=/usr/bin/flatpak-spawn
--- host side through flatpak-spawn ---
HOST_HOME=/home/kunweiz
HOST_PWD=/home/kunweiz/Desktop/a0lite
HOST_PATH=/home/kunweiz/.bun/bin:...（截断）
/usr/bin/flatpak
BUN_EXEC_OK
SERVER_OK
1.4.4
spawn_rc=0
```

（2）沙盒内 MCP 握手。命令：

```bash
flatpak run --user --command=/usr/bin/python3 org.agentzero.AgentZero \
  /home/kunweiz/a0-local-backup/wps-mcp/sandbox-handshake.py
```

输出：

```text
command: /usr/bin/flatpak-spawn --host .../bin/bun .../dist/index.js
startup_ms: 161
protocolVersion: 2024-11-05
serverInfo: wps-office-mcp 1.0.0
tools: 250
first5: wps_check_connection, wps_get_active_document, wps_insert_text, wps_get_active_workbook, wps_get_cell_value
all_have_name_and_inputSchema: true
call wps_list_cache: 2ms isError=False text={"success":true,"count":0,"caches":[]}
call wps_check_connection: 30010ms isError=False text={"connected":false,"status":{"connected":false,"error":"Connection check failed"}}
```

这不是短命特例：30 秒的 `wps_check_connection` 也通过 `flatpak-spawn` 的 stdin/stdout 正常返回，说明长轮询不破坏管道。

（3）关闭行为。命令：

```bash
flatpak run --user --command=/usr/bin/python3 org.agentzero.AgentZero \
  /home/kunweiz/a0-local-backup/wps-mcp/sandbox-shutdown.py [--watch-bus]
```

输出（不带 `--watch-bus`）：

```text
server: {'name': 'wps-office-mcp', 'version': '1.0.0'}
call: {"connected":false,...}
stdin_close_exit: STILL_RUNNING
after_stdin_close: 宿主侧可见 flatpak-spawn 与 bun（pgrep 原文）
sigterm_exit: 0
after_sigterm: 只剩 pgrep 自身（bun 已退出）
```

带 `--watch-bus` 的结果相同。结论：

- 关闭 stdin **不会**让 server 退出。`wps_check_connection` 会启动 58891 的 poll server，它让事件循环保持存活。
- SIGTERM 会干净退出，宿主侧不留 bun。
- `--watch-bus` 让宿主进程在调用方消失时被清理，用于防 A0 崩溃后的孤儿；它不改变握手与 SIGTERM 行为。
- 本轮早期用 SIGKILL 杀 `flatpak-spawn` 时留下过一个宿主 bun（PID 1683897，占用 58891），已手动 kill。SIGKILL 不会转发，`--watch-bus` 正是覆盖这个场景。

（4）README 精简脚本。从 README 原文抽出后实跑：

```text
{'name': 'wps-office-mcp', 'version': '1.0.0'}
250 ['wps_check_connection', 'wps_get_active_document', 'wps_insert_text', 'wps_get_active_workbook', 'wps_get_cell_value']
real    0m0.309s
```

（5）残留检查。清掉 SIGKILL 留下的那个孤儿之后，最终状态：`pgrep -af wps-skills/wps-office-mcp/dist/index.js` 无输出，`ss -ltn` 无 58891，override 文件不存在。

### 12.4 三方案对比

| 方案 | 可验证性 | 取舍 |
| --- | --- | --- |
| **A. `flatpak-spawn --host` + talk 权限** | **已实测通过** | 改动最小：manifest 1 条权限，config 改 `command` 与 `args`。代价是沙盒获得在宿主执行命令的能力；主包已有 `--filesystem=host`，实际增量有限，但这是真实的边界放宽。 |
| B. 把 `dist/` 与 `node_modules` 打进主包 | 未验证 | `dist` 约 1.9 MB、`node_modules` 约 94 MB（未压缩）。`flatpak/wps-office-mcp-deps.tar.gz` 被 `.gitignore` 忽略、仓库里不存在，只能在构建时用 `scripts/build-wps-deps.sh` 重新生成（需要网络与 bun）。主包会增大，且与 WPS 扩展的版本可能漂移。 |
| C. 不再声称主包内可启动，只给宿主侧方案 | 不需要 | A 已验证，降级会丢掉实际能力。 |

推荐 **A**。B 的收益是避免权限放宽，但代价是主包体积、构建依赖与版本漂移；如果以后沙箱边界需要收紧，再把 B 作为替代方案评估。

### 12.5 选 A 的精确 diff

`flatpak/org.agentzero.AgentZero.yml`（只显示本轮新增的 6 行）：

```diff
@@ -19,6 +19,12 @@ finish-args:
   - --filesystem=host-etc:ro
   - --filesystem=host-os:ro
   - --filesystem=/run/udev:ro
+  # flatpak/wps-mcp-config.json starts the WPS MCP server through
+  # `flatpak-spawn --host`, because Flatpak hides its own install tree from
+  # the sandbox. This talk permission is the minimum that allows it; it also
+  # lets the agent run commands on the host, which --filesystem=host already
+  # permits in effect.
+  - --talk-name=org.freedesktop.Flatpak
   - --env=OLLAMA_HOST=http://127.0.0.1:11434
```

注意：这份 diff 是基于当前工作树。`org.agentzero.AgentZero.yml` 里还有别的未提交改动（Xpra jQuery），不属于本轮，不能混入本轮的提交。

`flatpak/wps-mcp-config.json`（整文件）：

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

### 12.6 `add-extensions` 核实

- `flatpak/org.agentzero.AgentZero.yml` 的 `add-extensions` 只有 `org.agentzero.AgentZero.Models` 与 `org.agentzero.AgentZero.Cuda`，没有 WPS。
- `flatpak/org.agentzero.AgentZero.Wps.yml` 顶层是 `app-id: org.agentzero.AgentZero.Wps` 与 `command: wps-mcp`，依赖 `org.freedesktop.Platform`。安装 ref 是 `app/org.agentzero.AgentZero.Wps/x86_64/1.0`。
- 结论：WPS 是独立 **app**，不是 runtime；主包也没有为它声明 extension point。所以"主包通过扩展挂载点看到 WPS 载荷"这条路**本来就不存在**。要走这条路，需要新增 `add-extensions` 声明，并确认 app 类型的 ref 能否作为 extension 使用；本轮没有验证，且与 A 相比收益不明显。

### 12.7 是否需要重建主包

- 要让**新安装**的主包自带 talk 权限：需要重建并重装主包（manifest 改动）。
- 对**已安装**的主包：`flatpak override --user --talk-name=org.freedesktop.Flatpak org.agentzero.AgentZero` 立即生效，不需要重建。本轮就是这样验证的。
- `wps-mcp-config.json` 与 README 不进入 bundle：前者重新粘贴到 Settings → MCP，后者只是文档。

本轮结束时 override 已撤销，运行中的 A0 实例未被重启，`settings.json` 未被修改。
