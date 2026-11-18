# v20 交付前最终 smoke

时间：2026-11-18 08:05–08:07（复跑）。除 760K 探测外均为本机只读；未改代码、未构建、未重启实例。

| # | 项 | 结果 |
|---|---|---|
| 1 | 实例数 | **1**（`flatpak ps` 只有数据行、无表头；题面命令 `tail -n +2 \| wc -l` 得 `0` 是砍掉了唯一一行，`flatpak ps \| wc -l` = 1） |
| 2 | 端口 | `:5080` 计数 **1**；5081/14500/14501/9333–9336 **无监听**（`no extra listeners`） |
| 3 | health | **200**，`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T23:41:59Z`、`version=058582f-dirty`、`error=null` |
| 4 | UI 回归 | **PASS (6/6)**；`PASS a) running commit: 21b0e23abd78 (matches 21b0e23a)`；`PASS e) exceptions=0`；`PASS f) screenshot 1440x817` |
| 5 | 安全验证 | **12/12 PASS, 0 FAIL, 0 SKIP**（`--expect new`；含 `PASS 12 api/health … gitinfo.version=058582f-dirty`） |
| 6 | 安全验证自测 | **SELFTEST OK (3/3)**：V1 12/12、V2 11/12（1 FAIL，符合预期）、V3 12/12（unfixed as expected），exit 0 |
| 7 | 760K 验收脚本自测 | **SELFTEST OK (10/10)** |
| 8 | WPS | **250 工具**：`MCPClientBase (wps_office): Tools updated. Found 250 tools.`；`settings.json` 的 `mcpServers` 含 `wps-office`（`flatpak-spawn --host … bun … dist/index.js`）；**无 58891 监听属正常**——该 MCP 走 stdio，不是 TCP |
| 9 | 三件套 | 三者 sha256 与 v20 权威值一致（见下） |

```
5f8f1ee1c423726c7da1d41215a939d7547602da5c4a401cabfdf57e2c45701d  bundles/agent-zero.flatpak
e66e8d733d31e34481cb7bcde30efb5aa499009f5af5bd98b923dac74e41bc72  bundles/agent-zero-cuda.flatpak
4c4514574c8d8e8e656ac8340813114a0e0b47ca15b86e72a1231600759af613  bundles/agent-zero-wps.flatpak
```

**第 6 项已修复**：check 1 的口径从已废弃的 `flatpak info --show-permissions`（会过滤 `!` 条目）改为直读 `flatpak info --show-location` 的部署 `metadata`；自测桩同步实现 `info --show-location` 并生成临时 `metadata`，另加「口径漂移防护」——verifier 若再改判据而桩未跟进，自测会直接报错。上一轮 `SELFTEST FAIL (0/3)` 的原因即桩与新 check 1 不同步（V1 恒 SKIP 1，得 11/12），现已消除。

**760K**：08:06:04 `Connection timed out`（12022）、`frp5080=000`、`192.168.123.92` ARP `FAILED` → 仍离线，C48/C49–C52/C53–C57 与真实宿主 Xpra 继续记“未执行/环境不具备”。

**总结**：v20 交付前 smoke **9 项全绿**（实例、端口、health、UI 6/6、安全 12/12、安全自测 3/3、760K 脚本自测 10/10、WPS 250 工具、三件套指纹）。760K 仍离线，目标机相关用例继续记“未执行/环境不具备”，不影响本机交付。
