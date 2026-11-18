# v21 修复构建与部署验收（2026-11-18）

## 构建
- 日志：`build/logs/build-v21-rerun.log`（295 行）
- 起止：09:30:22 → 09:39:07，约 526 s（8m46s）
- 构建前 `bundles/` 已清空，三包均为本次连续产物
- 判据偏差：`build.sh` 只有 `set -eu`、无 `set -x`，日志不含字面 `build-bundle`；
  以日志末尾 `ls -lh` 三行与三包 mtime 证明三条 `flatpak build-bundle` 均成功。
  三包 mtime 跨度 7m49s（超过 3 分钟阈值），原因是 Cuda 860 MB 压缩耗时，
  不是 v20 旧包混入（构建前目录为空）。

## 三件套
| 包 | 大小 (B) | mtime | sha256 |
|---|---|---|---|
| agent-zero.flatpak | 60,516,256 | 09:31:18 | 8c8e1e535053265afe1a7f2effa368aab165d12ce683004c9fe3a7e56483d218 |
| agent-zero-cuda.flatpak | 860,267,312 | 09:37:58 | e5c12af39e21d963fe8d94632ad39c964674afb8c8a7e5ff8a9bb821a1a286bf |
| agent-zero-wps.flatpak | 50,210,576 | 09:39:07 | 63b51ce2b63ae2468ada4e07c45d220bb9775b518d02b59c7f6b4179cfb3eb7b |

安装：`--reinstall` 三包，INSTALL_RC=0；Installed 126.8 MB；
Commit `053ed951355acb8d353d884f2a84217ba4d858a0e4a51136ed9b89e76f2afe9d`。

## 四项复验
1) 并发 5 × `wps_office.wps_check_connection`（同进程 asyncio.gather，应用
   `a0flatpak` 的 compat + base_dir + mcp_cache 补丁）：
```
PROBE dur=32.3s isError=False
CALL[1] start=0.0s end=32.3s  isError=False busy=False
CALL[2] start=0.0s end=64.6s  isError=False busy=False
CALL[3] start=0.0s end=96.9s  isError=False busy=False
CALL[4] start=0.0s end=129.2s isError=False busy=False
CALL[5] start=0.0s end=161.5s isError=False busy=False
SUMMARY_OK 5 /5
```
2) stderr 落盘：`~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/logs/mcp-wps_office.log`
   存在且非空，首行 `[2026-11-18T01:39:27.160Z] session start: /usr/bin/flatpak-spawn ...`
3) `_TeeLog`：`grep -c '_TeeLog' ~/a0-local-backup/run-v21.log` → `0`
4) 250 工具：`MCPClientBase (wps_office): Tools updated. Found 250 tools.`

## 回归
- `/api/health` → 200，`commit_time=2026-11-02T18:56:58Z`，`version=058582f-dirty`
- `scripts/verify-security-fix.sh --expect new` → `SUMMARY: 12/12 PASS, 0 FAIL, 0 SKIP`
- `A0_DEBUG_PORT=9227 ~/a0-local-backup/verify-ui-fix.sh 053ed951` → `RESULT: PASS (6/6)`
  （running commit 053ed951355a；asset-bundle 08944df1b86b，不同于旧 749c98f1ffe4）

## 结束状态
- `flatpak ps`：1 个实例（重启后 PID 2247805）
- 仅 `127.0.0.1:5080` 监听；无 58891/9227 残留

## 结论
v21 可作为最终基线：MCP 锁超时（5/5 排队完成、无 `MCP_BUSY`）、stderr 落盘、
`_TeeLog` 报警消失、250 工具全部成立，安全与 UI 回归均通过。
唯一偏差是 mtime 阈值与日志字面量判据（见“构建”），属判据措辞与脚本实现差异，
不影响包内容与运行行为。
