# 760K 验收脚本安全审查

对象：`scripts/test-760k-acceptance.sh`（约 1,100 行，未提交）。只读审查 + 小修；未执行任何 `--destructive` 分支，未 reboot，未改 `report.md`/results 格式。本机 Manjaro + systemd 261；用 fake `systemctl` 只验证 C53 的判定与退出码。

## 1. 十个审查项

| # | 结论 | 证据 |
|---|---|---|
| 1 破坏性守卫 | **缺陷 R6/R7 已修**：C48/C54/C55/C56 原先已有门；C44/C47 会在默认“只读”运行中创建桌面会话，已并入 `--destructive`。C50–C52 仍会起瞬时 MCP server（§3） | 16–19、261–270、391–398、1014–1027 |
| 2 reboot 确认 | **缺陷 R8 已修**：只接受 `REBOOT_CONFIRM`（或 `REBOOT-CONFIRM`）的精确值 `REBOOT-CONFIRM`；删掉 `yes`/`1`；另要求 `--only C56`；完整 `--destructive` 不会中途重启 | 19–20、982–1006 |
| 3 路径安全 | **缺陷 R9 已修**：无 `rm -rf`；C48 的 `find -delete` 只在精确 sessions 路径、先备份成功后才执行；OUT_DIR/DATA 有绝对路径、无 `..`/尾斜杠/系统目录检查，OUT_DIR 另有 owner+700+symlink 检查 | 73–108、188–195、703–725、915–922 |
| 4 `set -eu` | **缺陷 R1 已修**：`run_case` 原为 `set +e`，中间命令失败会被后面的 `echo`/`is-active` 吞掉；现在 subshell 内 `set -e`，只捕获最终状态；WPS 的 124 用 `|| wh_rc=$?` 捕获 | 40、349–352、816–834 |
| 5 PASS/FAIL | **缺陷 R2–R5 已修**：C54/C55 健康断言与 `is-active` 合并；C57 加 `grep -q`；C56 boot_id 变化显式 `exit 1`；C46/C49 的末尾 `echo` 不再掩盖失败；C49 bun 检查显式 exit；C53 verify 改看退出码；A3 补 Cuda 扩展断言 | 434、475、504、531、540、573、643–655、800 |
| 6 凭据泄露 | **缺陷 R10 已修**：API key/CSRF 改为 `curl -H @file`（600 临时文件），不再进 argv；URL query、`Set-Cookie`、Xpra `--password` 脱敏；`.cookies`/header 有 EXIT/HUP/INT/TERM 清理；E3/C49 不再落原始 env | 194、577–610、623–641、904–910、920–922 |
| 7 dry-run | **OK**：runtime 的 mkdir/results/read_auth_key 全部在 `DRY_RUN=0` 内；`run_case` 只打印；cleanup 也跳过。最终 444 行（原 389），exit 0，未生成输出目录或 reboot marker | 222–239、329–334、915–954、1034–1049 |
| 8 WPS 30s | **部分**：`timeout --kill-after=5 45` + `flatpak-spawn --watch-bus`；不阻塞、超时后杀 wrapper。没有额外 kill 宿主 WPS 的 trap；见 §3 | 807–838 |
| 9 并发 | **缺陷 R12 已修**：C48 在 `flatpak kill` 后等待并用 `flatpak ps` 确认无旧实例，拒绝起第二个；所有 flatpak/xpra 探测串行 | 704–725、1014–1027 |
| 10 退出码 | **缺陷 R13 已修**：0 全 PASS、1 有 FAIL、3 无 FAIL 但有 SKIP、2 用法/无选中用例；已实测 | 1042–1049、1093–1099 |

## 2. 已修缺陷

| 编号 | 行号 | 问题 | 改法 | 复验 |
|---|---|---|---|---|
| R1 | 349–352 | `run_case` 显式 `set +e`，中间断言失败可被最终命令掩盖 | subshell 内 `set -e`，外层捕获一次退出码 | C53 fake PASS/FAIL 得 0/1；`sh -n` OK |
| R2 | 504、531 | C54/C55 的 health 断言不是最后命令，`is-active` 可单独把用例判 PASS | 合并成一条 `[ ... ] && ... && is-active --quiet` | 逐行审查；无真机破坏性执行 |
| R3 | 573 | C57 `grep ... \| tail` 的状态来自 `tail`，无命中仍 0 | 末尾加 `grep -qE` | 表达式审查 |
| R4 | 540 | C56 post 的 boot_id 变化不是最后命令，未重启也可能 PASS | `[ ... ] \|\| { echo; exit 1; }` | fake marker 同 boot_id exit 1、不同 boot_id exit 0 |
| R5 | 434、475、643–655、800 | C46/C49 末尾 `echo`、C49 bun、C53 verify 可掩盖失败；A3 未断言扩展 | 显式退出/退出码/扩展 grep；bun 明确 exit | fake C53；逐行 |
| R6 | 16–19、261–266 | C44/C47 在默认只读运行中创建桌面会话 | 并入 `is_destructive`；默认 skip | `--only C44` 得 SKIP/3 |
| R7 | 268–270、703–725 | C48 备份失败仍删除；删除失败被吞；可能起第二个实例 | 备份失败即 exit；删除失败即 exit；ps 确认旧实例；C48 要求 admin | `--only C48 --destructive` 非 root 得 SKIP/3 |
| R8 | 982–1006 | reboot 接受 `yes`/`1`，且完整 `--destructive` 会在中途重启 | 精确 `REBOOT-CONFIRM`；`--only C56`；删 alias | 非 root `--only C56 --destructive` 得 SKIP/3 |
| R9 | 43–108、188–195、915–922 | 用户/UID/home 硬编码；路径可注入/为空/系统目录；OUT_DIR 可被用户预置 | 从 passwd/id 派生；字符白名单；`..`/尾斜杠/系统目录；owner+700+symlink | `DATA=/etc`、`OUT_DIR=/tmp/..` 均 exit 2 |
| R10 | 577–610、623–641、904–910 | API key/CSRF 在 curl argv；URL token、Set-Cookie、进程行可能落盘；cookie 无 trap | `-H @file`、脱敏、EXIT trap、C49 只存 command/args | 生成的 C44 block `sh -n`；jq 脱敏样例 |
| R11 | 807–834 | `timeout 45` 可能留孤儿；`set -e` 会把正常 124 当失败提前退出 | `--kill-after=5`；`\|\| wh_rc=$?` 捕获 | `sh -n`；未执行真实 WPS |
| R12 | 704–725、1014–1027 | C48 可能同起两个 flatpak | `flatpak ps` 等待并拒绝第二个 | 逐行 |
| R13 | 1042–1049、1093–1099 | 任何结果都 exit 0；无选中用例生成空 results | 0/1/3/2；空 results → 2 | 实测 0/1/3/2 |

## 3. 仍存在的风险

- **reboot 后必须人工再跑**：C56 第一次只写 marker 并重启；主机回来后必须用同一 `A0_APP_USER`/`A0_HOME` 执行 `--only C56`，否则 marker 或 post-check 数据对不上。
- **WPS 宿主进程**：`--watch-bus` 正常会随 sandbox bus 结束而终止 WPS；若被 SIGKILL 或 watch-bus 失效，宿主 `wps-office-mcp` 可能残留。跑完用 `pgrep -af wps-office-mcp` 检查。
- **C50–C52 未受 `--destructive` 门控**：它们会起瞬时 MCP server；虽无删除，但可能触碰 WPS 状态，建议只读阶段单独跑并观察。
- **路径**：`A0_DATA_DIR`/父目录/既有 OUT_DIR 内容的 symlink 仍在逐项审计之外；自定义数据目录可能指向用户可写的树。`E2`/`E3` 是记录型用例，无阈值断言。
- **其他密钥**：E3 只脱敏 `A0_AUTH_KEY`，C45 只覆盖常见认证头；其他自定义密钥仍可能进日志。
- **C45.body / C48 backup**：前者是 Xpra HTML 页面，后者是 session JSON（可能含 Xpra token）；都在 700 的 OUT_DIR 下且不进 `results.md`，但离开机器前不要整体拷走。

## 4. 760K 首次运行顺序

1. `scripts/test-760k-acceptance.sh --dry-run`：预期 444 行、exit 0、不生成输出目录或 marker。
2. `--only A`：只读；无 NVIDIA 时 A1–A3 FAIL 属环境事实，不是脚本缺陷。
3. 只读组 `--only C53,C57,E1,E2,E3`（有桌面时加 C45,C46）；确认 C53 的 unit/verify 与 journal。
4. 逐项 `--destructive --only C44`、`C47`、`C48`、`C54`、`C55`（root 或免密 sudo）；先备份再让 C48 清 sessions。
5. `REBOOT_CONFIRM=REBOOT-CONFIRM scripts/test-760k-acceptance.sh --destructive --only C56`；主机回来后 `--only C56`。完整 `--destructive` 有意跳过 C56，不要指望它顺手重启。
## 5. 自测结果

`scripts/test-760k-acceptance-selftest.sh`（403 行）用临时 fake bin 跑 10 个场景；`sh -n` 通过，`SELFTEST OK (10/10)`、exit 0。S1 原始输出为 `HTTP=500 elapsed=0s` → C54 FAIL；旧 `set +e` 版会在最后一条 `is-active` 上改判 PASS。

| 场景 | 期望 | 实际 | 通过 |
|---|---|---|---|
| S1 | FAIL | FAIL (HTTP=500 elapsed=0s) | yes |
| S2 | FAIL | FAIL (inactive) | yes |
| S3 | FAIL | FAIL (PID 1234 -> 1234) | yes |
| S4 | FAIL | FAIL (Server: nginx) | yes |
| S5 | FAIL | FAIL (--mmap=no) | yes |
| S6 | FAIL | FAIL (no XVFB_OK) | yes |
| S7 | SKIP | SKIP x3 (no systemctl/find) | yes |
| S8 | SKIP | SKIP x4 (no reboot) | yes |
| S9 | PASS | PASS | yes |
| S10 | PASS | PASS | yes |
10 个场景都可 fake，无 `SKIP (cannot fake)`；S9/S10 是正向对照，防止“永远 FAIL”也过。

## §6 脚手架回归（2026-11-18 07:5x）

- 现象：`verify-security-fix-selftest.sh` 报 `SELFTEST FAIL (0/3)`；V1 为 11/12，check 1 `SKIP installed metadata not readable`。
- 根因：`verify-security-fix.sh` 的 check 1 改成 `flatpak info --show-location` + 读 deployment `metadata` 的 `!~` 负权限（`--show-permissions` 会隐藏它们），selftest fake 仍只实现旧的 `info` 输出。
- 修法：fake `flatpak` 增加 `info --show-location`（返回 `$FAKE_LOCATION`）与 `--show-permissions` 分支；每个场景把 V1/V2 的 8 条 `!~` metadata 或 V3 的无 `!~` metadata 写进该目录。
- 口径漂移防护：selftest 启动时用 `grep -o 'flatpak [a-z-]*'` 提取 verify 用到的子命令（过滤 `not/found/flatpak` 噪声），与 fake `flatpak` 顶层 case 分支比对；再比对 `flatpak info --[a-z-]*` 选项；缺项打印 `SELFTEST FAIL: fake flatpak coverage missing: ...` 并 exit 1。
- 复验：两脚本 `sh -n` 均 0；V1 12/12 exit 0，V2 11/12 + 1 FAIL exit 1，V3 12/12 + 8 条 `unfixed as expected` exit 0；`SELFTEST OK (3/3)`。
