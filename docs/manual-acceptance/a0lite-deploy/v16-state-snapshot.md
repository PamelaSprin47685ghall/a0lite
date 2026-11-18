# v16 安装后状态快照

> **已过期。** 本文件是 v16 `0eda9fe1` 时点的历史记录，保留不改。当前基线是 v20 `21b0e23a`（主包 60,530,648 B / `5f8f1ee1…`，07:43:22；Cuda 860,262,096 B / `e66e8d73…`；Wps 50,210,816 B / `4c451457…`）。最新事实见 `v15-v16-fix-run.md §3` 与 `report.md §2.2/§2.4`。

采集时间：2026-11-18 06:04:53（本机 7940HS）。只读，未删任何文件。

| 项 | 实测 |
|---|---|
| `flatpak ps` | **1 行**：`4309413 2094264 org.agentzero.AgentZero`（合判据） |
| 5080 | `LISTEN 127.0.0.1:5080`，持有者 `python pid=2094295`（上述 bwrap 的子进程） |
| 5081 / 14500 / 14501 / 9333 / 9334 | 均无监听 |
| Xvfb / xpra / 残留 run_ui | 无（`pgrep` 仅命中 2094295 本身） |
| health | `commit_hash=058582f`，`version=058582f-dirty`，`error=null` |
| 已安装 commit | `0eda9fe120c0890704ce73ff236d7f667a939f85673a5e033a1ab486799eca8b`（v16） |
| 主包 | 60,536,280 B，`4d88526b80d2fd739bac9e85036d849a8961d5cf318415c03373240996f82faf`，05:51:56 |
| Cuda | 860,279,952 B，`6dd2ef682dcc9fade0c188406867d9a17919abc2607617916b02d5676a9a82dc`，06:00:35 |
| Wps | 50,211,368 B，`818feb212e0720fca57242c5a5c8aacfe3d5c01fbf5aa67cb622bc939448d241`，06:02:03 |
| 磁盘 | `/home` 111G，88G 已用，**22G 可用（81%）**；`~/a0-local-backup` 2.1G、`~/a0-shots` 1.7G、`~/.var/app/org.agentzero.AgentZero` 1.5G、`/tmp` 1009M（tmpfs） |
| /tmp `a0*` 合计 | 23,604 KB；大项为 5 个 3.6M 的旧测试沙箱，其余 ≤2.3M |
| Chrome 探测进程 | 无（`pgrep chrome.*remote-debugging` 空） |
| `~/a0-soak/` | 存在，28K（05:47 仍在写，按“在用”处理） |
| `~/a0-guard-test/`、`~/a0-browser-probe/`、`/tmp/mcptest`、`/tmp/mt2` | 均不存在 |
| 760K | SSH `Connection timed out`；`frp5080=000`；`ip neigh show 192.168.123.92` **无输出**（条目已过期）→ 仍离线 |

**清理候选（仅列，未删）**：`/tmp/a0dm2.YSVsGZ`、`/tmp/a0f1.tbtnix`、`/tmp/a0final.EHNovk`、`/tmp/a0nodm2.dUMwqo`、`/tmp/a0stage1.ZDWkZl`（各 3.6M，04:05 的一轮测试沙箱，可删）；`/tmp/a0perf` 2.3M、`/tmp/a0perf2` 64K（含 `section7-draft.md`，可能仍是证据，建议保留）；`/tmp/a0-mcp-probe` 4K、`/tmp/a0tok` 8K、`/tmp/a0vcheck.QggWjp` 0（可删）。
**结论**：22G 可用，足以再跑 1–2 次构建（增量构建约 2–4G），不必先清理。

### 清理与 commit_time 判定（2026-11-18 06:1x）

- 已删 8 项：`a0dm2.YSVsGZ`、`a0f1.tbtnix`、`a0final.EHNovk`、`a0nodm2.dUMwqo`、`a0stage1.ZDWkZl`（各 3.6M）、`a0-mcp-probe` 4K、`a0tok` 8K、`a0vcheck.QggWjp` 0；`/tmp` used 1,035,892 → 1,017,776 KB，**释放 18,116 KB ≈ 17.7 MiB**。保留 `a0perf` 2.3M、`a0perf2` 64K、`~/a0-soak` 28K。
- `scripts/build.sh:35` 的 `A0_BUILD_TIME` 由 `date -u +%Y-%m-%dT%H:%M:%SZ` 生成，是**构建时刻**，不是提交时刻。
- `flatpak/a0flatpak/version.py:30` 把它填进 `commit_time`；而上游 `helpers/git.py:394` 的同一字段来自 `state.head.committed_at`（提交时间）；`ui_server.py:353` 又把它注入页面 `gitinfo.commit_time`，页脚 `Version <hash> <time>` 直接展示。
- 因此 v14→v16 的「hash 不变、time 变了 80 分钟」是必然结果：同一份源码重建，构建时刻不同。
- 判定：**真缺陷（低危，元数据语义错位）**。修法：`build.sh` 用 `git -C "$HERE" log -1 --format=%cI` 替换 `date -u`；若确需构建时间，另加 `build_time` 字段，不要复用 `commit_time`。

### commit_time 修复（2026-11-18 06:1x）

- `scripts/build.sh`：新增两行取值 + 一个 `printf` 字段（净 +23/-1）——`BUILD_TIME=$(date -u ...)` 保留构建时刻；`COMMIT_TIME=$(TZ=UTC git -C "$HERE" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd)` 取 HEAD 提交时间；写出 `A0_COMMIT_TIME` 与 `A0_BUILD_TIME` 两个键。
- 降级：`if COMMIT_TIME=$(...) && [ -n "$COMMIT_TIME" ]` 不成立时 `COMMIT_TIME=$BUILD_TIME`，并向 stderr 打 `build: warning: cannot read commit time from <HERE>, falling back to build time`（非 git 目录已实测走此分支）。
- `flatpak/a0flatpak/version.py`：`commit_time` 改读 `A0_COMMIT_TIME`（旧 `.a0-build-info` 只有 `A0_BUILD_TIME` 时回退，保证向后兼容），并新增 `build_time` 键，不再把构建时钟冒充提交时间。
- 校验：`sh -n scripts/build.sh` OK；`python3 -m py_compile flatpak/a0flatpak/version.py` OK。
- 期望：v17 构建后页脚应显示 `Version <hash> 2026-11-02T18:56:58Z`（HEAD `058582f` 的提交时间），而不是构建时刻（v16 为 `2026-11-17T21:50:08Z`）。
