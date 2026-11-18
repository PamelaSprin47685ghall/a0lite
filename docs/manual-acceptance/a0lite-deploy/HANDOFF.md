# a0lite 交付指引（v22）

## 当前状态
v22 已安装：`Commit d77499804c13`，`flatpak ps` 1 实例，`127.0.0.1:5080` 在听，`/api/health` 200（`commit_time=2026-11-02T18:56:58Z`，`build_time=2026-11-18T01:52:13Z`，`version=058582f-dirty`，`error=null`）；AMD Radeon 780M 经 Vulkan 推理（`size_vram` 1.82/7.25 GiB，1.81×）。5081/14500/14501/9333–9336 无监听。

## 三件套
| 包 | sha256 | 大小 |
|---|---|---|
| `bundles/agent-zero.flatpak` | `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7` | 60,506,136 B |
| `bundles/agent-zero-cuda.flatpak` | `1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f` | 860,271,248 B |
| `bundles/agent-zero-wps.flatpak` | `3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772` | 50,210,992 B |

安装顺序固定：主包 → Cuda → Wps（Cuda 的 base 是主包）。

## 回滚
备份在 `~/a0-local-backup/bundles-5631f3ab/`（v14 三件套，commit `5631f3ab`）。回滚：
```sh
for b in agent-zero.flatpak agent-zero-cuda.flatpak agent-zero-wps.flatpak; do
  flatpak install --user -y --noninteractive --reinstall "$HOME/a0-local-backup/bundles-5631f3ab/$b"
done
```
`~/.var/app` 不在安装目录内，重装不影响 1.5 G 用户数据；旧 commit 会保留在 `flatpak/.removed/`，进程退出前仍可回退。

## 重新构建
```sh
A0_SRC=/home/kunweiz/Desktop/agent-zero OUT=./bundles scripts/build.sh
```
约 10–12 分钟（缓存热时），产出三件套；顺序由脚本保证（主包先、扩展后）。构建前先 `git diff scripts/build.sh` 确认 `A0_COMMIT_TIME` 块存在。

## 760K（已弃用，仅存档）
1. `scripts/deploy-760k.sh --with-services`（默认 stage 到 `~/a0-bundles`，先停旧实例）
2. `scripts/test-760k-acceptance.sh --dry-run`
3. `scripts/test-760k-acceptance.sh --only A`（NVIDIA/CUDA）
4. 只读组：C44/C45/C46/C47、C49–C52、E1–E3
5. `scripts/test-760k-acceptance.sh --destructive --only C53,C55`；reboot 用 `--only C56` + `REBOOT_CONFIRM=REBOOT-CONFIRM`

## 760K 若起不来
`760k-rescue-kit/README.md` 三种情形：A 停在 GRUB（选 `7.3.0-rc6`，`grub-editenv unset next_entry`）；B live USB（`mount -t f2fs /dev/sda2 /mnt` → `manjaro-chroot` → 缓存回滚 → `mkinitcpio -P` → `grub-mkconfig`）；C 能进系统但没网（`systemctl status NetworkManager frpc`、`journalctl -u frpc -n 40`、前台 `frpc -c /etc/frp/frpc.toml`）。

## 已知限制
`--talk-name=org.freedesktop.Flatpak`（WPS MCP 依赖，凭据目录已用 `nofilesystem` 遮蔽）；`A0_AUTH_KEY` 默认空，部署侧必须设；V5/V6/V7 为上游文案/模型选择；D59–D62（空消息、低分辨率 OCR、静音 STT、空串嵌入）未修；K06 为 FD 高水位（非泄漏）；J 类（systemd/reboot）因环境不具备未验收；760K 目标机已弃用（2026-11-18），C48/C49–C52/C53–C57 记未执行/环境不具备。

## 不要做的事
不要直接 commit（先看 `worktree-changes.md`，排除 `.herd/`）；不要把 5080 暴露到 `0.0.0.0`；不要在 760K 上 `pacman -Syu`；不要 `flatpak uninstall --unused`（会清掉回滚材料）。
