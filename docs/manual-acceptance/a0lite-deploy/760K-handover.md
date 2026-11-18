# 760K 交接单（现场恢复 + 交付部署）

> **2026-11-18：760K 目标机确认死亡（换内核后 10.5 小时未回连，无带外恢复手段），本项目转为本机 AMD Vulkan 交付**；以下恢复步骤与 760K 专属探测保留作历史记录。

## 1. 一句话状态

截至 **2026-11-18 09:45:48**，760K 自 **2026-11-17 23:12** 起整机不在线，已约 **10.5 小时**未回连；`kernel-gpu` 的探测循环已停；恢复按 §3 三种情形择一执行，恢复后按 §4–§5 部署。

最后探测 **09:45:48**：SSH `Connection timed out during banner exchange` / `frp5080=000` / ARP `192.168.123.92 dev wlp4s0 FAILED`。此前 08:09:04、08:20:45、08:25:53、09:30:16 四次探测同样离线。

---

## 2. 时间线

| 时间 | 事件 | 证据 |
|---|---|---|
| 22:57:30 | **最后一次正常**：xtcp 打洞成功，对端 `192.168.123.92:43318` | 本机 `journalctl -u frpc` |
| 23:04–23:06 | 部署前准备（备份、旧状态快照、sha256 对比）全部成功 | `target-prep.md §1–§9` |
| ~23:07–23:10 | 事务一：8 个包升到 615 驱动；事务二：装 `linux72 7.2.9-1` + headers + `linux72-nvidia-open 615.71.09-7` | `kernel-gpu-migration.md §3.3/§3.4` |
| 23:10 | `/boot/vmlinuz-7.2-x86_64`、`initramfs-7.2-x86_64.img` 生成；`modinfo -k 7.2.9-1-MANJARO` 的 vermagic 逐字符匹配 | 同上 §3.5、§4.3 |
| 23:11:38 | `systemctl reboot`；grubenv 同时有 `saved_entry=<7.2.9 id>` 与 **`next_entry=1>1`**（存疑项） | 同上 §4.2/§4.4 |
| **23:12:16** | 首次 `get tunnel connection error` → `xtcp server for [ssh-tunnel-12022-xtcp] doesn't exist` | `760K-connectivity-hunt.md §9` |
| 23:12–23:40 | visitor 每 10 秒重复报错；本机 frpc 控制通道一直 ESTAB，frps 未重启 | 同上 §2、§9 |
| 23:24–23:40 | 局域网 22 端口只有 `.43/.97/.253/.254`；`.92` ARP `INCOMPLETE`；frps:12022 接受后 6 秒关闭、无 banner | 同上 §5、§7 |
| 23:29 | 借 7640HS（`.43`）复核：`.92` 仍 `INCOMPLETE`，22/12022 都不通 | 同上 §5 |
| 05:2x | 探测循环终止；整机仍未回连 | 交接说明 |

---

## 3. 现场恢复操作卡（12 步以内，三选一）

**前提**：显示器 + 键盘接到 760K。所有命令都在 760K 本机执行（情形 B 除外）。

### A. 停在 GRUB 菜单

| # | 操作 | 成功判据 |
|---|---|---|
| 1 | 开机自检刚过、logo 消失时**连按 `Esc`**（有的固件是按住 `Shift`） | 出现 Manjaro GRUB 菜单 |
| 2 | ↓ 选 `Advanced options for Manjaro Linux` → 选 **`Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)`** → 回车，等 90 秒 | 屏幕滚完内核日志，出现登录提示或桌面 |
| 3 | 进系统后立刻清掉一次性项并固定旧内核：<br>`grub-editenv /boot/grub/grubenv unset next_entry`<br>`grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'`<br>`grub-editenv /boot/grub/grubenv list` | `list` 里只剩 `menu_auto_hide` / `boot_success` / `saved_entry`，**没有 `next_entry`** |

两条菜单项标题原文（`/boot/grub/grub.cfg` 第 157、172 行）：

```text
Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)
Manjaro Linux (Kernel: 7.2.9-1-MANJARO x64)
```

两个 entry id（`--id` 原文）：

```text
旧 7.3.0-rc6-1  gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2
新 7.2.9-1      gnulinux-7.2.9-1-MANJARO x64-advanced-/dev/sda2
```

> 要**继续**验证新内核：第 2 步改选 `7.2.9` 那条，第 3 步 `saved_entry` 换成新内核 id。
> 注意 `grub-editenv` 没有 `-` 占位参数；`grub-editenv - set ...` 会把 `-` 当文件名，什么都不改。

### B. panic / emergency shell / 连 GRUB 都过不去

| # | 操作 | 成功判据 |
|---|---|---|
| 4 | Manjaro live USB 启动，开终端：`lsblk -f` | 看到 `sda2 f2fs`、`sda1 vfat`、`sda3 swap` |
| 5 | `mount -t f2fs /dev/sda2 /mnt && mkdir -p /mnt/boot/efi && mount /dev/sda1 /mnt/boot/efi && ls /mnt/boot` | 能看到 `vmlinuz-7.3-x86_64` 与 `vmlinuz-7.2-x86_64` |
| 6 | `manjaro-chroot /mnt`（提示 command not found 就改 `arch-chroot /mnt`） | 提示符进入目标系统根 |
| 7 | 只回启动项、不动包（推荐）：<br>`grub-editenv /boot/grub/grubenv unset next_entry`<br>`grub-editenv /boot/grub/grubenv set saved_entry='gnulinux-7.3.0-rc6-1-MANJARO x64-advanced-/dev/sda2'` | `grub-editenv /boot/grub/grubenv list` 无 `next_entry` |
| 8 | 若怀疑 initramfs 或包损坏：`ls /var/cache/pacman/pkg/ \| grep -E '^(linux73\|nvidia-utils\|lib32-nvidia\|opencl\|nvidia-settings)'`，按列出的**实际文件名** `pacman -U`；然后 `mkinitcpio -P`；最后 `grub-mkconfig -o /boot/grub/grub.cfg`，`exit; umount -R /mnt; reboot` | `mkinitcpio` 每个内核各一行 `Initcpio image generation successful`；`grub.cfg` 里两条 `menuentry` 都在 |

> 回滚优先级：**先只改 grubenv 回旧内核**（旧内核 + 615 模块已在，GPU 仍可用）。不要顺手把 615 退回 610——610 线在 rc6 上本来就是坏的。

### C. 能进系统但没网

| # | 操作 | 成功判据 |
|---|---|---|
| 9 | `Ctrl+Alt+F2` 进终端：`ip -br a`；`nmcli device status` | 至少一个网卡有 `inet`；对应设备 `connected` |
| 10 | `systemctl status NetworkManager --no-pager`；`systemctl list-units --all \| grep -iE 'frp\|tunnel'` | NetworkManager `active`；**记下 frpc 的真实单元名**（760K 上从未确认过） |
| 11 | `systemctl start <单元名>`；`journalctl -u <单元名> -n 40 --no-pager` | 出现 `login to server success` / `start proxy success`，不再有 `doesn't exist` |
| 12 | 若单元起不来：`ip tuntap show; lsmod \| grep tun`；再前台跑一次 `frpc -c /etc/frp/frpc.toml`，把报错原样拍下来 | 能区分是「配置错」「TUN 依赖被拖死」还是「出站被挡」 |

---

## 4. 恢复后要做的 6 件事

1. **确认内核**：`uname -r`。是 `7.2.9-1-MANJARO` 还是 `7.3.0-rc6-1-MANJARO`，后面每一步都以此为前提。
2. **确认 GPU**：`nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv`。期望 `NVIDIA GeForce RTX 3070 Ti, 615.71.09, 8192 MiB`；若失败，先 `lsmod | grep nvidia`、`journalctl -b -p err | tail -30`，**不要**急着重装驱动。
3. **要不要卸 rc 内核**：只有**同时**满足才动——新内核已连续两次重启成功、`nvidia-smi` 正常、`systemctl --failed` 为空。不满足就保留双内核（多占约 140 MB，安全）。
4. **若确定要卸**（先排除当前内核）：
   ```bash
   uname -r                                  # 确认不是 7.3.0-rc6
   pacman -Q | grep -E '^linux7[0-9]'        # 列出所有内核包
   pacman -Rns --print linux73 linux73-headers linux73-nvidia-open   # 先 dry-run
   ```
   判据：dry-run 的清单里**不能出现** `linux72*`、`nvidia-utils`、`linux-firmware`。确认后去掉 `--print` 执行，再 `grub-mkconfig -o /boot/grub/grub.cfg`，核对菜单只剩目标内核。
5. **装交付三件套**：按 §5 的顺序与命令，先停旧服务，再 `flatpak install --user --reinstall`。
6. **验收三条**：
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5080/api/health     # 期望 200
   sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 flatpak --user info org.agentzero.AgentZero | grep -E 'Commit|Date'
   # 期望 Commit: d77499804c13003ed0465dee589f86b7ccaa3a8ee456ce0a3e60cf5fc26576ff
   grep -E 'inference compute|library=cuda' \
     /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/ollama.log | tail -5
   # 期望出现 library=cuda 且 name="NVIDIA GeForce RTX 3070 Ti"
   ```
   `CUDA_VISIBLE_DEVICES=0` 通过 `flatpak override --user --env=CUDA_VISIBLE_DEVICES=0 org.agentzero.AgentZero` 设置后重启应用再查日志（该命令只追加变量，不会清掉已有的 `A0_AUTH_KEY`）。

---

## 5. 交付物与部署命令

| 包 | commit | sha256 | 大小 |
|---|---|---|---|
| `bundles/agent-zero.flatpak` | `d7749980` | `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7` | 60,506,136 B |
| `bundles/agent-zero-cuda.flatpak` | `b0633fcb` | `1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f` | 860,271,248 B |
| `bundles/agent-zero-wps.flatpak` | `790cee09` | `3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772` | 50,210,992 B |

**首选（一条命令）**：从本机运行 `scripts/deploy-760k.sh`。目标不可达时脚本只打印
`target unreachable; nothing changed` 并退出 2，不会 scp、不会停服务、不会安装。

```sh
cd /home/kunweiz/Desktop/a0lite
sh scripts/deploy-760k.sh --target root@127.0.0.1 --port 12022
# 只演练：sh scripts/deploy-760k.sh --dry-run
```

脚本会按固定 sha256 校验三个本地 bundle，把包直接送到
`/home/kunweiz/a0-bundles/`（不是 `/root`），按主包 → Cuda → Wps 顺序安装，
用 `setsid flatpak run` 启动并轮询 health 240 秒；失败时打印回滚命令。

**带 `--with-services` 可一并启用开机自启**（`agent-zero.service` 与
`agent-zero-desktop.service`，安装到 `/etc/systemd/system`），前提是目标机的
`sudo` 可免密或已知密码；`--with-services` 会先停掉手工实例，再由 systemd
接管，并用 `ExecMainPID != 手工 PID` 验证接管成功。本机 `sudo` 需要密码，
所以这条路径没有端到端验证。

**Models 扩展无需重传**：目标机已装 `org.agentzero.AgentZero.Models` 1.0
（5.4 GB，commit `f011ae9b`，含三个模型）；本机也没有重打 `models-repo.tar`。
脚本不碰 Models。

**手工退路（脚本失败时）**：

**0）先停旧实例**（它们占着 5080/11434/14500，不停会挡住新包）：

```sh
systemctl stop agent-zero-desktop agent-zero
ss -ltn | grep -E ':(5080|11434|14500)\b'      # 期望无输出
```

**1）从本机 scp**（不要用 `/tmp`）：

```sh
ssh root@127.0.0.1 -p 12022 'mkdir -p /root/a0-bundles'
scp -P 12022 bundles/{agent-zero,agent-zero-cuda,agent-zero-wps}.flatpak root@127.0.0.1:/root/a0-bundles/
```

**2）复制到 `kunweiz` 可读的位置**（**最容易错的一步**：`/root` 通常是 0700，`sudo -u kunweiz` 穿不过去，直接装会 `Permission denied`）：

```sh
ssh -p 12022 root@127.0.0.1 'install -d -o kunweiz -g kunweiz /home/kunweiz/a0-bundles &&
  cp -a /root/a0-bundles/*.flatpak /home/kunweiz/a0-bundles/ &&
  chown kunweiz:kunweiz /home/kunweiz/a0-bundles/*.flatpak &&
  sha256sum /home/kunweiz/a0-bundles/*.flatpak'
```

**3）按顺序安装**（必须主包 → Cuda → Wps，Cuda 的 base 是主包）：

```sh
for b in agent-zero.flatpak agent-zero-cuda.flatpak agent-zero-wps.flatpak; do
  sudo -u kunweiz env XDG_RUNTIME_DIR=/run/user/1000 \
    flatpak install --user -y --noninteractive --reinstall "/home/kunweiz/a0-bundles/$b" || break
done
```

**4）启动并验收入口**：

```sh
systemctl start agent-zero
systemctl start agent-zero-desktop
sleep 20
curl -sS http://127.0.0.1:5080/api/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:14500/
```

预期：health 200、401（根路径，鉴权生效）、Xpra 200；`flatpak --user info` 的 Commit 为 `d7749980…`。
`A0_AUTH_KEY` 已在 `~/.local/share/flatpak/overrides/org.agentzero.AgentZero`，**不要重写、不要清空**。

注：`scripts/deploy-760k.sh` 按任务要求用 `setsid flatpak run` 启动；
如果目标机继续由 systemd 托管，手工退路用上面的 `systemctl start agent-zero`。

**回连后仍未验证、只能现场确认的清单**：scp 三个 bundle；停旧服务并等待
5080/11434 释放；主包/Cuda/Wps 三次 install；`setsid flatpak run` 启动；
health 200；`--with-services` 的 `systemctl is-enabled`、`is-active`、
`ExecMainPID` 接管、`journalctl -u agent-zero` 与 CUDA `library=cuda` 日志。

---

## 6. 不要做的事

1. **不要 `pacman -Syu`**：系统落后仓库约 6 周、249 个待升级包，全量滚动会把这次恢复变成第二次事故。
2. **不要在确认新内核能起两次之前卸旧内核**：现在唯一能带 GPU 起来的还是 7.3.0-rc6 + 615 模块。
3. **不要 `flatpak uninstall --unused`**：会清掉回滚用的旧 commit（`b15bc387…`）。
4. **不要删 `/root/kernel-migration-20261117/` 与 `/root/a0lite-deploy-backup/`**：前者是迁移日志与 grub/env 原始存档，后者是旧部署的配置与数据备份。
5. 不要跑仓库里的 `scripts/deploy.sh`：它会 `pkill -9 org.agentzero` 并 `setsid flatpak run`，绕过 systemd，与本机 unit 管理方式冲突。
6. 不要删 `~/.var/app/org.agentzero.AgentZero`（1.5 G 用户数据）与 `/home/kunweiz/a0-models-repo`（4.7 G 模型）。

---

## 7. 证据索引

| 需要什么 | 看哪里 |
|---|---|
| 启动项、GRUB 结构、grubenv 存疑点、恢复手册全文 | `kernel-gpu-migration.md` §4.1–§4.3、§8.1–§8.3、§10、§11 |
| 恢复后只读采集清单（12 条命令） | `kernel-gpu-migration.md` §12 |
| 失联起点、frps 未注册、局域网扫描、frp 差异测试 | `760K-connectivity-hunt.md` §5、§7、§9、§10 |
| 机器规格、分区、旧部署布局、root/kunweiz 关系 | `recon-target.md` §1、§3、§6、§8 |
| 备份内容、旧状态快照、重装不丢数据的证据 | `target-prep.md` §1、§3、§9 |
| 交付三件套的 commit/sha256/大小、v13 验证 | `report.md` §2.2、§2.4、§8.2 |
