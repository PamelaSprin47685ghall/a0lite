# v22 最终状态清点

采集：2026-11-18 07:53:37（v20 快照）；版本值与端口于 v22 安装后 10:05 复核。本机 `7940HS`。除 760K 探测外均只读，**未删任何文件**。HEAD 仍为 `058582f`（交付改动全部未 commit）。

## 1. 实例与端口
| 项 | 值 |
|---|---|
| `flatpak ps` | **1 行**：`3510358199 2256296 org.agentzero.AgentZero` |
| 5080 | `LISTEN 127.0.0.1:5080` |
| 5081 / 14500 / 14501 / 9333–9336 | 全部无监听；无 Xvfb / xpra / 多余 run_ui |
| health | `commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-18T01:52:13Z`、`version=058582f-dirty`、`error=null` |
| 已安装 | `Commit: d77499804c13003ed0465dee589f86b7ccaa3a8ee456ce0a3e60cf5fc26576ff`，`Installed: 126.7 MB` |

`commit_time` 修复已生效：显示 HEAD 提交时间，构建时刻单列在 `build_time`。
HEAD `058582f` 与已装 `d7749980` 不对应——前者是源码状态，后者是 ostree 制品指纹，两者本来就不同层（见 §2.6 版本号语义）。**这不是不一致。**

## 2. 三件套核对（全部一致）
| 包 | sha256 | 大小 | 判定 |
|---|---|---|---|
| main | `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7` | 60,506,136 | 与权威值一致 |
| cuda | `1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f` | 860,271,248 | 与权威值一致 |
| wps | `3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772` | 50,210,992 | 与权威值一致 |

mtime：main 09:53:45 → cuda 10:00:27 → wps 10:01:30，符合 build-bundle 顺序。

## 3. 磁盘与可删清单（只报，未删）
- `/home` 111G，89G 已用，**21G 可用（81%）**；`~/a0-local-backup` 2.5G、`~/a0-shots` 1.7G、`~/.var/app/org.agentzero.AgentZero` 1.5G、`/tmp` 1.1G（tmpfs，30G 空闲）。
- 无 Chrome 调试进程、无 soak/harness/sampler；旧 chrome profile 已不存在。
- **已清理**：`build/logs/` 删除 16 个旧日志（保留 r12/r13/final-full-build 共 3 个，172K → 约 26K）；`/tmp/a0perf`、`a0perf2`、`a0-wps2`、`a0-wps3`、两者 `.out`、`a0-760k-dry{2,}`、`a0-760k-final`、`a0-onlyA3`、`/tmp/a0*.mjs` 全部删除；`/tmp` used 1,103,148 → 1,099,788 KB（**释放约 3.3 MiB**）。

## 4. 760K 最后探测（已弃用；本节保留作历史）
```
2026-11-18 07:53:37
Connection timed out during banner exchange / Connection to 127.0.0.1 port 12022 timed out
curl: (52) Empty reply from server   frp5080=000
ip neigh show 192.168.123.92 → 无输出（条目已过期）
2 packets transmitted, 0 received, 100% packet loss
```
自 2026-11-17 23:12 起约 8.7 小时未回连；局域网无 ARP、frp 无注册。

## 5. 交付物清单
- 文档 75 个：`docs/manual-acceptance/a0lite-deploy/*.md`。
- 脚本 5 个全部在位：`deploy-760k.sh`、`test-760k-acceptance.sh`、`test-760k-acceptance-selftest.sh`、`verify-security-fix.sh`、`verify-security-fix-selftest.sh`。
- `760k-rescue-kit/`：`01-diagnose.sh` 2269 B、`02-fix-boot.sh` 3743 B、`03-deploy.sh` 9493 B（已同步 v22 校验值）、`README.md` 3452 B、`make-kit.sh` 1284 B、`a0lite-760k-rescue-kit.tar.gz` 16060 B（v21 重打，sha256 `a7493d24…`；tar 内 `03-deploy.sh` 仍是 v21 值，本轮未重打）。
- `git status --short` 共 **36 条**（22 M、1 D、13 未跟踪）；HEAD `058582f`。

## 交付前必须做
1. **提交（按既定决策不 commit）**：`worktree-changes.md` 已逐条说明 36 项对应哪个 D 号/功能，用户可随时 `git add -A && git commit`（提交前排除 `.herd/`）。
2. **760K 未验收**：C48、C49–C52、C53–C57、CUDA 可见性、真实宿主 Xpra 只能记“未执行/环境不具备”。
3. **已核对**：`report.md` 顶部为 `d7749980` / 60,506,136 B / `97615832…`。
