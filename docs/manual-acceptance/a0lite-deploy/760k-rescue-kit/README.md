# 760K 现场救援包

> **先不要 `pacman -Syu`。** 系统落后仓库约 6 周、249 个待升级包，滚动升级会把这次恢复变成第二次事故。

把 tar 解到一个空目录，再把三个包（`agent-zero.flatpak`、`agent-zero-cuda.flatpak`、`agent-zero-wps.flatpak`）放进同一目录。三个包太大，不在 tar 里。接好显示器 + 键盘；所有命令都在 760K 本机执行，改系统或装包用 `sudo sh <脚本>`，`01-diagnose.sh` 可以直接跑。

## A. 停在 GRUB 菜单

1. 开机自检刚过、logo 消失时连按 `Esc`（有的固件按住 `Shift`）。
   成功：出现 Manjaro GRUB 菜单。
2. ↓ 选 `Advanced options for Manjaro Linux` → `Manjaro Linux (Kernel: 7.3.0-rc6-1-MANJARO x64)` → 回车，等 90 秒。
   成功：内核日志滚完，出现登录提示或桌面。
3. 固定旧内核：`sudo sh 02-fix-boot.sh --to old`
   成功：最后一行是 `OK: next_entry is gone`，且 `saved_entry` 指向 7.3.0-rc6-1。
4. 留下现场证据：`sh 01-diagnose.sh`
   成功：当前目录出现 `760k-diagnose-*.txt`，末尾打印行数。

## B. panic / emergency shell / 连 GRUB 都过不去

1. Manjaro live USB 启动，开终端：`lsblk -f`
   成功：看到 `sda2 f2fs`、`sda1 vfat`、`sda3 swap`。
2. 挂载：`sudo mount -t f2fs /dev/sda2 /mnt && sudo mkdir -p /mnt/boot/efi && sudo mount /dev/sda1 /mnt/boot/efi && ls /mnt/boot`
   成功：看到 `vmlinuz-7.3-x86_64` 和 `vmlinuz-7.2-x86_64`。
3. 不进 chroot 先改引导：`sudo env GRUBENV=/mnt/boot/grub/grubenv sh /<U盘路径>/02-fix-boot.sh --to old`
   成功：输出 `OK: next_entry is gone`，`/mnt/boot/grub/grubenv` 里没有 `next_entry`。
4. 只有还要修包才进 chroot：`sudo manjaro-chroot /mnt`（找不到就改用 `sudo arch-chroot /mnt`）
   成功：提示符进入目标系统的根。

> 仍起不来才动包：按 `760K-handover.md` §3B 第 8 步，只 `pacman -U` 缓存里列出的实际文件名，再 `mkinitcpio -P`、`grub-mkconfig`。

## C. 进了系统但没网

1. 先留证据：`sh 01-diagnose.sh`
   成功：生成 `760k-diagnose-*.txt`；里面的 `ip -br a` 段就是判断依据。
2. 看网卡：`nmcli device status`
   成功：目标网卡是 `connected`；不是就先 `sudo nmcli device connect <网卡名>`。
3. 找 frp 单元：`systemctl list-units --all | grep -iE 'frp|tunnel'`
   成功：记下真实单元名（760K 上从未确认过）。
4. 起隧道：`sudo systemctl start <单元名>`
   成功：状态为 `active`。
5. 看日志：`journalctl -u <单元名> -n 40 --no-pager`
   成功：出现 `login to server success` 和 `start proxy success`，不再有 `doesn't exist`。

## 恢复后装三件套

1. 先演练：`sudo sh 03-deploy.sh --dry-run`
   成功：只打印校验、停服务、安装、启动步骤，系统无改动。
2. 真装：`sudo sh 03-deploy.sh`
   成功：最后打印 `DEPLOY OK`，health 为 `200`。
3. 要开机自启再跑一次（会重装三包）：`sudo sh 03-deploy.sh --with-services`
   成功：`agent-zero` 与 `agent-zero-desktop` 都是 `enabled` / `active`，health 为 `200`。

装完先跑验收三条（health、`flatpak --user info` 的 Commit、`library=cuda` 日志），判据见 `760K-handover.md` §4–§5。回滚用 `b15bc387…` 旧 commit，命令由 `03-deploy.sh` 在失败时打印。不要 `flatpak uninstall --unused`，不要删 `~/.var/app/org.agentzero.AgentZero`。
