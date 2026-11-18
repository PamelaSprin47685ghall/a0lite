# a0lite 安全边界测试

- 实例：`http://127.0.0.1:5080`，PID 1995463，包 commit `ab3d8e6150f7…`（应用 `058582f-dirty`）
- 方法：只读命令实测；`/a0/a0-link-etc -> /etc` 测试链接已删除
- 日期：2026-11-18

## §1 权限全景

`flatpak info --show-permissions org.agentzero.AgentZero` 原文：

```
[Context]
shared=ipc;network;
sockets=pulseaudio;x11;
devices=dri;
filesystems=host-etc:ro;host-os:ro;/run/udev:ro;host;

[Session Bus Policy]
org.freedesktop.Flatpak=talk

[Environment]
OLLAMA_HOST=http://127.0.0.1:11434
```

`~/.local/share/flatpak/overrides/` 与 `/var/lib/flatpak/overrides/` 均无本包文件。这些权限是 manifest 默认值，不是本机 override。

| 权限 | 用途（manifest 注释/实测） | 风险 |
|---|---|---|
| `shared=ipc` | Xpra、输入法共享 IPC | 中：与宿主进程共享 IPC，配合 X11 扩大面 |
| `shared=network` | Ollama、浏览器、局域网 | 高：沙盒内 `127.0.0.1:5080` 直打实例；LAN 可达（实测 `.80:80` 返回 404） |
| `socket=x11` | 桌面、剪贴板 | 高：X11 无隔离，可截屏、记键、注入其它窗口 |
| `socket=pulseaudio` | TTS/STT | 中：可录麦克风 |
| `device=dri` | GPU | 低 |
| `filesystem=host` | “agent 在真机上工作” | 高：宿主 `/home` 全量 rw；`.ssh`、`.gnupg`、`.config` 均可读 |
| `filesystem=host-etc:ro` | 系统配置 | 中：宿主 `/etc` 只读合并；`/etc/shadow` 被排除（沙盒内不存在） |
| `filesystem=host-os:ro` | 系统二进制 | 中：宿主 `/usr` 可读，配合执行面可跑宿主工具 |
| `filesystem=/run/udev:ro` | 设备枚举 | 低 |
| `org.freedesktop.Flatpak=talk` | WPS MCP 用 `flatpak-spawn --host` | **极高：任意宿主命令** |
| `OLLAMA_HOST=…` | 本地模型地址 | 无 |

## §2 19 项结果

| # | 尝试 | 实际结果 | 风险 |
|---|---|---|---|
| A1 | `ss -tlnp \| grep 5080` | `127.0.0.1:5080`，仅 loopback | 无 |
| A2 | 访问 `192.168.123.80:5080` | `nc` Connection refused；`curl` 000；LAN 不可达 | 无 |
| A3 | `--show-permissions` 全量 | 见 §1；`host` + `talk-name` 同时存在 | 高 |
| B4 | 沙盒内 `ls /`、`ls /home`、`cat /etc/passwd` | 根完整；`/home/kunweiz`；`passwd` 是 109 B stub（uid 1000） | 高 |
| B5 | 沙盒内 `ls ~` | 123 项，与宿主家目录一致：**真 home，非映射** | 高 |
| B6 | 沙盒内 `flatpak-spawn --host id` | 成功，rc=0；宿主 uid 1000，组含 `wheel,lp,network` | 高 |
| B7 | `flatpak-spawn --host cat /etc/shadow` | `Permission denied`（root:root 600，uid 1000 被 DAC 挡住） | 中 |
| B8 | 沙盒内 `test -r ~/.ssh/id_*`、`ls ~/.gnupg` | `id_ed25519`、`authorized_keys`、`.gnupg` 均可读；GPG 私钥目录为空 | 高 |
| B9 | 沙盒内 `curl 192.168.123.80` | 返回 404，**共享宿主网络，LAN 可达**；`.92` 无服务为 000 | 高 |
| C10 | 无 cookie/token `GET/POST /api/message` | 403 `CSRF token missing or invalid`（不是 401） | 中 |
| C11 | 带 `a0key=wrong` | 仍 403（CSRF）；`A0_AUTH_KEY` 为空，auth 中间件未装载，错误 key 无意义 | 中 |
| C12 | `Origin: http://evil.com`；无 Origin | `/api/csrf_token` 应用层拒绝；伪造 `Origin: http://127.0.0.1:5080` 即发 token；`/api/message` 本身不校验 Origin | 中 |
| C13 | `GET /api/get_work_dir_files?path=/etc`（带合法 token） | 200，列出 `/etc` 全部条目 | 高 |
| C14 | `/a0/a0-link-etc -> /etc`，`?path=/a0/a0-link-etc/passwd` | 200，返回 109 B passwd；目录列表同样 200 | 高 |
| D15 | `/api/message` 指令跑 `id;pwd` | 沙盒内 uid 1000，组 `65534`，pwd `…/usr/workdir` | 中 |
| D16 | 同一消息内跑 `flatpak-spawn --host id` | 成功；宿主组 `3(sys),90(network),98(power),989(lp),998(wheel),1000(autologin)` | 高 |
| D17 | 评估 D16 是否设计意图 | 是：manifest 注释明写“also lets the agent run commands on the host” | 中 |
| E18 | `--show-runtime` / manifest | `org.freedesktop.Platform 25.08`、SDK 25.08；Cuda/Models 以主包 `master` 为 base | 低 |
| E19 | `grep curl\|wget\|pip install`、依赖清单 | 无 `curl \| sh` 构建步骤；uv 0.13.6 与 7 个 deb 全部 sha256；40 条精确 pin，25 条 `>=` 下界，无 hash lock | 中 |

**合计：高 9、中 7、低 1、无 2。**

## §3 四个高风险面

**1. `--talk-name=org.freedesktop.Flatpak`（最严重）。** 沙盒内 `flatpak-spawn --host id` 直接成功，B6 与 D16 两条独立路径互证；宿主 `/etc/shadow` 读不了，但 `/home/kunweiz` 全部可读，`.ssh/id_ed25519` 可读。这不是“可能逃逸”，而是默认能力。manifest 注释承认它能跑宿主命令，并称 `--filesystem=host` 已等效——但 `--filesystem=host` 只给文件，`talk-name` 给的是任意进程执行，两者不等价。配合无认证 WebUI，攻击链是“HTTP 请求 → 取 CSRF token → `/api/message` → 宿主 shell”。

**2. 无 `A0_AUTH_KEY`。** 实例只绑 `127.0.0.1`，公网/LAN 不可达，这是当前唯一的有效边界。本机任意进程只需两步：`Origin: http://127.0.0.1:5080` 取 token，再带 token 调 `/api/message`；无需任何身份。沙盒内代码同样能打（`127.0.0.1:5080/api/health` 实测 200）。CSRF 只挡浏览器跨站，挡不住本机进程与非浏览器客户端。

**3. 文件 API 路径与符号链接。** 根因不是“穿越检查被绕过”，而是 `FileBrowser.base_dir="/"` 和 `resolve_download_path(path, Path("/"))` 把根设成了整机：`relative_to("/")` 永远成立，`startswith("/")` 永远通过。实测 `?path=/etc` 200，`/a0/a0-link-etc/passwd` 200，宿主 `.bashrc` 200、`.ssh/authorized_keys` 200。符号链接因此也不需要“绕过”，它只是全盘浏览的一个入口。

**4. 代码执行面。** `/api/message` 里 agent 的 `code_execution_tool` 使用本地 PTY（`LocalInteractiveSession` → `TTYSession`），执行在沙盒 uid 1000；同一条消息内再 `flatpak-spawn --host` 即到宿主。设计上 agent 需要终端和工作目录，这部分合理；不合理的是“终端 + talk-name + 无认证”叠加后等于本机任意命令执行。D17 说明 WPS MCP 需要 talk-name，但没有说明为什么主包必须常驻该权限。

## §4 建议（按修复成本排序）

必须修：

1. `A0_AUTH_KEY` 为空时拒绝非 loopback 绑定，或启动时生成随机 key 写入 `.env` 并显示一次。成本：低，`serve.py` + `agent-zero.sh`。
2. 主包移除 `--talk-name=org.freedesktop.Flatpak`，改为 WPS 扩展启用时才授权；WPS 也可用 `--filesystem` 暴露其安装树替代 `flatpak-spawn`。成本：低，manifest。
3. 文件 API 根从 `/` 收回 `/a0`；若产品坚持整机浏览，加显式开关与敏感路径拒绝表（`.ssh`、`.gnupg`、`.config`、keyring）。成本：低（一行 + 过滤），但会改变“浏览整机”的产品语义，需明确决策。
4. 首次启动一次性横幅：本应用可读写整个 home 并可在宿主执行命令。成本：低。

应该修：

5. 默认启用 login/password，或首次运行强制设 key。成本：中。
6. 依赖加 hash lock（`uv lock` 或 `--require-hashes`），消除 25 条无上界约束。成本：中。
7. 主包不直接拿宿主 X11，改用 xpra 窗口级转发。成本：中高。

可接受：

8. 绑定 `127.0.0.1`（已正确，保持）。
9. 宿主 `/etc/shadow` 不可读（Linux DAC 有效）。
10. `host-etc:ro`、`host-os:ro`、`/run/udev:ro` 只读。
11. 构建源全部 sha256 固定，构建脚本无 `curl | sh`。

**能否暴露公网：不能。** 目前仅 loopback；一旦改 `0.0.0.0` 或加反向代理，任何能连端口的人都能在无认证情况下读全盘并在宿主执行命令。即使补上 key，`talk-name` + `filesystem=host` 仍使它只适合单用户本机。

## §5 与安全相关的 D 台账条目

`report.md` 现有：**D06** Xpra shadow 分支无认证（已修）；**D07** CSRF/Origin 默认值（已修）；**D17** 为 WPS 引入 `--talk-name`（功能修好，副作用未评估）；**D19** 是 `xiaomi-ocr` manifest 误判，与安全无关。

用户所说“D19 是 `--talk-name` 那条”与仓库不符：`--talk-name` 记在 **D17**（`org.agentzero.AgentZero.yml:27`）。本轮发现不修改 `report.md`，在此登记：

| 新编号 | 风险 | 结论 | 证据 |
|---|---|---|---|
| S1 | 高 | `A0_AUTH_KEY` 默认空，WebUI 无身份认证 | C10–C12 |
| S2 | 高 | 文件 API 根为 `/`，全盘可读 | C13–C14 |
| S3 | 高 | `--talk-name` 使 agent 可在宿主执行命令 | B6、D16 |
| S4 | 中 | 依赖无 hash lock，25 条仅下界 | E19 |
