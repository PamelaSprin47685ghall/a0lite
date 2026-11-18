# systemd 静态复核（C53–C57）

日期：2026-11-18。主机：Manjaro，systemd 261（261.3-1-manjaro），flatpak 1.18.4。只读仓库 + 暂存根；未写 `/etc`，未运行 `systemctl`，未 `sudo`。

## 1. 两个 unit 的静态检查表

`systemd-analyze verify systemd/agent-zero.service`：exit 0，无输出。
`systemd-analyze verify systemd/agent-zero-desktop.service`：

```text
agent-zero-desktop.service: Command /usr/local/bin/a0-desktop-start is not executable: No such file or directory
```

这是“助手尚未装到 `/usr/local/bin`”的预期错误；在暂存根补齐后 `systemd-analyze verify --root=...` exit 0（见 §2 D29）。

| 项目 | `agent-zero.service` | `agent-zero-desktop.service` | 证据 |
|---|---|---|---|
| `Type=` | `simple` | `oneshot` + `RemainAfterExit=yes` | unit 原文；oneshot 允许 `Restart=on-failure`，`always` 会被 verify 拒绝 |
| `ExecStart=` | `/usr/bin/flatpak run --user ...` | `/usr/local/bin/a0-desktop-start` | `test -x /usr/bin/flatpak` 通过；助手由安装器 755 落盘 |
| `Restart=` / `RestartSec=` | `always` / `5` | `on-failure` / `15` | 启动失败会重试；成功后的 Xpra 死亡不监督（D35） |
| `TimeoutStartSec=` | 默认（Type=simple 不等） | `300` | 默认 `DefaultTimeoutStartUSec=1min 30s`，小于脚本 120s health 等（D26） |
| `After=` / `Wants=` | `network-online.target` | `agent-zero.service`；`display-manager.service` 仅 After，检测到 DM 时 drop-in 补 Wants | 无 `graphical-session.target`：它是 user target，system unit 不能可靠排序 |
| `User=` / `Group=` | 无硬编码；drop-in `10-user.conf` | 同左 | base unit 内 `grep 'kunweiz\|1000\|/home/'` 无输出 |
| `Environment=` | 基座 `DISPLAY=:0`；drop-in XDG/DBUS/XAUTHORITY | 同左 | unit 自己设 `DISPLAY=:0`，不是缺变量；无 X server 时 `desktop.py` 回退 `/app/bin/Xvfb`；`/run/user/1000` 与 `~/.Xauthority` 本机存在，无登录启动由 linger + `user@1000` 兜底（D31） |
| `WorkingDirectory=` | drop-in `/home/kunweiz` | 不需要 | 目录存在；systemd 对 `WorkingDirectory=` 不剥引号，故安装器写裸路径并拒绝空白/引号/`%` |
| `StandardOutput=` | 未设 → journal | 未设 → journal | 无日志目录需要创建 |
| 硬编码路径 | `/usr/bin/flatpak` 存在；`/var/lib/flatpak` 未引用 | 同左；`/run/user/1000` 本机存在 | `flatpak list` 显示 `org.agentzero.AgentZero` 为 per-user 安装 |
| 互相冲突 | 只有它启动 `agent-zero.sh`（5080） | 只起 `flatpak run --command=sh`，不跑 launcher、不绑 5080 | 两个 unit 可同时启动；desktop 等 health |

## 2. 发现的缺陷与修复

| 编号 | 严重度 | 文件 | 改了什么 | 复验 |
|---|---|---|---|---|
| D25 | 高 | `systemd/agent-zero.service`、`agent-zero-desktop.service` | app 改 `WantedBy=multi-user.target` 并去掉 DM 依赖；desktop 改 `WantedBy=graphical.target multi-user.target` | `--root` verify exit 0；staged `WantedBy` 原文 |
| D26 | 高 | `agent-zero-desktop.service` | 加 `TimeoutStartSec=300` | `DefaultTimeoutStartUSec=1min 30s`；verify exit 0 |
| D27 | 高 | `systemd/a0-desktop-start` | `available=False` 时 `raise SystemExit(1)` | fake flatpak exit 7 传播为 7；`sh -n` OK |
| D28 | 高 | 两个 unit + `scripts/install-services.sh` | 用户身份移入 drop-in；`id -gn`；拒绝 UID 0；字符白名单；`set -euo pipefail` | staged drop-in 原文；`root`/未知用户 exit 1；base unit 无硬编码 |
| D29 | 中 | `scripts/install-services.sh` | stage → verify → drop-in 先落盘 → 临时文件 `mv` → `reenable` | 两次 staging `diff -r` exit 0；`--root` verify exit 0 |
| D30 | 中 | `scripts/install-services.sh` | 120s 未 200 时 `exit 1` 并提示 journal | 代码路径；`bash -n` OK；未在真机触发 |
| D31 | 中 | `scripts/install-services.sh` + drop-in | `loginctl enable-linger`；drop-in `Wants/After=user@<uid>.service` | drop-in 原文；`user@.service` 的 `BindsTo=user-runtime-dir@%i` |
| D32 | 低 | `systemd/a0-desktop-start` | 数据目录改用 `${XDG_DATA_HOME:-$HOME/.local/share}/agent-zero` | 沙盒内 `XDG_DATA_HOME=/home/kunweiz/.var/app/.../data`，与 launcher 同值 |
| D33 | 低 | `systemd/a0-desktop-start` | health URL 读 `A0_PORT`，默认 5080 | `sh -n` OK；health 200 时 fake flatpak 流程通过 |
| D34 | 低 | `systemd/a0-desktop-start` | 默认 Xauthority 不可读时回退 GDM/mutter cookie | 本机 `~/.Xauthority` 存在；GDM 路径不存在，无法本机复现 |
| D35 | 中 | `README.md`、本文档 | 明确 desktop unit 是 launcher 不是 supervisor；C56/C58 不能只信 `is-active` | README §Running as a service |

## 3. `install-services.sh` 的幂等性与失败语义

- 语法与注入：`set -euo pipefail`；所有变量展开加双引号；不再用 `sed`，用户/组/home 经字符白名单后由 `printf` 生成，`&`、`|`、`\`、`%` 不会进入 unit。
- 幂等：同一用户连续两次 `A0_STAGE_ROOT=... scripts/install-services.sh kunweiz` 的产物 `diff -r` 为空；两次的 unit/drop-in sha256 相同。生产路径每次覆盖同内容，`systemctl reenable` 还会清掉旧 `WantedBy` 留下的 target 链接。
- 失败前置：先校验用户、UID≠0、主组、home 绝对路径与字符集，再 stage；`systemd-analyze verify` 在写 `/etc` 前执行。未知用户/root 在写文件前 exit 1（本次实测 0 个文件落盘）。
- 半装：drop-in 先于 unit 落盘；unit 的 `AssertPathExists` 在 drop-in 缺失时直接失败，不会以 root 启动。`place` 用同目录临时文件 + `mv`，避免 `sed >` 截断。
- 运行期失败：`systemctl restart`、`is-active` 或 health 超时会 exit 1；unit 文件已完整安装并 enabled，这属于“装好了但没跑起来”，不是文件半装。安装器不自动回滚，重跑即可。

## 4. C53–C57：静态可判定与必须真机

| 用例 | 静态已能判定 | 必须真机 |
|---|---|---|
| C53 | 两个 unit 语法/依赖/ExecStart 可在暂存根 verify；drop-in 生成正确 | `systemctl is-enabled` 的两个 `enabled` 状态、真实 `/etc` 路径 |
| C54 | `Type=simple`、`Restart=always`、health URL 与 5080 | `systemctl restart` 后 200 的耗时与 `is-active` |
| C55 | `Restart=always`/`RestartSec=5` 语义正确 | kill -9 后 MainPID 变化、10s 内恢复 |
| C56 | 已消除 `graphical.target` 单目标阻塞；desktop 同时挂 multi-user | 真实重启、两个 unit 的 active、health 200；desktop 启动后 Xpra 死亡不监督（D35） |
| C57 | 只能确认 unit 会写 journal（未设 StandardOutput） | `journalctl -u agent-zero` 的重启记录与权限 |

结论：C53 的 verify 部分与 C56 的 target 阻塞已静态判定；C54/C55/C57 的核心断言、C53 的 enabled 状态、C56 的真实开机仍必须真机 `systemctl`。最可能在 760K 上真炸的是 D25（tty-only 到不了 `graphical.target`）。
