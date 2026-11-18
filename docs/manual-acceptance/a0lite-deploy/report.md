# a0lite 实机部署与手工验收报告

- 报告时间：2026-11-18 03:14 CST（v13 定版）；04:12 追加 headless 修复 `5631f3ab75d7`；04:44 追加 V1–V4 修复 `ab3d8e6150f7`；05:34–06:29 连做 v15–v18 四轮；07:14–07:51 再构建 v19/v20；09:30–09:39 构建 v21；09:52–10:01 构建 v22（AMD Vulkan）并定版，v22 为最终交付基线
- 验收对象：`org.agentzero.AgentZero`（Flatpak，user 安装，branch `master`）
- 最终 commit：`d77499804c13`（v21 为 `053ed951`，v20 为 `21b0e23a`，v18 为 `be957363ef7e`，v13 为 `4d0ccd2ceeb4`；完整值见 §2.2）
- 最终 bundle：`bundles/agent-zero.flatpak`，60,506,136 B，sha256 `97615832fa8e…`（v21 包 60,516,256 B / `8c8e1e53…`）
- 用例基数：`test-matrix.md` 的 61 条（C01–C61）
- 判定口径：单类 PASS 阈值 70；环境不具备单列，不计通过也不计失败

## 1. 结论摘要

**结论：v22 交付包可部署——已装入并重启到 `d7749980`，health 200（四键 build-info）、`verify-security-fix.sh` 12/12、WPS 250 工具、`flatpak ps` 1 个实例；本机 AMD Radeon 780M 经 Vulkan 参与推理，`size_vram` 1.82/7.25 GiB，tps 32.27 → 58.36（1.81×）。验收口径为 A–I、K 通过，H 有条件通过，J 环境不具备。台账 D01–D63 共 63 行：58 条已修（其中 D56/D57/D58/D63 在 v19/v20 实测通过），1 条为非缺陷（D19，已排除），4 条未修（D59–D62）；另有两项无 D 号的已知限制（`--talk-name`、`A0_AUTH_KEY`）。**

最强三条证据：① v22 重新构建三件套并装入重启到 `d7749980`：health 200（`build_time=2026-11-18T01:52:13Z`）、`verify-security-fix.sh` 12/12（0 FAIL 0 SKIP）、`verify-ui-fix.sh` 6/6、WPS 250 工具仍注册、desktop `available:true`、`flatpak ps` 1 个实例；AMD Radeon 780M 走 Vulkan（`type=iGPU`、`size_vram` 1.82/7.25 GiB、tps 32.27 → 58.36，1.81×）；MCP 锁 600 s 下并发 5 个 `check_connection` 5/5 全返回，stderr 落盘实测成立。D56–D58 与 D63 四项端点复验在 v20 通过，v22 为同补丁集加 iGPU 启动开关，端点未重测；v13 做过卸载后的空安装演练（14 s，health 200、verify 6/6），卸载后 `~/.var/app` 仍为 1.4G；② TTS WAV 头 `wave` 与 `ffprobe` 完全一致（v12 2.88 s；v10 2.72/12.16 s），坏索引同步改哈希后生成 `*.incompatible-20261118-015734` 并恢复到 `ntotal=6`；③ 聊天连续 10 条 153.4 s 无卡死、中断后 2.27 s 恢复、并发 3 条全部 200。

最大缺口：① 760K 目标机已弃用（2026-11-18，换内核后 10.5 小时未回连、无带外恢复手段），J 类与 CUDA 不再计划验收，H 的 C48 记未执行；本机改为 AMD Vulkan 路径，headless 技术路径已在本机隔离实例通过（C44–C47）；② 宿主无 WPS Office，WPS 文档操作不可用（MCP 启动/注册/250 工具已通过）。

## 2. 环境与部署事实

### 2.1 部署机

| 项 | 实测值 | 证据 |
|---|---|---|
| 主机 | `7940HS` / `kunweiz` / Manjaro rolling / XFCE / X11 `:0.0` | `local-host-prep.md §1` |
| CPU / 内存 | 16 逻辑 CPU（`nproc=16`）；`MemTotal 63496 MiB`，验收时 available 47921 MiB | `local-host-prep.md §1`、`probe-models.md §0.3` |
| GPU | AMD Radeon 780M 集显；**无 NVIDIA** | `local-host-prep.md §4` |
| 磁盘 | `/home` 111 G，已用 81 G，可用 29–30 G（74%） | `probe-stability.md §6.2`、`probe-i-j-k.md §K.6` |
| 显示 | `DISPLAY=:0.0`，`/tmp/.X11-unix/X0` 存在 | `probe-i-j-k.md §J.1` |
| 权限 | 有 `flatpak` user 权限；`sudo` 需密码，本会话不可用 | `probe-i-j-k.md §4` |

### 2.2 最终安装

```console
$ flatpak --user info org.agentzero.AgentZero
ID: org.agentzero.AgentZero
Ref: app/org.agentzero.AgentZero/x86_64/master
Branch: master
Installation: user
Installed Size: 126.7 MB
Runtime: org.freedesktop.Platform/x86_64/25.08
Commit: d77499804c13003ed0465dee589f86b7ccaa3a8ee456ce0a3e60cf5fc26576ff
Date: 2026-11-18 01:52:27 +0000
```

- v13 安装包：59,937,144 B，sha256 `02d857bcf715364a2dd6983a3b69ce626c07ab59682032877b1d56117b1d4238`（`local-v5-regression.md:v13`）。
- 2026-11-18 04:12 重新构建并安装 headless 修复包：60,029,120 B，sha256 `cf2896f23b9d8e55b29a5f02b3e5c3d5b27a5a71f60035ee90424eb00bc25865`，commit `5631f3ab75d764196e50d849e7d6a55371196f81f3c805be4b571f2c0371ec76`，Installed Size 125.1 MB；真实实例仍是 `4d0ccd2c` 进程，重启后使用新包。
- 2026-11-18 04:31–04:42 一次构建三件套（623 s），04:44 安装并重启到 V1–V4 修复包：主包 59,920,792 B，sha256 `e9fc289aef0b0d50cb3a22fb672b4ec3bb5f4aea173e51513993c50b6be40f73`，commit `ab3d8e6150f78872c3221c0304477d5adb4746c1be92f0a0b98f78220bf1ac7d`；Cuda 859,752,760 B / `39c3f403f992…`，Wps 50,210,888 B / `1971d99f7c16…`。health 200 用时 5 s。
- 2026-11-18 05:34–06:29 构建 v15–v18 并定版（四轮 744/715/628/648 s）：v18 主包 60,318,144 B，sha256 `cad5083175319481b8c104e0bc9062675dcc7aeb4f93f1de4521a6f2f4f8a8be`，commit `be957363ef7eeccfe7a440e1381bfeb98e679e245101f43d82a8406c41ce4c5a`；Cuda 860,274,832 B / `5a1b5c41da3f…`，Wps 50,210,360 B / `e84bbed03b97…`。已安装并重启到该 commit；health 四键为 `commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T22:18:48Z`（`v15-v16-fix-run.md §4`）。
- 2026-11-18 07:14–07:51 构建 v19/v20 并定版：v20 主包 60,530,648 B，sha256 `5f8f1ee1c423726c7da1d41215a939d7547602da5c4a401cabfdf57e2c45701d`，commit `21b0e23abd7821ee2e9a6d36e3d7af98e23e33cea31e6a68f9126558762fb63a`；Cuda 860,262,096 B / `e66e8d733d31…`，Wps 50,210,816 B / `4c4514574c8d…`。已安装；health 四键为 `commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T23:41:59Z`（实测）。
- 2026-11-18 09:30–09:39 构建 v21 并定版（526 s）：主包 60,516,256 B，sha256 `8c8e1e535053265afe1a7f2effa368aab165d12ce683004c9fe3a7e56483d218`，commit `053ed951355acb8d353d884f2a84217ba4d858a0e4a51136ed9b89e76f2afe9d`；Cuda 860,267,312 B / `e5c12af39e21…`，Wps 50,210,576 B / `63b51ce2b63a…`。已安装并重启；Installed Size 126.8 MB，health 四键为 `commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-18T01:30:22Z`、`version=058582f-dirty`（实测；`v21-fix-run.md`）。
- 2026-11-18 09:52–10:01 构建 v22（AMD Vulkan，557 s）：主包 60,506,136 B，sha256 `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7`，commit `d77499804c13003ed0465dee589f86b7ccaa3a8ee456ce0a3e60cf5fc26576ff`；Cuda 860,271,248 B / `1a5196a4d3e0…`（commit `b0633fcb79d3`），Wps 50,210,992 B / `3ddbd3504f8b…`（commit `790cee09ba87`）。已安装并重启；Installed Size 126.7 MB，health 四键为 `commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-18T01:52:13Z`、`version=058582f-dirty`；Vulkan 生效，`size_vram` 1.82/7.25 GiB（§13，`v22-vulkan-fix.md`）。
- 安装命令：`flatpak install --user -y --noninteractive --reinstall bundles/agent-zero.flatpak`，`INSTALL_RC=0`；v13 另做卸载→安装→启动演练，总耗时 14s（`local-v5-regression.md:v13`）。
- health（v22）：`HTTP 200`，`gitinfo.commit_hash=058582f`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-18T01:52:13Z`、`version=058582f-dirty`、`error=null`。v13 的 `gitinfo:null` 已由 D38 修复；v16 的 `commit_time` 错位已由四键 build-info 修正。
- 当前 override：`flatpak override --user --show org.agentzero.AgentZero` **输出为空**（03:14 复核）。A 类补测用的临时 key 已清理。
- 当前进程：`flatpak ps` 只有 1 条 `org.agentzero.AgentZero`；5080 与 11434 在听；**14500 当前未监听**，桌面 Xpra 已停止。
- 当前 `usr/settings.json` 存在（2,483 B），WPS MCP 配置保留；`connected=true`、`tool_count=250` 来自最终补测（v10 实例），v13 安装后配置未丢（`local-v5-regression.md:最终补测 §5`）。

### 2.3 Ollama 与模型

```console
$ curl -s http://127.0.0.1:11434/api/tags | jq -r '.models[].name'
xiaomi-ocr:latest
lfm3-omni:2b-q4_K_M
qwen3-embedding:4b-q4_K_M
```

- `OLLAMA_MAX_LOADED_MODELS=1`、`OLLAMA_KEEP_ALIVE=10m`、`OLLAMA_HOST=127.0.0.1:11434`（`local-first-boot.md §4.4`）。
- `qwen3-embedding` 的向量维度 2560；`lfm3-omni` 的 `size_vram=0`，纯 CPU 推理（`probe-models.md §0.3/§D1`）。
- 聊天模型 `mistral/deepseek-v4-1-flash-1017` 经本机 zproxy `127.0.0.1:18080` 提供；provider `kw92` 写入 `conf/model_providers.yaml`，预设 `Default` 指向它（`probe-chat.md §1.1/§1.2`）。

### 2.4 数据目录与构建产物

| 项 | 实测值 | 证据 |
|---|---|---|
| `$DATA` | 1.4 G | 03:14/演练后 `du -sh`；与 `probe-i-j-k.md §K.3` 一致 |
| `venv` | 847 MB | `probe-i-j-k.md §K.3`（v8 实测） |
| `tmp/playwright/chromium-1228` | 379 MB | `probe-i-j-k.md §K.3`；v13 未删 |
| `ollama.log` | 约 1.5 MB（1,517,335 B，03:15） | 03:15 `ls -l`；重装后 1,517,249 B |
| `usr/memory/default` | 5 个文件：`embedding.json` 89、`index.faiss` 61,626、`index.faiss.sha256` 64、`index.pkl` 7,126、`knowledge_import.json` 1,698 | 03:14 `ls -l` |
| `usr/settings.json` | 2,483 B，含 WPS MCP 配置 | 03:14 `ls`、`jq` |
| WPS 扩展 | `org.agentzero.AgentZero.Wps` 1.0 已安装 | 03:14 `flatpak list` |

构建产物（最终交付三件套，v22 同源）：

| 包 | commit（短） | sha256 | 大小 | mtime |
|---|---|---|---|---|
| 主包 `agent-zero.flatpak` | `d77499804c13` | `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7` | 60,506,136 B | 09:53:45 |
| Cuda `agent-zero-cuda.flatpak` | `b0633fcb79d3` | `1a5196a4d3e025fb132e8976c891ba603c31abb171e28ed4162bbd582a499f5f` | 860,271,248 B | 10:00:27 |
| Wps `agent-zero-wps.flatpak` | `790cee09ba87` | `3ddbd3504f8b72aad84c1fa8f74830835722a5897253dd59125bc9bcdb768772` | 50,210,992 B | 10:01:30 |

三件套同源：同一工作树、同一批模块缓存，一轮构建（v22）打出。部署顺序必须是 **主包 → Cuda → Wps**。三件均已安装到上表 commit：`flatpak --user info` 对主包、`runtime/org.agentzero.AgentZero.Cuda/x86_64/12`、`app/org.agentzero.AgentZero.Wps/x86_64/1.0` 分别报 `d7749980` / `b0633fcb` / `790cee09`。

### 2.5 目标机 760K（已弃用）

- 连接方式：`ssh -p 12022 root@127.0.0.1`；4 核 Athlon、RTX 3070 Ti、19 GiB 内存（`recon-target.md §0/§1`）。
- 换内核后失联：`kernel-gpu-migration.md §5` 记录首次重启后未回连；`760K-connectivity-hunt.md §9` 记录失联起点 `23:12:16`，frp 侧未重新注册。
- 截至 2026-11-18 09:45:48 仍未回连（自 2026-11-17 23:12 起约 10.5 小时），当日确认放弃：无带外恢复手段，目标机按死亡处理。所有只能在 760K 做的用例保持“未执行/环境不具备”，历史证据不升级为通过；交付目标改为本机 AMD Vulkan。

### 2.6 交付验证（v14 → v22）

- **v21 安装与复验（09:30–09:39）**：三件套重新构建（526 s）并依次装入，重启到 `053ed951`；health 200（`build_time=2026-11-18T01:30:22Z`）；`verify-security-fix.sh --expect new` **12/12**、`verify-ui-fix.sh 053ed951` **6/6**；WPS 250 工具仍注册；MCP 锁 600 s 下并发 5 个 `check_connection` **5/5 全返回**（32.3/64.6/96.9/129.2/161.5 s），无 `MCP_BUSY`；`usr/logs/mcp-wps_office.log` 存在且首行 `[2026-11-18T01:39:27.160Z] session start: /usr/bin/flatpak-spawn …`；`_TeeLog` AttributeError 计数 **0**。原始输出见 `v21-fix-run.md`。
- **v20 安装与复验（07:43–07:52）**：三件套依次装入并重启到 `21b0e23a`；health 200 且四键齐全（`build_time=2026-11-17T23:41:59Z`）；WPS MCP `Tools updated. Found 250 tools.`；desktop session `ok:true`/`available:true`；`flatpak ps` 1 个实例。端点复验：TTS 超长 413 `SPEECH_INPUT_TOO_LONG`、STT 中文 3/3 汉字、OCR 5 页尾注含 `A0_OCR_MAX_PAGES=4`、截断 PDF 0.095 s 抛 `damaged page tree`（见 §3.1 与 D56–D58/D63）。
- **v19 复验（07:16–07:36）**：`a9aa6ebf` 上完成 12 页视觉验收（`visual-audit-v19.md`、`visual-final.md`）与 D56–D58 端点复验；v20 为同补丁集的重建定版。

- **v18 安装与复验（06:20–06:29）**：三件套依次装入并重启到 `be957363`；health 200 且 `gitinfo` 四键齐全；`verify-security-fix.sh --expect new` **12/12**（0 FAIL 0 SKIP）；WPS `connected:true`/250 工具；desktop `{action:"session"}` 200、`available:true`、`display:":0"`；`flatpak ps` 1 个实例。原始输出见 `v15-v16-fix-run.md §4`。
- **v14 安装与复验（04:44）**：`flatpak install --user -y --noninteractive --reinstall` 装入 `ab3d8e61` 并重启；health 200（5 s）、`verify-ui-fix.sh` **6/6**、`flatpak ps` **1 个实例**、5080 在听、**5081/14500 未监听**。V1–V4 四条复验的原始输出见 `v14-fix-run.md`。
- **空安装演练（v13，历史对照）**：卸载主包（保留扩展）→ `~/.var/app/org.agentzero.AgentZero` 仍为 1.4G → 重装 → health 200 → verify 6/6；卸载→安装→启动总耗时 **14 秒**。v14 沿同一安装路径升级，未重做卸载→安装。
- **数据保留四项**：`conf/model_providers.yaml` 的 kw92 provider 1 条；`usr/memory/default` 5 个文件（v14 安装后 `usr/memory` mtime 仍为 01:38:53，未被重写）；Ollama 3 个模型（xiaomi-ocr、lfm3-omni、qwen3-embedding）；`ollama.log` 约 1.5 MB（重装后 1,517,249 B）。
- **v22 安装与复验（09:52–10:01）**：三件套重新构建（557 s，`~/a0-local-backup/build-v22-0952.log`）并依次装入，重启到 `d7749980`；health 200（`build_time=2026-11-18T01:52:13Z`）；`verify-security-fix.sh --expect new` **12/12**；AMD Radeon 780M 经 Vulkan 推理（`library=Vulkan`、`type=iGPU`、`size_vram` 1.82/7.25 GiB、tps 32.27 → 58.36 = **1.81×**）；WPS 250 工具仍注册；MCP 锁 600 s 行为不变。原始输出见 `v22-vulkan-fix.md`、`vulkan-recon.md`。

- **镜像内容断言**：`manual-acceptance` 计数 **0**；`docs/setup/host-ollama.md` 计数 **1**。
- **与 v13 的差异**：v13 相对 v12 的代码路径逐字节一致，镜像差异仅 D24（排除 `docs/manual-acceptance/` 28 份文档）加两处非代码项（`wps-office-mcp-deps.tar.gz` 全量重建、`docs/setup/host-ollama.md` 并发更新）；v14 在此基础上新增 D38–D41 四处修复——`version.py` 从 `.a0-build-info` 回答版本（D38）、`agent-zero.sh` 补齐顶层目录 mtime（D39）、`desktop.py` 转发 resize 参数（D40）、`patches/flatpak-ui.patch` 加移动端 media query（D41）。

- **版本号语义（v21 四键）**：`.a0-build-info` 现有 `A0_BUILD_VERSION=058582f-dirty`、`A0_BUILD_COMMIT=058582f`、`A0_COMMIT_TIME=2026-11-02T18:56:58Z`（源码 HEAD 的提交时间）、`A0_BUILD_TIME=2026-11-18T01:30:22Z`（v21 构建时刻）。页脚显示 `Version 058582f-dirty 2026-11-02T18:56:58Z`，第二个字段是真提交时间；v16 及以前该字段误填构建时钟（v16 快照为 `2026-11-17T21:50:08Z`），v17 已纠正并另立 `build_time`。
- **包 commit 语义**：`flatpak --user info org.agentzero.AgentZero` 的 `Commit: 053ed951355a…` 是**制品指纹**，即 ostree commit，只在构建时生成。
- **不能互相对照**：页脚只能显示源码状态（构建时还不知道 ostree commit）；两者不在同一层，`058582f` 与 `053ed951` 本来就不应相等。

## 3. 验收判定表（A–K）

计数以 `test-matrix.md` 的 61 条为基数，状态按 v13 交付验证、v12/v11 实机结果、`probe-*.md` 与 `local-v5-regression.md` 校正。证据不足一栏为 0；`未执行` 仅指前置不满足或未跑，不等于失败。

| 类别 | 用例数 | 通过 | 不通过 | 证据不足 | 环境不具备 | 未执行 | 判定 | 主证据路径 |
|---|---:|---:|---:|---:|---:|---:|---|---|
| A 安装与启动 | 7 | 7 | 0 | 0 | 0 | 0 | 通过 | `local-first-boot.md §2/§3`；`local-v5-regression.md:v13`；`最终补测 §1` |
| B Web UI 渲染 | 6 | 6 | 0 | 0 | 0 | 0 | 通过 | `local-v5-regression.md:v12`；`verify-ui-fix-settings.png`；本次 curl C09/C12/C13 |
| C 聊天 | 9 | 9 | 0 | 0 | 0 | 0 | 通过 | `probe-chat.md §2–§5`；`probe-stability.md §0`；C22 重测 |
| D 嵌入与记忆 | 5 | 5 | 0 | 0 | 0 | 0 | 通过 | `probe-models.md §1`；`local-v5-regression.md:收尾状态 §1` |
| E 语音 | 5 | 5 | 0 | 0 | 0 | 0 | 通过 | `local-v5-regression.md:v12`；`tts-v12.wav` |
| F OCR 与文档解析 | 7 | 7 | 0 | 0 | 0 | 0 | 通过 | `probe-pdf.md`；`local-v5-regression.md:v11 §2` |
| G 浏览器工具 | 4 | 4 | 0 | 0 | 0 | 0 | 通过（降级可见） | `local-v5-regression.md:v12`；`probe-browser.md §10` |
| H 桌面/Xpra | 5 | 4 | 0 | 0 | 0 | 1 | 有条件通过 | `local-v5-regression.md:v12`；`91-desktop-v12.png`；`headless-desktop-2026-11-17T20-15-44-970Z.png` |
| I WPS MCP | 4 | 4 | 0 | 0 | 0 | 0 | 通过（有保留） | `local-v5-regression.md:最终补测 §3/§5` |
| J systemd 与重启 | 5 | 0 | 0 | 0 | 5 | 0 | 环境不具备 | `probe-i-j-k.md §2` |
| K 资源与清理 | 4 | 4 | 0 | 0 | 0 | 0 | 通过 | `probe-stability.md §6`；`probe-i-j-k.md §3` |
| **合计** | **61** | **55** | **0** | **0** | **5** | **1** | — | — |

计数说明（按 CASE 唯一归属，避免重复计）：

- A–I 通过 51 条，加 K 的 4 条 = **55 条通过**；不通过 0，证据不足 0。
- 环境不具备 5 条：J 的 C53–C57 全部 5 条；I 不再记环境项。
- 未执行 1 条：H 的 C48（清空 sessions 后的服务重启）。
- J 的 5 条已整体记“环境不具备”，**不再**把其中 4 条另记“未执行”；否则会把 J 的 4 条重复计入，总数超过 61。按本表去重后为 **55 + 5 + 1 = 61**。
- 没有不通过项；C52 记“通过（有保留）”：无 WPS 时 `wps_list_cache` 3 ms 返回结构化成功、`wps_check_connection` 30 s 返回可读 `connected:false`、文档工具超时返回可读 `isError:true`，工具没有崩溃、没有挂死超过 90 s。`isError` 语义不一致是上游缺陷，写入 §7.3 备注，不影响本条判定。

### 3.1 v18 新增用例结果（C62–C77）

本节是**独立增量**，不参与上表 61 条的计数与 85.4 的平均分；C01–C61 的判定保持原样。用例定义见 `test-matrix.md` L 组。

| CASE | 测点 | 结果 | 缺陷 | 证据 |
|---|---|---|---|---|
| C62 | S01 八条 `nofilesystem` 遮蔽生效 | **v20 复测通过** | — | `security-retest-v20.md`：metadata 8 条 `!~`；沙盒内 8 目录 `ls -A` 全 0（§11） |
| C63 | S02 `~/.ssh` 私钥不可读 | **v20 复测通过** | — | 同上：`test -r ~/.ssh/id_ed25519` → BLOCKED |
| C64 | S03 八个敏感目录内容为空 | **v20 复测通过** | — | 同上：8/8 计数为 0 |
| C65 | S04 文件 API 拒绝凭证路径（403 + marker） | **v20 复测通过** | — | `security-retest-v20.md §2`：list/download/delete `~/.ssh` 三入口均 403 `SENSITIVE_PATH_BLOCKED`，无 `PRIVATE KEY` |
| C66 | S05 符号链接穿越被拒并清理 | **v20 复测通过** | — | `security-retest-v20.md §3`：`a0v-link -> ~/.ssh` 三入口均 403 `SENSITIVE_PATH_BLOCKED`；链接已删，`~/.ssh` 未变 |
| C67 | S06 正常路径回归（`/a0`、`~/Documents`、上传） | **v20 复测通过** | — | `security-retest-v20.md §2` 对照组：`/a0` 读写 200、`~/Documents` 上传 200；`edge-files-retest-v20.md` 的 `/a0` 200 同向 |
| C68 | E06 TTS 连续 3 次（每次 reload） | **v20 复测通过** | D43 | `edge-retest-v20.md`：3/3 200 且 `audio` 非空，无 `spacy` 错误 |
| C69 | E07 STT 连续 3 次（每次 reload） | **v20 复测通过** | D43 | 同上：3/3 `success:true`，中文出汉字 |
| C70 | E08 5,500 字在 HTTP 层撞上限 | **v20 复测通过**（413，0.018 s） | D63（原 M2） | 同上：413 `SPEECH_INPUT_TOO_LONG`；v14 为 `success:false` |
| C71 | E09 1 s 静音不产生幻觉文本 | 失败 | D61（原 M6） | `edge-media.md §2 B7`：返回 `Oh,` 且 `success:true` |
| C72 | E10 中文 TTS→STT 的语言标注 | **v20 复测通过（准确率 2/3）** | D58（原 M7） | `edge-retest-v20.md`：中文 3/3 出汉字、2/3 字面正确，英文正确，`language=""` |
| C73 | F08 5 页扫描件走默认配置 | **v20 复测通过** | D57（原 M3） | 尾注 `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).`；v14 只报 timeout |
| C74 | F09 截断 50% PDF 应报可读错误 | **v20 复测通过**（0.063 s） | D56（原 M4） | `ValueError: PDF could not be read: damaged page tree…`，无重复前缀；v14 为 `ok=true` 白跑 45 s |
| C75 | F10 100×50 低分辨率图应拒识 | 失败 | D60（原 M5） | `edge-media.md §2 C13`：返回 76 字符无关数学题，无标注 |
| C76 | D06 空字符串不应静默编码 | 失败 | D62（原 M8） | `edge-media.md §2 D20`：2560 维非零单位向量，无错误 |
| C77 | K05 空闲 10 分钟 RSS/fd | **v18 通过**（RSS +3.4% ≤ 20%） | K06（观察项） | `soak-v18.md §4`：RSS 583,896/564,792 = +3.4%；FD +61 另记 K06（`fd-leak-root-cause.md`） |

**小结：新增 16 条——13 通过 / 3 失败 / 0 待复验。** 通过的 13 条是 C62–C70、C72–C74、C77（安全 6 + 语音/OCR 6 + 稳定性 1）；失败的 3 条是 C71（D61）、C75（D60）、C76（D62），三项在 v18–v20 都没有对应修复。C77 按 RSS 判过（+3.4% ≤ 20%），FD +61 未达 ≤30 阈值但根因确认是「请求密集时的高水位 + 回收滞后」而非泄漏（`fd-leak-root-cause.md`），另记 K06 观察项，不撤 C77。

版本口径：C70–C76 的**历史失败**都记在 v14 实例（`edge-media.md`，05:00–05:15），C72 另在 v18 端点复现（`stt-pinyin-root-cause.md`）；改判依据是 v19/v20 的端点复验（`edge-retest-v20.md`、`security-retest-v20.md`、`edge-files-retest-v20.md`，汇总见 §11）——C70（D63）413、C72（D58）中文 3/3 汉字、C73（D57）尾注写明 `A0_OCR_MAX_PAGES=4`、C74（D56）0.063 s 抛 `damaged page tree`。C71（D61）、C75（D60）、C76（D62）在 v18–v20 均无对应修复，保持失败。C77 按 RSS 判过（+3.4%），FD 项转入 K06 观察，不再作为 C77 的待复验理由。按本条口径重算，16 条最终为 **13 通过 / 3 失败 / 0 待复验**。

## 4. 逐类详述

### A. 安装与启动（C01–C07）

**验了什么**：bundle 安装、commit、health、根路径鉴权、`?key=` cookie、免鉴权白名单、WebSocket 鉴权。

**怎么验**：`flatpak install --user -y --reinstall`；`flatpak info`；临时 `A0_AUTH_KEY=tmpprobe1` 重启；`curl` 覆盖 401/200/错 key/`?key`/cookie/health/manifest；WebSocket 握手；两张浏览器截图。

**结果**：

```console
INSTALL_RC=0
Commit: 53ae0c0dc2...
Installed Size: 125.2 MB
HTTP 200 {"gitinfo": null, "error": ".../data/agent-zero"}

GET /            无 key        -> 401 unauthorized, WWW-Authenticate: Bearer
GET /            Bearer key   -> 200
GET /            X-API-Key    -> 200
GET /            wrong key    -> 401
GET /?key=...                  -> 200 + Set-Cookie: a0key=...; HttpOnly; SameSite=Lax
GET /            cookie       -> 200
GET /api/health  无 key        -> 200 (exempt)
GET /js/manifest.json 无 key   -> 200 (exempt)
WebSocket 无 key               -> 403
WebSocket 带 key               -> 101 Switching Protocols
```

浏览器：`a1-auth-query-key.png` 进入 Agent Zero UI；`a2-auth-no-key.png` 为纯文本 `unauthorized` 页面。

**判定**：C01–C07 全部通过。唯一保留是 `?key` 的 query 清洗没有运行时可观测证据（`auth.py` 代码路径已确认，Uvicorn access log 不记录 query），不影响鉴权结果。**类别：通过**。

**未覆盖**：query 清洗的下游可观测性；过期 cookie。**证据路径**：`local-v5-regression.md:最终补测 §1`、`a1-auth-query-key.png`、`a2-auth-no-key.png`。

### B. Web UI 渲染（C08–C13）

**验了什么**：首页 HTML、关键静态资源、设置页片段、聊天页 token、PWA manifest、缺失资源 404。

**怎么验**：`verify-ui-fix.sh`（CDP）；`curl` 静态资源与 manifest；`curl /plugins/_model_config/webui/main.html`；带 `Origin` 取 CSRF。

**结果**：

```text
verify-ui-fix: PASS 6/6
  c) runtime webui == bundle webui (0 differences)
  e) channels=1, teleports=1, settings pane visible, exceptions=0
PASS: f) screenshot: verify-ui-fix-settings.png (1440x817 mean=0.0829967 sd=0.09764)
RESULT: PASS (6/6)
```

```console
/index.css 200 text/css 32919
/js/initFw.js 200 text/javascript 5412
/public/icon.svg 200 image/svg+xml 1426
/js/manifest.json: name=Agent Zero start_url=/ icons=2 display=standalone
/js/does-not-exist-probe.js -> 404
/plugins/_model_config/webui/main.html -> 200 7959, model|preset 命中 70
/api/csrf_token (Origin) -> 200, token 非空, runtime_id=6492fc278b77d241
```

**判定**：C08–C13 全部通过。截图 `verify-ui-fix-settings.png` 可判读 Settings 主体。**类别：通过**。

**未覆盖**：真浏览器交互式逐页点击（C13 已用 curl 验证 404）；旧 Chrome profile 缓存会单独复现空白（见 §7）。**证据路径**：`local-v5-regression.md:v12`、`verify-ui-fix-settings.png`、本次 03:14 curl。

### C. 聊天（C14–C22）

**验了什么**：zproxy 端点、`/api/api_message`、多轮上下文、max_tokens、错误模型、空消息、缺 API key、异步路径、超长消息、稳定性。

**怎么验**：zproxy 直连；`S-CHAT-ASYNC.sh`；同 context 三条消息；坏模型改 `presets.yaml` 后请求；无 `X-API-Key` 请求；`probe-stability.md` 的 10 条连续、80k 字符、并发 3 条、中断恢复。

**结果**：

```json
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200 35.48s
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200  2.73s
{"context_id":"cCEy3lLm","response":"收到"} HTTP=200  3.15s
{"error":"litellm.BadRequestError: OpenAIException - Unknown model: definitely-not-a-model-xyz"} HTTP=500 4.93s
```

```text
C14 200 / finish_reason=stop / "1+1 等于 2。"
C18 404 {"error":{"message":"Unknown model: no-such-model-xyz"}}
C19 400 {"error":"Message is required"}，随后 health 200
C20 401 "API key required"
C21 message_async "Message received."，轮询得到"收到"，ASYNC_OK
C22 正确前置：UI 2160 字通过；HTTP 80,000 字符 200 / 34.80s
稳定性：10 条连续 153.4s，全部 200；并发 3 条 6.16/7.50/9.03s；中断后 2.27s 恢复
```

**判定**：C14–C22 全部通过。C22 此前的 404 是 `test-matrix.md` 原命令引用了未创建的 `context_id`；按正确前置（先建会话/用已有 context）重测，UI 2160 字与 HTTP 80k 字符均通过。10 条连续消息每条之后 `running=false`，第 10 条无排队；并发 3 条全部复位；中断后 PID 不变、后续消息正常。**类别：通过**。

**未覆盖**：`/api/api_message` 不返回 `finish_reason`/`usage`；80k 字符的 `chat.json` 副本被 `CONTENT_MAX_LEN=15_000` 截断，模型输入未被截断属 [推断]（代码路径 + 直连 46,887 prompt tokens 一致）。**证据路径**：`probe-chat.md §2–§5`、`probe-stability.md §2–§5`、`local-v5-regression.md:v10 §6`。

### D. 嵌入与记忆（C23–C27）

**验了什么**：嵌入维度、记忆写入/检索/删除/新进程重载、旧索引不兼容（两道防线）。

**怎么验**：`d1_embed.py`、`d3_memory.py`、`d5_reload.py`；v10 收尾补测构造“哈希匹配、内容坏”的索引：12 字节垃圾 + 同步改写 `index.faiss.sha256`，重启加载（v12 未改 `vector_store` 的该分支）。

**结果**：

```text
MODELTYPE OllamaEmbeddings DIM 2560
INSERT jYJqWwSQwM / NfRBSdps2W
SCORE 0.858004 猫喜欢在阳光下打盹。
SCORE 0.644255 量子计算机使用超导比特进行计算。
DELETE_ID NfRBSdps2W NTOTAL_BEFORE 2 NTOTAL_AFTER 1
RELOAD_CREATED False NTOTAL 1
```

```text
$ printf 'GARBAGE12345' > .../usr/memory/default/index.faiss
$ H=$(sha256sum .../index.faiss | cut -d' ' -f1); printf '%s' "$H" > .../index.faiss.sha256
Initializing VectorDB...
a0flatpak: could not read the vector index ... (UnpicklingError: invalid load key, '3'.)
a0flatpak: the index ... was not readable, so the database was set aside
  (suffix .incompatible-20261118-015734) and will be rebuilt
MEMORY_OK ntotal None
（恢复原文件并重启后 ntotal=6，health=200）
```

**判定**：C23–C27 全部通过。第一道防线（哈希不匹配 → 重建）和第二道防线（哈希匹配但内容坏 → `read_index` 报错 → `*.incompatible-*` 改名 → 空索引重建）均已实测；生成 `index.faiss.incompatible-20261118-015734`、`index.faiss.sha256.incompatible-…`、`index.pkl.incompatible-…`，恢复后 `ntotal=6`。**类别：通过**。

**未覆盖**：真 faiss `IxFI` 头（现有 shim 索引，非真 faiss 遗留）；`Memory.get_by_subdir("default")` 的完整 agent 初始化路径。**证据路径**：`probe-models.md §1`、`local-v5-regression.md:收尾状态 §1`。

### E. 语音（C28–C32）

**验了什么**：TTS WAV 头、STT 往返、空文本、超长文本、Ollama 不可达、错误模型。

**怎么验**：`synthesize_sentences` 写 WAV；`wave` 与 `ffprobe` 双读；STT 回译；1400 字；`A0_SPEECH_MODEL=nope`；`OLLAMA_HOST=127.0.0.1:9`。

**结果**：

```text
v12 短句: BYTES 138284, frames 69120, rate 24000, seconds 2.88; ffprobe 2.88
v10 长句: BYTES 583724, frames 291840, rate 24000, seconds 12.16; ffprobe 12.16
STT: '你好,这是Agent Zero的语音测试。' similarity 0.9091 language='english'
空文本: '' / 0.000s（EMPTY_LIST_OK / EMPTY_STR_OK / WHITESPACE_OK）
1400 字: SpeechInputTooLong, 1400 > 1200 (A0_SPEECH_MAX_CHARS), 0.05s
model=nope: RuntimeError model=nope status=404 body='{"error":...}'
黑洞: ConnectError [Errno 111] Connection refused, 0.015s
```

**判定**：C28–C32 全部通过。v8 的同一 WAV 断言曾因 `wave` 信任 `0xFFFFFFFF` 而假通过（2147483647 帧/89478 秒），v10 的 2.72/12.16 s 与 v12 的 2.88 s 才是真通过，`wave` 与 `ffprobe` 误差 0.00 s。C31 的判据按 v10 新行为更新：超长输入被可读地拒绝（`SpeechInputTooLong`，0.05 s），不再要求 1500 字在 200 s 内合成。C29 的 `language='english'` 仍是已知误报，文本正确。**类别：通过**。

**未覆盖**：`/api/plugins/_kokoro_tts/synthesize` 的 CSRF/JSON 形状、多语言 STT、长音频、并发 TTS。**证据路径**：`local-v5-regression.md:v12`、`probe-models.md §2`、`tts-v12.wav`、`tts-v10-final.wav`、`tts-v10-longer.wav`。

### F. OCR 与文档解析（C33–C39）

**验了什么**：图片 OCR、数字 PDF 文本抽取、扫描 PDF 视觉回退、关闭回退、多页预算/页数上限、缺模型、坏 PDF、1×1 图、非 PDF、超时文案。

**怎么验**：P4 生成 `a0_probe.png`、`a0_probe.pdf`、`a0_scan.pdf`、`a0_scan3.pdf`、5 页扫描件；P1 + `S-OCR` 各 MODE；v11 默认预算 135 s；`probe-pdf.md` 逐条复跑。

**结果**：

```text
C33 image: len 11 'A0 PROBE 42' OCR_OK
C34 pdf:   len 15 'A0 PDF PROBE 42' OCR_OK
C35 scan:  len 23 'A0 SCAN PROBE 42 page 1' OCR_OK
C36 nofallback + OLLAMA_HOST=127.0.0.1:9: len 0 '' NO_FALLBACK_OK（无 ConnectError）
C38 A0_OCR_MODEL=no-such-model: ValueError: OCR failed within 45s: HTTPStatusError 404 ... MODEL_MISSING_OK
C39 broken.pdf: FileDataError: Failed to open stream BADFILE_ERR_OK

v11 默认 135s:
C37 scan3: 63.701s, 3/3 页, 无 OCR incomplete
     scan5: 5.88s, '4 of 5 pages processed (A0_OCR_MAX_PAGES=4)'
     budget10: 5.847s, 4/5（A0_OCR_MAX_PAGES=4 先命中）
     onepx 1×1: 0.222s, 'the vision model returned no text for this image.'
     notpdf: 0.082s, 'ValueError: PDF could not be read: FileDataError: Failed to open stream'
     timeout001: 0.218s, '0 of 3 pages processed (timeout after <0.1s).'
```

**判定**：C33–C39 全部通过。v11 把默认文档预算从 60 s 提升到 `max(60, 4*30+15)=135 s`，3 页扫描件 3/3、5 页 4/5（页数上限 `A0_OCR_MAX_PAGES=4`）；1×1、非 PDF、超时文案都返回可读文本/异常，不再有空串或裸 `ValueError`。C34 的矩阵脚本默认 `PDF_NAME=a0_scan.pdf` 会测扫描件，这是矩阵自身的缺陷；显式 `PDF_NAME=a0_probe.pdf` 后数字 PDF 通过。**类别：通过**。

**未覆盖**：手写/低质量扫描件、表格/公式的定量准确率、HTTP 上传路径、Office 文档。**证据路径**：本次复跑；`probe-pdf.md §0/§3`、`local-v5-regression.md:v11 §2`。

### G. 浏览器工具（C40–C43）

**验了什么**：宿主 Chrome 发现、打开 `data:` URL 取标题、不可执行 override、打开/关闭幂等、降级可见性。

**怎么验**：`browser.find_system_chrome()`；`runtime.get_runtime(ctx).call("open", ...)`；`close_all` 两次；`A0_BROWSER_CHROME=/etc/passwd` 行为验证；清 override 后复查 `source=system`。

**结果**：

```text
find_system_chrome() -> /run/host/root/opt/google/chrome/google-chrome
open(data:...A0 Probe Title...) -> id=1 title='A0 Probe Title' content 含 plugin-ok
open(example.com) -> title='Example Domain'，正文 962 字符
OPEN1_ID 1 OPEN2_ID 2 DISTINCT True；CLOSE1/CLOSE2 均返回 {"browsers": []}

v12 /etc/passwd:
find -> None
source -> bundled
warnings -> ['No host Chrome was found (A0_BROWSER_CHROME, PATH and the known locations are all empty or not executable); the bundled Chromium download is used instead.']
binary -> .../tmp/playwright/chromium-1228/chrome-linux64/chrome
工具层 -> 0.59s 正常打开，title='C42 Probe'
清 override -> source=system, warnings=[]
```

**判定**：C40–C43 全部通过。C42 从“静默回退”改为“降级可见”：`source=bundled`、`warnings` 含 `No host Chrome was found`、binary 指向 `chromium-1228`，工具层仍可用；清 override 后 `source=system`、`warnings=[]`。**类别：通过（降级可见）**。

**未覆盖**：真实网页登录/下载；`close_runtime(delete_profile=True)` 的 profile 删除语义（已知实现未使用该参数）。**证据路径**：`local-v5-regression.md:v12`、`probe-browser.md §10`、`80-browser-tool.png`。

### H. 桌面 / Xpra（C44–C48）

**验了什么**：`ensure_system_desktop()`、14500 HTML5、鉴权分支、Xvfb 路径、强制 headless。

**怎么验**：`a0-desktop-start` 起 shadow `:0`；本机隔离实例（`--command=sh` 内 `unset DISPLAY`、`A0_PORT=5081`、独立 `A0_BASE_DIR`/`XDG_DATA_HOME`、临时 `A0_AUTH_KEY`）走 headless；`ss`/`curl` 14500；CDP 取 `canvases`/`exceptions`；正确/错误 key 走 Xpra `info`。

**结果**：

```text
shadow（v12）：xpra shadow :0 ... --bind-tcp=127.0.0.1:14500 ...（不含 --mmap=no）
Handshake complete 计数 1；HTTP 200；CDP canvases=1 EXCEPTIONS 0
91-desktop-v12.png 2880x1800 mean=0.329701 sd=0.437785

headless（2026-11-18，commit 5631f3ab75d7，隔离实例）：
spawn-diag: host='' display=120 port=14500
xpra: /app/bin/xpra start-desktop :120 --xvfb=/app/bin/Xvfb -screen 0 1920x1080x24 -nolisten tcp -noreset --daemon=no --mdns=no --html=on --tray=no --notifications=no --bind-tcp=127.0.0.1:14500 --tcp-auth=env --log-dir=... --log-file=xpra.log
Xvfb: /app/bin/Xvfb-for-Xpra-120 -screen 0 1920x1080x24 -nolisten tcp -noreset :120
tcp_auth_count=1；mmap_no_count=0；XPRA_PASSWORD present；DISPLAY absent
HTTP 200 http://127.0.0.1:14500/；Server: Xpra-WebSocket-Server Python/3.14
xpra info：正确 key rc=0；错误 key rc=28 'authentication failed'
desktop API: available=true display=:120 url=/desktop/session/agent-zero-desktop/index.html?...（非空）
CDP: 无密码 -> password prompt canvases=0；正确密码 -> canvases=1 canvas 1440x757 EXCEPTIONS 0
headless-14500-2026-11-17T20-15-32-936Z.png 1440x757 mean=45.72 colors=1867
headless-desktop-2026-11-17T20-15-44-970Z.png 1440x757 mean=37.05 colors=127（黑板 + 红测试窗）
```

**判定**：C44、C45、C46（shadow + headless）、C47（headless Xvfb）通过；C48（清空 sessions 后的服务重启）未执行。headless 的桌面本身是**裸 X 根窗口**：bundle 没有窗口管理器/桌面 shell，Xpra 自带 greeter 因缺 `xpra.client.gui` 不能运行，D36 关闭了该失败子进程；因此不能写成“完整 XFCE 桌面可见”。**类别：有条件通过**。

**未覆盖**：C48（清 sessions + systemd 服务重启）、760K 无宿主 X 的实机、目标机 host libs/`xauth`、headless 下的文档窗口（LibreOffice 不在 bundle）。**证据路径**：`headless-evidence-20261118-041603.log`、`headless-browser-20261118-041624.log`、`headless-14500-2026-11-17T20-15-32-936Z.png`、`headless-desktop-2026-11-17T20-15-44-970Z.png`、`headless-artifacts/xpra.log`。

### I. WPS MCP（C49–C52）

**验了什么**：配置 JSON、宿主路径、沙盒内 MCP 握手、工具列表、运行时注册、无宿主 WPS 的调用行为。

**怎么验**：`jq` 配置；沙盒内 `flatpak-spawn --host <bun> <dist/index.js>` 写 `initialize`/`tools/list`；`settings_set` 写入 `usr/settings.json`；`/api/mcp_servers_status`；`wps_list_cache`、`wps_check_connection`、文档工具。

**结果**：

```text
initialize: serverInfo.name=wps-office-mcp, protocolVersion=2024-11-05
tools/list: 250 tools, has wps_check_connection=True
bun: 107260472 B, X_OK；dist/index.js: 5186 B, mode 644（不需要可执行位）
usr/settings.json: 2483 B，mcp_servers 含 wps-office
MCPClientBase (wps_office): Tools updated. Found 250 tools.
/api/mcp_servers_status:
  {"name":"wps_office","connected":true,"error":"","tool_count":250}
wps_check_connection: 30.01s {"connected":false,...} isError:false（无宿主 WPS）
wps_get_active_document: 69.78s isError:true；wps_insert_text: 30.02s isError:true
```

**判定**：C49–C52 全部通过（C49 配置/注册/运行时 `connected=true`、250 工具；C50 握手；C51 工具列表；C52 无宿主 WPS 时返回结构化、可读的错误，工具没有崩溃、没有挂死超过 90 s）。C52 记“通过（有保留）”：宿主无 WPS Office 只限制真实文档操作，`isError` 语义不一致是上游缺陷，写入 §7.3。**类别：通过（有保留）**。

**未覆盖**：真实 WPS 文档操作、250 工具逐项调用、无 WPS 时提示词降级。**证据路径**：`local-v5-regression.md:最终补测 §3/§5`、`probe-i-j-k.md §1`、`wps-mcp.md §3–§5`。

### J. systemd 与重启（C53–C57）

**验了什么**：unit 模板、`install-services.sh` 的 root 替换、手工 kill/重启、systemd 本体。

**怎么验**：`systemctl is-enabled`、`systemd-analyze verify`、`ls /etc/systemd/system/agent-zero*`、`journalctl -u agent-zero`；一次 `flatpak kill` + `flatpak run` 计时；root 版 unit 的 `sed` diff。

**结果**：

```text
systemd-analyze verify: agent-zero-desktop.service: Command /usr/local/bin/a0-desktop-start is not executable
ls /etc/systemd/system/agent-zero*: No such file or directory
systemctl --user list-unit-files 'agent-zero*': 0 unit files listed
journalctl -u agent-zero: -- No entries --
手工重启: old_pid=1716379 -> new_pid=1838580, health=200 elapsed=10s
root sed diff: User/Group/XDG_RUNTIME_DIR/DBUS/XAUTHORITY/WorkingDirectory/RequiresMountsFor 均正确替换
```

**判定**：C53–C57 全部**环境不具备**：本机没有安装 unit、没有 `/run/user/0`、`sudo` 需密码；手工重启 10 s 回到 health 200 只能证明应用层可重启，不能证明 `Restart=always` 或开机自启。root 版 `sed` 逻辑静态正确，但 root 的 Flatpak user 安装与图形会话不存在。**类别：环境不具备**。

**未覆盖**：`systemctl restart`、`kill -9` 后自动拉起、`reboot`、journal 重启记录、root 形态 `a0-desktop-start`。**证据路径**：`probe-i-j-k.md §2`、`systemd/agent-zero.service`、`systemd/agent-zero-desktop.service`。

### K. 资源与清理（C58–C61）

**验了什么**：孤儿进程、端口、数据目录、日志/OOM、重装数据、磁盘、长跑资源。

**怎么验**：`flatpak ps`、`pgrep -af`、`ss -ltnp`、`du -sh`、`journalctl -k | grep -i 'killed process'`、`df -h /home`；`probe-stability.md` 30 分钟采样；v10 收尾/v12 安装后恢复记忆索引。

**结果**：

```text
应用核心进程: 1 × run_ui.py, 1 × ollama serve；重启后 0 × xpra
端口: 127.0.0.1:5080 python, 127.0.0.1:11434 ollama；14500 当前无监听
data 1.4G；venv 847M；tmp/playwright/chromium-1228 379M；usr/memory 84K（5 文件）
ollama.log 约 1.5 MB（1,517,335 B，03:15），未删除
journalctl -k: 2 条 OOM，进程名均为 omp；无 agent-zero/ollama/xpra OOM
/home: 111G, 81G used, 29–30G avail, 74%
RSS 450.7–453.0 MB；fd 锯齿 219 → 59（请求期），无持续泄漏
v10 收尾/v12/v13 安装后 memory ntotal=6，conf/prompts/usr 保留
```

**K06（新增观察项，不改 §3 计数）**：每次 HTTP 请求临时 +3 fd（socket +2、eventpoll +1），高并发时形成 FD 高水位（v18 31 分钟 83→147，峰值 171），停止请求 10 s 内回落（171→42）；v19 空闲 3.5 分钟稳定 60，无 CLOSE_WAIT、无 ESTAB 堆积。根因是 asyncio 每请求创建/延迟关闭事件循环，配合 `helpers/api.py::_dispatch` 每请求实例化 handler，回收依赖 GC；**不是泄漏**，峰值远低于 1024。严重度低–中，不阻塞交付；长跑（>2 h 持续请求）需复测是否收敛。证据：`fd-leak-root-cause.md §1–§7`。

**判定**：C58–C61 全部通过。`flatpak ps` 条目数不等于实例数，验收期间曾出现探针入口与僵尸；C59 的“重装前后文件数/哈希”没有逐项留原始行，但 v10 收尾/v12/v13 安装后恢复索引 `ntotal=6` 证明数据未被清空。K 类长跑证据还显示 fd 峰值 219 在受控聊天后回落到 59、RSS 450.7–453.0 MB，没有持续泄漏。**类别：通过**。

**未覆盖**：崩溃后孤儿检查（依赖 C55）、重装前后 `model_providers.yaml` 哈希对比、长期磁盘增长基线。**证据路径**：`probe-stability.md §6`、`probe-i-j-k.md §3`、`local-v5-regression.md:收尾状态 §2/§3`。

## 5. 缺陷与修复台账

“引入版本”指首次可判定的版本；“修复版本”指修复进入镜像的版本。commit 均为短前缀（10–12 位）。

| 编号 | 严重度 | 现象 | 根因 | 修复（文件:行） | 验证证据 | 引入版本 | 修复版本 |
|---|---|---|---|---|---|---|---|
| D01 | 高 | `flatpak build-bundle` 报 `Refspec not found` | `scripts/build.sh` 调 `flatpak-builder` 未传 `--repo` | `scripts/build.sh:70` 加 `--repo="$CACHE"` | `build-run.md §3` 首次失败原文与重试成功 | 初版 | `169f5e09e5` |
| D02 | 高 | Settings/Projects 模态框空白；所有 `x-teleport="#welcome-channels"` 失败，Alpine observer 死 | `webui` 一次性 seed，升级后旧模板缺 slot | `flatpak/agent-zero.sh:94` 把 webui 纳入每次 `cp -a`；`base_dir.py` 不 seed webui | `local-v5-regression.md:v5 §2` 6/6；`ui-rootcause.md §1–§5` | ≤ `475e157782` | `a8f932128c` |
| D03 | 高 | HTML5 客户端 `$ is not defined`，jQuery/jQuery UI 404；`default-settings.txt` 404 | Debian 包内是悬空符号链接 `/usr/share/javascript/...`，bundle 只拷 `usr/share/xpra` | `flatpak/org.agentzero.AgentZero.yml:114-121` 改实体文件；新增 jquery/jquery-ui deb 源 | `build-run.md` 第六轮：285284 B / 540438 B，200，`/*!`；`50-desktop-v7.png` | ≤ `a8f932128c` | `1e0f41ccec` |
| D04 | 高 | 升级后旧 venv 的 xpra 布局遮蔽新包，`xpra.net.mmap` 是文件而非包 | venv 里 xpra/gi/cairo 只装一次，无版本戳 | `flatpak/agent-zero.sh:180-209` 每次启动按 `.a0-python-deps` 戳刷新三棵树 | `local-v5-regression.md:v7 §1`：戳匹配、`xpra/net/mmap` 是目录 | ≤ `1e0f41ccec` | `1ddcd34f7b` |
| D05 | 高 | Xpra `--mmap=no` 导致 `xpra.net.mmap.common` 导入失败，握手断开 | 关闭 mmap 反而触发上游 hello 路径的 mmap 导入，二者矛盾 | `flatpak/a0flatpak/desktop.py:346` 从 argv 过滤 `--mmap=no` | v12 `Handshake complete`、`canvases=1`、无 `is not a package` | ≤ `1ddcd34f7b` | `0e6c508202` |
| D06 | 高 | `A0_AUTH_KEY` 不保护 Xpra shadow 分支，14500 可无认证连接 | shadow 分支未追加 `--tcp-auth=env` | `flatpak/a0flatpak/desktop.py:276-278`、`348-351`：有 key 时统一注入并去重 | `local-v5-regression.md:v7 §5` + 最终补测 §2：临时 key `tcp-auth` 计数 1，清 key 0 | ≤ `169f5e09e5` | `a33e50bd24` |
| D07 | 高 | 所有 POST/CSRF 403，设置/项目面板空白；默认值还会遮蔽 `.env` | `ALLOWED_ORIGINS` 未设；上游在 login disabled 时拒绝无 Origin 请求；直接 export 默认值会压过 `.env` | `flatpak/agent-zero.sh:144-164`：先看 `.env`，再设 loopback 默认并追加 bind host | v6/v12 运行进程 environ 两地址；带 Origin csrf `ok:true`；verify 6/6 | ≤ `169f5e09e5` | `a33e50bd24` / `475e157782` |
| D08 | 中 | Ollama 日志启动后 `*.log (deleted)`，无持久日志 | 日志写在 `logs/`，框架迁移 `Removing logs...` 在 Ollama 打开后删目录 | `flatpak/agent-zero.sh:237` 改到 `$DATA_DIR/ollama.log` | v12 `ollama.log` 649623 B，fd 指向同一路径；`probe-i-j-k.md §K.4` | ≤ `169f5e09e5` | `a33e50bd24` |
| D09 | 中 | 沙盒内 `command -v google-chrome` MISSING，Patchright 下载 177 MiB 回退 Chrome | `which` 在沙盒 `/usr`（runtime）查不到宿主 Chrome | `flatpak/a0flatpak/browser.py:51-84` 增加 `_CHROME_PATHS`（`/run/host/root/opt/...` 等 7 条） | `probe-browser.md §2`：返回宿主路径，启动无下载 | ≤ `169f5e09e5` | `a33e50bd24` / `475e157782` |
| D10 | 中 | override 指向存在但不可执行的文件时，错误延后为 Patchright `EACCES` | `A0_BROWSER_CHROME` 分支只查 `is_file()` | `flatpak/a0flatpak/browser.py:74` 加 `os.access(..., X_OK)` | `build-run.md` 第九轮 §1：`/etc/passwd -> None` | ≤ `0e6c508202` | `4d4e00e7a9` |
| D11 | 高 | 坏模型/黑洞/超限异常被 `FileNotFoundError: fw.msg_output_limit.md` 二次覆盖 | `prompts/` 一次性 seed，升级新增的 prompt 缺失 | `flatpak/a0flatpak/base_dir.py:52-58` 每次 `_merge_missing`；`agent-zero.sh:46` 逐文件补缺 | v8/v10 坏模型返回可读 JSON error，无 `FileNotFoundError` | ≤ `a8f932128c` | `1e0f41ccec` |
| D12 | 高 | 长对话收尾崩溃，`context.running` 卡 true，后续消息排队 | Python 3.14 + anyio 读取 `_TaskStub` 缺失的 `_must_cancel`/`_fut_waiter`/`done` | `flatpak/a0flatpak/compat.py:56-83` 补成员；`152-187` 修 `current_task` | `probe-stability.md`：10 条连续 153.4s 无卡死、中断 2.27s 恢复、并发 3 条全部复位 | ≤ `a8f932128c` | `1e0f41ccec` |
| D13 | 高 | 记忆删除必崩（缺 `remove_ids`/`reconstruct`） | numpy shim 未实现 langchain `FAISS.delete` 依赖的方法 | `flatpak/a0flatpak/vector_store.py:65-79` 补 `reconstruct_n`/`reconstruct`/`remove_ids` | `probe-models.md §D4`：ntotal 2→1，victim 不再返回 | 初版 | `169f5e09e5` |
| D14 | 高 | 旧 faiss/坏索引让记忆初始化崩溃，无重建分支 | `read_index` 直接 `pickle.load`；`FAISS.load_local` 无 try/except | `flatpak/a0flatpak/vector_store.py:90-127` 返回空索引+可读警告；`131-179` 把坏库改名 `*.incompatible-*` 并返回 None | v10 收尾补测：`UnpicklingError` → `.incompatible-20261118-015734` → 重建；恢复后 ntotal=6；v12 未改该分支 | ≤ `4d4e00e7a9` | `7a55c085a2` |
| D15 | 高 | TTS WAV 头 RIFF/data size = `0xFFFFFFFF`，`wave` 报 2147483647 帧/89478 秒；v8 的 `wave` 断言因此假通过 | Ollama 流式响应的头部先写 `0xFFFFFFFF` 哨兵值（stream header sentinel），真实长度在流结束前不可知 | `flatpak/a0flatpak/speech.py:45-75` `_repair_wav` 重写两个 size 字段 | v8 假通过（2147483647 帧/89478 秒）；v10 2.72/12.16s；v12 2.88s，wave=ffprobe 0.00s | 初版 | `7a55c085a2` / v12 复验 |
| D16 | 中 | 语音错误不含模型名/状态；超长文本无限等待 | `raise_for_status()` 直接抛 httpx 默认文本；无长度上限，httpx read timeout 不覆盖总时长 | `flatpak/a0flatpak/speech.py:38-42` 加 `SPEECH_MAX_CHARS=1200`/`SpeechInputTooLong`；`98-119` `_describe` 带 model/status/body | v10 复验（v12 未改 speech.py）：model=nope status=404 body；1400 字 0.05s 抛错；黑洞 0.015s | 初版 | `7a55c085a2` |
| D17 | 高 | 主包沙箱无法启动/注册 WPS MCP；配置指向 system 路径与 `bin/node`；缺 D-Bus/显示环境 | 缺 `--talk-name=org.freedesktop.Flatpak`；MCP 子进程只继承默认环境；`flatpak-spawn` 默认 cwd 在宿主不存在 | `flatpak/wps-mcp-config.json` 改 `/usr/bin/flatpak-spawn` + `env`（DBUS/XDG/DISPLAY/XAUTHORITY）+ `--directory=/`；`org.agentzero.AgentZero.yml:27` 加 talk-name | `local-v5-regression.md:最终补测 §5`：`connected=true`、250 工具；`probe-i-j-k.md §I.2` 冷启动 0.48 s | ≤ `a8f932128c` | `d3731ae0` |
| D18 | 高 | 任何 PDF 解析 `TypeError: parse() takes 2 positional arguments but 3 were given`；扫描件无分页/超时预算；默认 60s 只够 2 页 | `_parse_pdf_with_fallback` 返回的闭包缺 `self`；`per_document_timeout` 与 OCR 预算语义冲突 | `flatpak/a0flatpak/ocr.py:188-190` 加 `self`；`32-34` `OCR_MAX_PAGES=4`/`OCR_MARGIN=5`；`43-44` `_planned_budget=135s`；`132-162` `_ocr_pages` 预算 | v12：数字 PDF len 15；扫描 23；v11 默认 135s 下 3/3、5 页 4/5；边界文案可读 | ≤ `169f5e09e5` | `a33e50bd24` / `d3731ae0` |
| D19 | —（非缺陷） | 曾误判 `xiaomi-ocr` 缺 manifest | 只跑 `find models/manifests -type f`，漏了 `manifests-v2` 符号链接 | 无代码改动；盘点方法改为同时看 `manifests-v2` 与 `find -type l` | `models-inventory.md §8`：manifest 合法、digest 全匹配 | — | 已排除 |
| D20 | 低 | 文档不一致：README 的 `plugin/`、requirements 注释、WPS 路径 | 多次改动后文档漂移 | `flatpak/README.md:145-170`、`286-350`；`flatpak/requirements-flatpak.txt` 注释；`docs/setup/host-ollama.md` | v9/v12 镜像断言与当前 `git diff` | 初版 | `4d4e00e7a9` / `7a55c085a2` |
| D21 | 高 | OCR 默认 60 s 文档预算只够 2 页，`A0_OCR_MAX_PAGES=4` 不可达；3 页扫描件默认截断 | `per_document_timeout` 默认 60 与单页 20–28 s 不匹配 | `flatpak/a0flatpak/ocr.py:43-44` `_planned_budget=max(60,4*30+15)=135` | `probe-pdf.md §0`（60s 2/3）；`local-v5-regression.md:v11 §2`（135s 3/3、5 页 4/5） | ≤ `7a55c085a2` | `d3731ae0` |
| D22 | 中 | 1×1 PNG 返回空串；非 PDF 抛裸 `FileDataError`；超时文案 `0s` | 视觉回退对“无文本”与“读不了”的边界未统一包装；`_secs` 未处理亚秒 | `flatpak/a0flatpak/ocr.py:49` `<0.1s` 格式；`157/170` `PDF could not be read`；`212/243` `returned no text` | `local-v5-regression.md:v11 §2`：onepx/notpdf/timeout001 均通过 | ≤ `7a55c085a2` | `d3731ae0` |
| D23 | 中 | 无宿主 Chrome 时静默回退 `chromium-1228`，运维误以为 `A0_BROWSER_CHROME` 生效 | `prepare_playwright_cache()` 回退分支没有 warning/source | `flatpak/a0flatpak/browser.py:106-113` 追加 `warnings` 并标 `source=bundled` | `local-v5-regression.md:v12`：source=bundled、warnings 含 `No host Chrome was found`、0.59s 仍可打开；清 override source=system | ≤ `d3731ae0` | `53ae0c0d` |
| D24 | 中 | 镜像误带 `docs/manual-acceptance/` 28 份验收文档（约 300 KB） | `build.sh` 的 `cp -a docs` 与 dir 源的 `..` checkout 把验收记录带进镜像 | `flatpak/org.agentzero.AgentZero.yml:219-225` 的 `skip: docs/manual-acceptance` | v13 镜像断言：`manual-acceptance` 计数 0，`docs/setup/host-ollama.md` 计数 1 | ≤ `53ae0c0dc2` | `4d0ccd2ceeb4` |
| D25 | 高 | 两个 unit 只被 `graphical.target` 拉起；760K 是 tty-only，开机停在 `multi-user.target`，`systemctl enable` 显示 enabled 但服务不启动（C56 失败） | 安装目标与宿主默认 target 不一致；`agent-zero.service` 还 `Wants/After=display-manager.service` | `systemd/agent-zero.service` 改 `WantedBy=multi-user.target`、去掉 DM；`agent-zero-desktop.service` 改 `WantedBy=graphical.target multi-user.target`，DM 仅保留 After，检测到 DM 时 drop-in 补 Wants | 暂存根 `systemd-analyze verify --root` exit 0；无 DM 与有 DM 两种 staged 输出均验证 | ≤ v13 | 本轮 |
| D26 | 高 | `agent-zero-desktop.service` 是 oneshot，默认启动超时 90s；`a0-desktop-start` 光 health 就等 120s，冷启动必被 systemd 杀掉 | systemd 默认 `DefaultTimeoutStartUSec=1min 30s` 小于脚本等待 | `agent-zero-desktop.service` 加 `TimeoutStartSec=300` | `systemctl show --all` 原文；暂存根 `--root` verify exit 0 | ≤ v13 | 本轮 |
| D27 | 高 | desktop 启动失败时 `ensure_system_desktop()` 返回 `available=False`，脚本仍 exit 0；`RemainAfterExit=yes` 把 unit 标 active，`Restart=on-failure` 不触发，C56 假通过 | Python 只 print 结果，不设置退出码 | `systemd/a0-desktop-start` 末尾 `raise SystemExit(0 if r.get("available") else 1)` | `sh -n` OK；fake flatpak exit 7 传播为 7；`--root` verify exit 0 | ≤ v13 | 本轮 |
| D28 | 高 | unit 硬编码 `kunweiz`/`1000`/`/home/kunweiz`，安装器只 sed 固定串；`Group=$USER_NAME` 假定同名主组，root 也可装；`getent`/`cut` 管道无 pipefail 可写空 home | 模板与安装器把用户身份当常量 | 用户身份移入 drop-in `10-user.conf`；installer 用 `id -gn`、拒绝 UID 0、字符白名单、`set -euo pipefail`；unit 加 `AssertPathExists` 守卫 | staged drop-in 原文；`install-services.sh root` 与未知用户均 exit 1 且 0 文件落盘；base unit `grep` 无硬编码 | ≤ v13 | 本轮 |
| D29 | 中 | 安装器直接 `sed > /etc/systemd/system/$unit`，中断或失败留下半截 unit；无预检；`systemctl enable` 不清理旧 target 链接 | 写入与安装顺序不安全 | 改为 stage → `systemd-analyze verify` → drop-in 先落盘 → 同目录临时文件 `mv` → `systemctl reenable` | 两次 `A0_STAGE_ROOT` 产物 `diff -r` exit 0；`--root` verify exit 0 | ≤ v13 | 本轮 |
| D30 | 中 | UI 120s 内未返回 200 时安装器仍 exit 0，部署脚本误判成功；失败无诊断 | 循环后只 echo | 超时 `exit 1` 并提示 `journalctl -u agent-zero -n 40` | 代码路径；`bash -n` OK；未在真机触发超时 | ≤ v13 | 本轮 |
| D31 | 中 | 无登录的启动没有 `/run/user/<uid>` 和 session bus，unit 却硬编码该路径 | 系统服务不经过 PAM/logind，安装器未 enable-linger | installer `loginctl enable-linger`；drop-in `Wants/After=user@<uid>.service` | drop-in 原文；`user@.service` 的 `BindsTo=user-runtime-dir@%i`；本机 linger=yes | ≤ v13 | 本轮 |
| D32 | 低 | `a0-desktop-start` 硬编码 `$HOME/.var/app/.../data/agent-zero`，与 launcher 的 `${XDG_DATA_HOME:-$HOME/.local/share}/agent-zero` 不是同一表达式 | 两处各自推导数据目录 | `a0-desktop-start` 改用 launcher 同款表达式 | 沙盒内 `XDG_DATA_HOME=/home/kunweiz/.var/app/.../data`，两式同值；`sh -n` OK | ≤ v13 | 本轮 |
| D33 | 低 | health URL 硬编码 5080，设置 `A0_PORT` 时 desktop 白等 120s | 脚本没读 launcher 的端口变量 | `a0-desktop-start` 用 `A0_PORT=${A0_PORT:-5080}` | `sh -n` OK；health 200 时 fake flatpak 流程通过 | ≤ v13 | 本轮 |
| D34 | 低 | desktop 只认 `~/.Xauthority`；GDM/Wayland 的 cookie 在 `/run/user/<uid>/gdm/Xauthority` 或 `.mutter-Xwaylandauth.*`，Xpra 影子会认证失败 | 单元把 XAUTHORITY 固定为 home 下默认文件 | `a0-desktop-start` 在默认文件不可读时回退 GDM/mutter cookie | 本机 `~/.Xauthority` 存在（156 B）；GDM 路径不存在，无法本机复现 | ≤ v13 | 本轮 |
| D35 | 中 | `RemainAfterExit=yes` + `Restart=on-failure` 只在启动失败时重试；Xpra 启动后死亡，unit 仍 active，C56 只看 `is-active` 会假通过 | oneshot 启动器不是 supervisor | README 明确该边界；C56/C58 需补 14500 或进程断言 | `README.md §Running as a service` | ≤ v13 | 本轮 |
| D36 | 中 | headless 启动时 `xpra start-desktop` 自动拉起 `xpra desktop-greeter`；bundle 只有 HTML5 客户端，缺 `xpra.client.gui`，子进程立刻失败并在 `xpra.log` 留下 `xpra main error`（桌面本来也没有 WM/shell） | `start-desktop` 默认 `XPRA_DESKTOP_GREETER=1`；Flatpak bundle 未装 GTK client | `flatpak/a0flatpak/desktop.py:296-301` headless env 设 `XPRA_DESKTOP_GREETER=0`；HTML5 客户端是 UI，桌面本身无 WM/shell | 本机 headless 隔离实例（`4d0ccd2ceeb4`→`5631f3ab75d7`）：`xpra.log` 中 `desktop-greeter`/`xpra main error` 计数 0；14500 200；canvas=1 | ≤ `4d0ccd2ceeb4` | `5631f3ab75d7` |
| D37 | 低 | headless 命令行带 `--log-dir` + `--log-file=xpra.log`，但 `--daemon=no` 时 Xpra 不写 log file，profile 下只有 stderr log，运维找不到命令行承诺的 `xpra.log` | Xpra `log_to_file = opts.daemon or XPRA_LOG_TO_FILE == 1`（`xpra/scripts/server.py:934`） | `flatpak/a0flatpak/desktop.py:291-295` headless env 设 `XPRA_LOG_TO_FILE=1` | 本机 headless 隔离实例：`xpra.log` 6,557 B（首行 `created tcp socket '127.0.0.1:14500'`）；`xpra-stderr.log` 只保留早期 stderr | ≤ `4d0ccd2ceeb4` | `5631f3ab75d7` |
| D38 | 高 | 页脚固定 `Version unknown unknown`；每页 console 报 `Failed to load self-update info: [Errno 2] ... 'git'`；`/api/health` 为 `{"gitinfo":null,"error":".../data/agent-zero"}` | 沙箱无 `git` 与 `.git`：GitPython 读仓库失败，`self_update` 又直接 `subprocess.run(["git",...])` | `flatpak/a0flatpak/version.py` 用 build-info 替换 `get_git_info()`；`scripts/build.sh:32-38` 生成 `A0_BUILD_*`；`agent-zero.sh:265-271` source；`flatpak-ui.patch` 在 settings 与 self-update 两处 refresh 前短路 | health：version `058582f-dirty`、error null；页脚 `Version 058582f-dirty 2026-11-17T20:31:57Z`；首页与设置页 console error 0 | ≤ `4d0ccd2ceeb4` | `ab3d8e6150f7` |
| D39 | 中 | 文件浏览器 7 个顶层目录显示 `1/1/70 8:00 AM`（agents、api、conf、extensions、plugins、prompts、webui） | flatpak-builder 把源 mtime 归一为 Unix epoch，`agent-zero.sh` 的 `cp -a` 原样保留 | `agent-zero.sh:58-109` 四处复制改 `cp -a --no-preserve=timestamps`；新增 `refresh_dir_mtime` 修复旧数据已落的 epoch 目录 | `/api/get_work_dir_files?path=%2Fa0` 12 项全部 ≥ 2026-11-01；`find -maxdepth 1 ! -newermt 2020-01-01` 为空；`usr/memory` mtime 仍为 01:38 | ≤ `4d0ccd2ceeb4` | `ab3d8e6150f7` |
| D40 | 中 | 桌面 surface 每次 resize 返回 400：`{"ok":false,"error":"xrandr is not installed."}` | `virtual_desktop.resize_display` 以 `shutil.which("xrandr")` 为空直接失败，路由把 `ok:false` 映射为 400 | `flatpak/a0flatpak/desktop.py::_patch_resize_display`：无 xrandr 时返回 `ok:true, resized:false`，保留请求尺寸；有 xrandr 时仍走原实现 | 700×800、1118×770、647×852 三次均 **200**，body 含 `"resized":false` | ≤ `4d0ccd2ceeb4` | `ab3d8e6150f7` |
| D41 | 中 | 390 px 下 `.right-canvas-rail` 为 `position:fixed; z-index:4`，压住消息气泡与首页卡片（实测重叠 20×95、10×14 px） | 上游 `right-canvas.css` 在 ≤640 px 没有隐藏 rail；只有偏好打开时才渲染，但打开后仍固定覆盖 | `flatpak/patches/flatpak-ui.patch` 追加 `@media (max-width:640px){.right-canvas-rail{display:none!important}}` | 390×844：`display=none`、`scrollWidth=390` 无横向滚动、9 条气泡 0 重叠、console error 0 | ≤ `4d0ccd2ceeb4` | `ab3d8e6150f7` |
| D42 | 高 | 插件补丁架构失效：19 个 `apply()` 中 6 个直接 `setattr` plugin 对象，改到的是 `/app` 副本，运行中的活对象在 `$BASE_DIR/plugins`，补丁静默失效 | 框架按裸名从可写树加载插件模块且不写入 `sys.modules`；`purge_namespace("plugins")` 每次换新对象；旧 `apply()` 用 `except ImportError: pass` 吞掉失败 | 新增 `flatpak/a0flatpak/plugin_guard.py`：按 `sys.modules` 的名字/文件后缀与框架 loader 找活对象，`register_module` 重放，挂 4 个钩子 | `v15-v16-fix-run.md §1/§2`（最终行序）；v16 `verify-security-fix.sh` 12/12 | ≤ `ab3d8e6150f7` | `72842c7a`（v15 首修，v16 补全） |
| D43 | 高 | TTS/STT 每次启动后永久失效：两端都是 HTTP 200 + `success:false`，正文 `No module named 'spacy'` / `module 'whisper' has no attribute 'load_model'` | `agent-zero.sh` 每次启动无条件 `cp -a` 覆盖插件文件，触发 purge，补丁留在旧对象 | `flatpak/agent-zero.sh` 的 `cp` 改为按 `.a0-build-info` 的构建 commit 幂等；`flatpak/a0flatpak/speech.py:263` 请求前 `ensure()` 自愈 | `v15-v16-fix-run.md §4.3`：TTS 200 `audio_len=286780`、WAV 4.48 s；§4.5 touch 后仍 200 | ≤ `ab3d8e6150f7` | `72842c7a` |
| D44 | 高 | 文件 API 写操作无边界：`/etc`、`$HOME` 下任意文件可写可删 | handler 只校验 CSRF 与路径存在，不校验目标是否在工作区 | `flatpak/a0flatpak/sensitive_paths.py:70` 读 `A0_WRITE_ROOTS`（默认 `/a0:~/Documents:~/Downloads`），`:101` 越界 403 `WRITE_OUTSIDE_WORKDIR` | `v15-v16-fix-run.md §4.2` 12/12（含写边界项） | ≤ `ab3d8e6150f7` | `0eda9fe1` |
| D45 | 中 | 下载不存在的文件返回 500 + 完整 traceback | 通用错误分支直接回传异常文本 | `sensitive_paths.py:205/222` 404 `NOT_FOUND`；`:105` 500 只回 `INTERNAL`，traceback 仅进日志 | 同上 12/12 | ≤ `ab3d8e6150f7` | `0eda9fe1` |
| D46 | 中 | 非空目录被无确认递归删除 | 删除分支不区分空目录与非空目录 | `sensitive_paths.py:182/195` 409 `NON_EMPTY_DIRECTORY` | 同上 12/12 | ≤ `ab3d8e6150f7` | `0eda9fe1` |
| D47 | 高 | `flatpak-spawn --host` 可执行宿主命令；`--filesystem=host` 把私钥目录暴露给沙箱 | manifest 同时给了全盘 `host` 与 `--talk-name=org.freedesktop.Flatpak`，后者是 WPS MCP 的必需项 | `flatpak/org.agentzero.AgentZero.yml:18-25` 加 8 条 `--nofilesystem`；`--talk-name` 保留 | `v15-v16-fix-run.md §4.1`：安装 metadata 的 `filesystems=` 含 8 条 `!~`；`--show-permissions` 不显示负权限（§7） | ≤ `ab3d8e6150f7` | `0eda9fe1`（部分） |
| D48 | 高 | 浏览器 `page.goto(timeout=30000)` 超时只 warning，没有有效上限；DNS 错误不冒泡；HTTP 状态码不透出 | `_goto` 把异常转成 warning，调用方拿到成功 | `flatpak/a0flatpak/browser_guard.py:36` `A0_BROWSER_CALL_TIMEOUT=45` 兜底；`:161` `NAVIGATION_FAILED`；`:171` 返回 `status` | `browser_guard.py` 自测；v16 复验 | ≤ `ab3d8e6150f7` | `72842c7a` |
| D49 | 中 | 浏览器 `close_runtime` 不结束 Chrome，RSS 228 MB 常驻；`delete_profile` 被忽略 | 关闭路径只清理上下文，不杀进程、不删 profile | `browser_guard.py:290-320` 补 `close_runtime`：最后一个会话关闭共享 Chrome 并校验 `delete_profile` | v16 复验 RSS 回落 | ≤ `ab3d8e6150f7` | `72842c7a` |
| D50 | 中 | WPS MCP 更新报 `AttributeError: '_TeeLog' object has no attribute 'fileno'`，`tool_count=0` | tee 包装只实现 `write`/`flush` | `flatpak/a0flatpak/mcp_cache.py:320-360`：补 `fileno`/`isatty`/`writable`/`readable`/`seekable`/`encoding`/`errors`/`closed`，`__getattr__` 委托 | `v15-v16-fix-run.md §5`：`Popen(stderr=tee)` 写入临时文件、WPS 250 工具 | ≤ `ab3d8e6150f7` | `d8c5b96a` |
| D51 | 高 | `desktop.py` 的 `_apply_desktop_session` 缺 `from helpers import virtual_desktop`，抛 `NameError`，desktop 永远建不起来 | 延迟 import 只写在别的分支 | `flatpak/a0flatpak/desktop.py:156` 函数内补 `from helpers import virtual_desktop` | `v15-v16-fix-run.md §4`：`{action:"session"}` 200、`available:true`、`display:":0"` | ≤ `ab3d8e6150f7` | `be957363ef7e` |
| D52 | 高 | `/desktop/health` 报 healthy 但 session 实际失败（健康检查撒谎） | health 只看文件存在，不读 session 状态 | `desktop.py:127-136` 与 `:179-190`：`collect_status` 与 session 判定同源 | 同上 | ≤ `ab3d8e6150f7` | `be957363ef7e` |
| D53 | 低 | `commit_time` 取构建时刻而非提交时间，health 的时间语义错位 | 只有一个时间字段，构建脚本写的是当前时间 | `flatpak/a0flatpak/version.py:27-33` 分离 `A0_COMMIT_TIME`/`A0_BUILD_TIME`；`scripts/build.sh` 写四键 | `v15-v16-fix-run.md §4.6`：`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T22:18:48Z` | ≤ `ab3d8e6150f7` | `d8c5b96a` |
| D54 | 中 | WPS MCP 58891 `EADDRINUSE` 时静默 `resolve()`，之后所有工具必 30 s 超时 | 端口由每个新 bun 反复抢，失败被吞成成功 | `mcp_cache.py:205` `_lock_for` 按 server 串行化；`:41` 返回 `MCP_BUSY` | `mcp_cache.py` 自测；WPS 250 工具 | ≤ `ab3d8e6150f7` | `d8c5b96a` |
| D55 | 中 | 每次 `call_tool` 重启 MCP 子进程，`cache_data`/`get_cached_data` 跨调用必失效 | 缓存挂在子进程生命周期上 | `mcp_cache.py:79-189`：四个缓存工具本地化（`_cache_data`/`_get_cached_data`/`_list_cache`/`_clear_cache`） | 同上 | ≤ `ab3d8e6150f7` | `d8c5b96a` |
| D56 | 中 | OCR 截断 PDF 静默降级为空文档：`ok=true` + `0 of 5 pages` + 白跑 45 s | MuPDF 的 `object out of range` 告警未判定；`processed==0` 仍返回成功注记 | 已修：`ocr.py:151` `_damaged_pdf()` 判定告警并抛错、`:224` `processed==0` 改为抛错 | v20 实测 0.095 s 返回 `PDF could not be read: damaged page tree…`，无重复前缀；v14 失败记录见 `edge-media.md §2 C15/C15b` | ≤ `ab3d8e6150f7` | **已修并实测通过（v20）** |
| D57 | 中 | OCR 默认预算到不了 `A0_OCR_MAX_PAGES=4`：45 s/页 × 4 页撞上 60 s 文档预算，只出 2/5 | 页预算与文档预算各自默认，尾注只报 timeout | 已修：`ocr.py:42` `_planned_budget()=max(60, 页数×30+15)`，`:90` `_document_limit()` 在调用方不传 `per_document_timeout` 时改用它；v19 再把 `A0_OCR_MAX_PAGES` 写进尾注 | v19 实测 `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).` | ≤ `ab3d8e6150f7` | **已修并实测通过（v19）** |
| D58 | 低 | STT 对中文音频输出拼音（`language=english`），3/3 次一致 | 插件默认 `language: en`：`runtime.DEFAULT_CONFIG`、`migration.DEFAULT_CONFIG`、`default_config.yaml`、`usr/plugins/_whisper_stt/config.json` 四处都是 `en`，多语模型因此强制音译 | 已修：四处默认改空串，`_resolve_language("") → None`，请求体不再带 `language`；UI 两处回退改空串、placeholder 改 `auto (blank = auto)`。见 `v19-fix-plan.md §D58` | v19 实测中文 3/3 汉字、英文正确；v18 拼音复现见 `stt-pinyin-root-cause.md §1` | ≤ `ab3d8e6150f7` | **已修并实测通过（v19）** |
| D59 | 低 | 空消息（`text=""` / 缺字段 / `null`）返回 200 并落到最近会话，与 `/api/api_message` 的 400 不一致 | 两个聊天入口的入参校验不同：`message` 只做 `str(... or "")` 透传，`api_message` 才校验空值 | 未修 | `edge-chat.md §2 E1`：5 个变体全 200；`probe-chat.md` 的 C19 测的是 `api_message`，400 属另一端点 | ≤ `ab3d8e6150f7` | 未修 |
| D60 | 中 | 100×50 低分辨率图 OCR 返回无关文本且 `ok=true`，无拒识/低置信标记 | 视觉回退不看输入分辨率与输出置信，只要有文本就判成功 | 未修（记录） | `edge-media.md §2 C13`：76 字符无关数学题，无 `OCR incomplete` | ≤ `ab3d8e6150f7` | 未修 |
| D61 | 中 | STT 无静音判定：1 s 全零静音返回 `Oh,`、1 s 粉噪返回 `Okay.`，均 `success:true` | 补丁路径未使用 `silence_threshold`，静音直接进模型 | 未修（记录） | `edge-media.md §2 B7/B8` | ≤ `ab3d8e6150f7` | 未修 |
| D62 | 低 | 空字符串嵌入返回非零 2560 维单位向量，调用方无法区分空输入 | 编码前未拒绝空文本，模型对空串仍产出向量 | 未修（记录） | `edge-media.md §2 D20`：`len=2560`、L2=1.0、RSS +76 KB | ≤ `ab3d8e6150f7` | 未修 |
| D63 | 中 | TTS 超长输入的上限在 HTTP 层不可达：5,500 字先撞 Paradee 失败（`No module named spacy`）返回 200 + `success:false`，永远走不到 `SpeechInputTooLong`；错误以 200 返回而非 4xx | 1,200 字上限只写在部署层 `Synthesize.process`，HTTP handler 未前置校验 | 已修：`speech.py:268` 在 handler 层先判 `SPEECH_MAX_CHARS=1200` 并返回 413 `SPEECH_INPUT_TOO_LONG`；v15 入包 | v19 实测 413 `SPEECH_INPUT_TOO_LONG`；v14 失败记录见 `edge-media.md §2 A2` | ≤ `ab3d8e6150f7` | **已修并实测通过（v19）** |

**台账附注**：C34 的 `S-OCR MODE=pdf` 默认 `PDF_NAME=a0_scan.pdf`，按矩阵原文测的是扫描件；这是矩阵脚本缺陷，不是产品缺陷。C27 的第二道防线在 v10 收尾补测才被触发；v12 未改该分支。此前“没有 `*.incompatible-*`”只是因为垃圾文件没有同步改哈希，第一道防线先命中了。

## 6. 评分（0–100，PASS 阈值 70）

评分采用第 3 节每类的证据；`user_score` 是外部用户愿意为该效果支付的分值，`developer_score` 是内部质量分值，最终分取二者较小值。J 类环境不具备，不计分；I 类已按 4/4 通过正式计分，平均分按 A–I、K 十类计算。

| 类别 | user_score | developer_score | 最终分 | 分档依据（具体证据） | 判定 |
|---|---:|---:|---:|---|---|
| A 安装与启动 | 90 | 86 | **86** | 7/7；401/Bearer/X-API-Key/?key+cookie/豁免/WebSocket 403/101 与两张浏览器截图均通过 | 通过 |
| B Web UI 渲染 | 94 | 90 | **90** | 6/6；verify 6/6；`pane=1`、`exceptions=0`；静态资源/manifest/404 均有原始码；截图可判读 | 通过 |
| C 聊天 | 92 | 88 | **88** | 9/9；三条 200；坏模型可读 JSON；C22 正确前置通过；10 条连续 153.4s、并发 3 条、中断恢复 | 通过 |
| D 嵌入与记忆 | 92 | 88 | **88** | 5/5；维度 2560、写入/检索/删除/重载；第二道防线生成 `*.incompatible-*` 并恢复 ntotal=6 | 通过 |
| E 语音 | 92 | 88 | **88** | 5/5；v12 2.88s、v10 2.72/12.16s，wave=ffprobe；错误/超长/黑洞可读；STT language 误报 | 通过 |
| F OCR 与文档解析 | 90 | 86 | **86** | 7/7；v11 135s 下 3/3、5 页 4/5；1×1/非 PDF/超时文案均通过；C34 矩阵默认值需修正 | 通过 |
| G 浏览器工具 | 88 | 84 | **84** | 4/4；宿主 Chrome 打开 `A0 Probe Title`、幂等；C42 `source=bundled` + warning、0.59s 仍可用；清 override source=system | 通过 |
| H 桌面/Xpra | 82 | 80 | **80** | 4/5；shadow 14500 + 本机 headless 隔离实例（Xvfb :120、`--tcp-auth=env`、正确 key 进 HTML5、canvas=1、红窗渲染）；C48 未执行；headless 无 WM/shell，根窗口黑 | 有条件通过 |
| I WPS MCP | 80 | 76 | **76** | 4/4；C49–C52 通过，connected=true、250 工具；C52 无 WPS 时返回结构化错误、不崩不挂死，记通过（有保留） | 通过（有保留） |
| J systemd 与重启 | — | — | **—** | 5/5 环境不具备；手工重启 10s 不能替代 systemd；无 unit、无 sudo、无 `/run/user/0` | 环境不具备 |
| K 资源与清理 | 92 | 88 | **88** | 4/4；单实例/端口/日志/OOM/磁盘；RSS 450.7–453.0 MB、fd 219→59 无持续泄漏 | 通过 |

- **平均分（A–I、K 十类）：85.4**（854/10）。
- **最低分：76（I）**；H 的 80 次低；I 已正式计入十类均值；J 不计分。
- **单类 PASS 情况**：A–I、K 共 10 类 ≥ 70；J 不计分。
- **全局结论：本机部署通过**（A/B/C/D/E/F/G/I/K 全通过，H 有条件通过——headless 技术路径通过、C48 待 760K，J 环境不具备）。剩余条件写入 §7，不再用“全量验收未通过”描述本机部署。

## 7. 未覆盖与风险

### 7.1 760K 失联导致的未做项

| 项 | 用例 | 影响 |
|---|---|---|
| GPU/CUDA | README 的 CUDA 扩展；无独立 CASE | 760K 的 RTX 3070 Ti 未验收；本机无 NVIDIA，`/dev/nvidia*` 不存在 |
| 无头 Xvfb 分支 | C48 | C47 已在本机隔离 headless 通过（§4.H）；C48 的清 sessions + 服务重启仍未验，目标机旧部署的 `:120` 只算历史证据 |
| root systemd | C53–C57 | 两个 unit 的 enabled/restart/crash/reboot/journal 均未验 |
| 真实重启自恢复 | C56 | 没有一次真正的 `sudo reboot` 后回连证据 |

### 7.2 本机环境不具备

- **无 NVIDIA GPU**：CUDA 扩展、`CUDA_VISIBLE_DEVICES=0`、GPU 内核挂载一律不判。
- **无宿主 WPS Office**：I 的 C52 记通过（有保留）；`wps_*` 文档工具 30 s 超时，不能做真实文档操作，但工具返回结构化、可读错误，不崩不挂死。MCP 启动、注册、250 工具已通过。
- **无 sudo**：systemd unit 安装/重启/崩溃拉起/reboot 无法执行；`/root/.local/share/flatpak` 不可读。

### 7.3 已知限制

1. `/api/health` 200 但 body 的 `error` 字段带 data 目录路径；监控若解析 `error` 会误报（`probe-models.md §P3-1`）。
2. 旧 Chrome profile 会继续显示空白 Settings，清 profile 后恢复；不是服务端回归（`local-v5-regression.md:v5 §P3`）。
3. `tmp/playwright/chromium-1228` 379 MB，本机有宿主 Chrome 时可清理；本轮未删（`probe-i-j-k.md §K.3`）。
4. STT 对中文音频报 `language='english'`，文本本身正确（`probe-models.md §P2-2`）。
5. `wps_check_connection` 无 WPS 时固定 30 s，文档工具 30–69.78 s；应作为前置条件写入文档（`probe-i-j-k.md §I.5`）。
6. 上游 `isError` 语义不一致：`wps_check_connection` 业务失败 `isError:false`，文档工具超时 `isError:true`（`probe-i-j-k.md §I.3`）。
7. `usr/settings.json` 的 WPS 配置含本机 `DISPLAY=:0.0`、`/run/user/1000`、`/run/flatpak/Xauthority`；换用户或换显示环境需要同步改（`local-v5-regression.md:最终补测 §5`）。
8. 当前 `bundles/agent-zero.flatpak` 是 2026-11-18 09:31 的 60,516,256 B / `8c8e1e535053…`（commit `053ed951355a`），已安装，Cuda/Wps 同为 v21；v20 包是 60,530,648 B / `5f8f1ee1c423…`（`21b0e23a`），v18 包是 60,318,144 B / `cad508317531…`（`be957363`），v14 包是 59,920,792 B / `e9fc289aef0b…`（`ab3d8e61`），v13 卸载→安装→启动演练用的是 59,937,144 B / `02d857bcf715…`（`4d0ccd2ceeb4`），不要拿历史包当最终证据。
9. fd 有请求期锯齿（峰值 219，受控聊天后回落到 59），RSS 450.7–453.0 MB，**没有持续泄漏**；建议降低健康轮询频率或在轻量端点后触发回收（`probe-stability.md §6.4`）。
10. C34 的矩阵脚本默认 `PDF_NAME=a0_scan.pdf`，按原文会测扫描件；判据需改成 `a0_probe.pdf`（本次已显式指定）。
11. headless 分支的桌面是裸 X 根窗口：bundle 没有窗口管理器/桌面 shell，Xpra 自带 greeter 因缺 `xpra.client.gui` 不能运行（D36 已关闭失败子进程）；文档窗口能力还受 bundle 无 LibreOffice 限制。`xpra.log` 仍有 `No module named 'xdg'`（菜单数据缺失），不影响 14500/HTML5。

### 7.4 上线后需要观察的三类

- **内存压力下的模型换页**：`OLLAMA_MAX_LOADED_MODELS=1`，62 GiB 内存，嵌入/语音/OCR 串行验收未遇压力；并发或长文档时需看 `ollama ps` 的 `size_vram` 与 swap。
- **长时间运行的 context 泄漏**：10 条连续、80k 字符、中断恢复、并发 3 条均无卡死；但 `/api/api_message` 不返回 `finish_reason`/`usage`，需继续观察多轮后的内存与队列。
- **Service Worker 缓存升级**：旧 profile 会缓存旧 `webui`，升级后可能出现设置空白；需要观察 `asset-bundle version` 是否随安装变化，以及清缓存后的恢复。

## 8. 交付物清单

`docs/manual-acceptance/a0lite-deploy/` 共 **75** 份 Markdown（含本报告）。§8.3 索引覆盖全部 75 份；脚本与截图另列。

### 8.1 仓库改动（`git status --short` 实际内容，03:14）

```text
 M README.md
 M docs/setup/host-ollama.md
 M flatpak/README.md
 M flatpak/a0flatpak/__init__.py
 M flatpak/a0flatpak/base_dir.py
 M flatpak/a0flatpak/browser.py
 M flatpak/a0flatpak/compat.py
 M flatpak/a0flatpak/desktop.py
 D flatpak/a0flatpak/health.py
 M flatpak/a0flatpak/ocr.py
 M flatpak/a0flatpak/packages.py
 M flatpak/a0flatpak/serve.py
 M flatpak/a0flatpak/speech.py
 M flatpak/a0flatpak/vector_store.py
 M flatpak/agent-zero.sh
 M flatpak/org.agentzero.AgentZero.yml
 M flatpak/requirements-flatpak.txt
 M flatpak/wps-mcp-config.json
 M scripts/build.sh
?? .herd/
?? docs/manual-acceptance/
```

共 21 行：19 个已跟踪文件（18 改、1 删）+ 2 个未跟踪目录。`README.md` 与 `docs/setup/host-ollama.md` 不在 `build-run.md §2` 的构建前改动清单里；v13 镜像按 D24 排除 `docs/manual-acceptance/`，保留 `docs/setup/host-ollama.md`（断言计数 1）。

上表是 03:14 的快照。此后本轮又新增 6 份验收文档（`systemd-static-review.md` 已在表内）、`760k-rescue-kit/` 与 3 个脚本，均落在已列出的未跟踪目录或 `scripts/` 下，见 §8.3/§8.4。

### 8.2 二十二轮构建（commit / sha256）

| 轮次 | commit（短） | bundle sha256 | 大小 | 说明 |
|---|---|---|---:|---|
| v1 | `44c0ae8315` | —（旧基线，未保留 bundle） | — | 接手时的已安装版本，Installed Size 128.1 MB |
| v2 | `169f5e09e5` | `6ca80d7d98df968aeb6c13d1e1c274c0a8098e1bd25fba5bd5cca462c0f564b8` | 59,533,584 | 首次成功构建；此前 `--repo` 失败一次 |
| v3 | `a33e50bd24` | `2a2fcf91eaffaca8d7c78a6692de81271acb557d93974845d8ff01f848035761` | 59,537,424 | D1/D4/D2/D6 + P1/P3/P4 |
| v4 | `475e157782` | `27bf8a3526a9...`（build-run 只留前 12 位） | 59,535,696 | `.env` 遮蔽 + Chrome 路径 |
| v5 | `a8f932128c` | `ee79e1b7c595...` | 59,538,616 | `webui` seed 修复 |
| v6 | `1e0f41ccec` | `62e6228d2904...` | 59,709,032 | jQuery 实体化 + 运行树清理 |
| v7 | `1ddcd34f7b` | `29d7510f9aa1fb5be89f00f426f5577171f72995ab6cfa1c67f80b8eca84def2` | 59,711,152 | venv 戳 + OCR 语义 + WPS 桥接 |
| v8 | `0e6c508202` | `b74e6d9f3a06ff201278130a045ad8907ac99286c1870cb6a9b0fa24d8a8af3f` | 59,715,960 | 去掉 `--mmap=no` |
| v9 | `4d4e00e7a9` | `fee1fa6745d2aae2b7a410cc2bc13db7173b56e36e2b260f4baea7d4da26a2c9` | 59,717,232 | `X_OK` 校验 + 文档校正 |
| v10 | `7a55c085a2` | `bb2afeed6ca798f842fe7a3dacb01408e10438a49bf4b65d0119e63eb84b375e` | 59,724,976 | WAV 头 + 旧索引 + 语音错误/超长 |
| v11 | `d3731ae0e9` | `b67933cd35970bfbf9794063dbb66c92a928d173341cf9bf2292dd64f3a0af6d` | 59,727,920 | OCR 预算 135s + 边界文案 |
| v12 | `53ae0c0dc2` | `378765852b53799c7c04545ebe5dda77a80053b0dba90232e28ee4586da4b7d1` | 59,928,208 | 无宿主 Chrome 降级 warning |
| v13 | `4d0ccd2ceeb4` | `02d857bcf715364a2dd6983a3b69ce626c07ab59682032877b1d56117b1d4238` | 59,937,144 | 移除 28 份验收文档（D24） |
| v14 | `ab3d8e6150f7` | `e9fc289aef0b0d50cb3a22fb672b4ec3bb5f4aea173e51513993c50b6be40f73` | 59,920,792 | V1–V4（D38–D41）+ headless 修复 |
| v15 | `72842c7a` | — | — | M1 根因修复、plugin_guard 自愈、F1/F2/F3 首版；security 9/12 |
| v16 | `0eda9fe1` | `4d88526b80d2fd739bac9e85036d849a8961d5cf318415c03373240996f82faf` | 60,536,280 | `sensitive_paths` 改 live 模块 patch；12/12 |
| v17 | `d8c5b96a` | — | 60,475,072 | `_TeeLog` 的 `fileno` + `A0_COMMIT_TIME`；V12 未赶上 |
| v18 | `be957363` | `cad5083175319481b8c104e0bc9062675dcc7aeb4f93f1de4521a6f2f4f8a8be` | 60,318,144 | 四键 build-info + V12 |
| v19 | `a9aa6ebf` | — | — | D56/D57/D58/D63 修复入包；FD 高水位复测 |
| v20 | `21b0e23a` | `5f8f1ee1c423726c7da1d41215a939d7547602da5c4a401cabfdf57e2c45701d` | 60,530,648 | 同补丁集重建（deps tarball 重打） |
| v21 | `053ed951` | `8c8e1e535053265afe1a7f2effa368aab165d12ce683004c9fe3a7e56483d218` | 60,516,256 | `_TeeLog` 落盘 + MCP 锁 600 s |
| v22 | `d7749980` | `97615832fa8ee5b80a8962ffc3840dca94a7e76b4a8734f4b3036a2a12412bc7` | 60,506,136 | AMD 780M iGPU Vulkan（`OLLAMA_IGPU_ENABLE=1`）；最终交付基线 |

说明：v4–v6 的 build-run 只保留了 sha256 前 12 位，表中按原文照录；其余为完整值。v1 是接手基线，不算本轮重建；v2–v22 共 21 次构建，加上基线合计 22 个版本；v15/v17/v19 的 bundle sha256 未留存（bundle 已被后续构建覆盖），记 `—`。v10 还产生过一个作废的 `e88900a30c`（文案字面量问题），被 `7a55c085a2` 覆盖。v12 之后先有 03:00 的 `506f6a0a`（60,272,544 B / `1ab3f909…`，未安装），随后 v13 `4d0ccd2c` 于 03:11 定版并安装；v14 于 04:44 安装并重启；v18 于 06:2x 安装；v20 于 07:5x 定版并安装，v21 于 09:3x、v22 于 10:0x 定版并安装。三件套（含 v22 Cuda/Wps）的 commit/sha256/大小/mtime 见 §2.4。

### 8.3 报告与证据索引

| 路径 | 内容 |
|---|---|
| `docs/manual-acceptance/a0lite-deploy/report.md` | 本报告 |
| `test-matrix.md` | 61 条用例、可复用脚本、评分规则 |
| `test-coverage.md` | 61 条的证据映射（早期基线，需按本报告更新） |
| `probe-chat.md` | C14–C22 聊天链路 |
| `probe-stability.md` | 10 条连续、80k 字符、并发、中断、fd/RSS |
| `probe-models.md` | C23–C32 嵌入、记忆、语音 |
| `probe-pdf.md` | OCR 预算、页数上限、边界文案 |
| `probe-browser.md` | C40–C43 浏览器 |
| `probe-i-j-k.md` | C48–C61 WPS、systemd、资源 |
| `systemd-static-review.md` | C53–C57 静态复核、unit 验证、安装器幂等性 |
| `760K-entrypoints.md` | 760K 三条入口（frpc 12022、frps 公网、局域网 22）逐条探测，全部不可用的原始输出 |
| `target-script-review.md` | `test-760k-acceptance.sh` 十项安全审查，R1–R9 缺陷与修复 |
| `760K-handover.md` | 760K 现场恢复与交付部署交接单：三种恢复情形、部署顺序、验收入口 |
| `bundle-base-check.md` | Cuda/Wps 扩展的 base 是 ref 不是 commit，不必随主包重建的判定与依据 |
| `v14-fix-run.md` | V1–V4（D38–D41）修复运行记录：产物哈希、方案与实际的 6 处差异、四条复验原始输出、回归；含版本号语义 |
| `760k-rescue-kit/` | 760K 现场救援包：`01-diagnose.sh`、`02-fix-boot.sh`、`03-deploy.sh`、`README.md`、`make-kit.sh` 与 tar.gz；三个大包不入包 |
| `local-v5-regression.md` | v5–v13 回归；v13 交付验证在文末 |
| `local-first-boot.md` | 首次启动基线、P1–P7 缺陷 |
| `build-run.md` | 十三轮构建、镜像断言、产物哈希 |
| `contract-audit.md` / `fix-drafts.md` / `fix-compat.md` / `fix-xpra-mmap.md` | 契约审查与修复依据 |
| `kernel-gpu-migration.md` / `760K-connectivity-hunt.md` | 760K 换内核与失联取证 |
| `HANDOFF.md` | 交付指引：状态、三件套、回滚、重建、760K 回连步骤、已知限制、禁忌 |
| `final-state.md` | v20 最终状态清点：实例/端口/health/三件套/磁盘/清理/760K |
| `final-smoke.md` | 交付前 9 项 smoke（全绿） |
| `worktree-changes.md` | 36 项未提交改动的逐条归类（对应 D 号/功能） |
| `visual-final.md` | v14→v19 五轮视觉巡检合并总表，12 页 + 六项 V |
| `fd-leak-root-cause.md` | K06：FD 高水位非泄漏的根因分析（v18/v19 定向复现） |
| `stt-pinyin-root-cause.md` | D58 根因（`language: en` 默认值）与 Ollama 对照实验 |
| `v19-fix-plan.md` | D56/D57/D58/D63 的修复方案与复验命令 |
| `v21-fix-run.md` | v21 构建与部署验收：三件套哈希、四项复验（MCP 5/5、stderr 落盘、`_TeeLog`、250 工具）、12/12 与 6/6 回归 |
| `amd-gpu-inventory.md` | AMD Radeon 780M 加速路径清点：Vulkan 设备、ROCm 不可用、Ollama 后端库与隔离实验 |
| `vulkan-recon.md` | Vulkan 侦察与 CPU 基线：RADV PHOENIX 枚举、Ollama 丢弃核显日志、32.27 tps 基线、可行性判定 |
| `v22-vulkan-fix.md` | v22 构建与 Vulkan 验证：`agent-zero.sh` 10 行改动、三件套哈希、`size_vram`/日志/tps、1.81×、回退 |
| `security-fix-plan.md` | S1–S3 安全修复方案与 `--nofilesystem` 实测 |
| `security-retest-v20.md` | v20 安全项复测原始输出（凭据遮蔽、8 目录、`test -r`） |
| `edge-files-retest-v20.md` | v20 文件写边界与错误语义复测（403/404/409 逐条） |
| `edge-retest-v20.md` | v20 聊天/语音/OCR/嵌入复测（413、中文 STT、OCR 尾注、截断 PDF） |
| `browser-retest-v20.md` | v20 浏览器复测：B1–B6 的 15 s 导航预算、DNS 冒泡、状态码、RSS 归零、profile 删除，附与 v14 对照 |
| `mcp-retest-v20.md` | v20 MCP 复测：MT1 跨会话缓存命中、MT2 并发串行与 `MCP_BUSY`、MT9 stderr 惰性落盘与 `note()` 待构建 |
| `security-audit.md` | 安全边界测试（S1–S6）原始证据 |
| `mcp-tools-audit.md` | WPS MCP 250 工具逐个审计（只读实测） |
| `mcp-fix-plan.md` | MT1/MT2 MCP 会话与端口修复方案 |
| `browser-deep.md` | 浏览器工具深度测试（B1–B6） |
| `browser-fix-plan.md` | 浏览器缺陷 B1/B2/B3/B4/B6 修复方案 |
| `edge-chat.md` | 聊天/消息 API 边界与压力（空消息、超长、多轮） |
| `edge-files.md` | 文件浏览器与记忆写边界实测（`/etc`、`~/.ssh`） |
| `edge-media.md` | 语音/OCR/嵌入边界实测（M1–M9 原始记录） |
| `long-session.md` | v14 长会话 79 轮实测 |
| `long-session-v16.md` | v16 长会话 65/100 轮（外部重建中断，记 L1） |
| `long-session-v18.md` | v18 长会话与上下文恢复实测 |
| `soak-v14.md` | v14 稳定性 soak（RSS +58.6%，作为对照） |
| `soak-v18.md` | v18 稳定性 soak（31 分钟，RSS +3.4%、FD +61） |
| `perf-baseline.md` | 首屏/视图/资源/包体性能基线 |
| `visual-audit.md` | 早期视觉巡检（运行实例） |
| `visual-audit-v16.md` | v16 视觉巡检（`0eda9fe1`） |
| `visual-audit-v18.md` | v18 视觉验收（12 页，`be957363`） |
| `visual-audit-v19.md` | v19 视觉验收（desktop 断言口径修正） |
| `V12-root-cause.md` | V12 根因与修复（desktop session `NameError`） |
| `v15-v16-fix-run.md` | v15–v18 修复运行记录与六条复验原始输出 |
| `v16-state-snapshot.md` | v16 安装后状态快照（已过期，历史记录） |
| `m1-speech-fix-plan.md` | M1–M4 语音修复方案（413 上限、损坏 PDF 抛错） |
| `fix-plan-v.md` | V1–V4 修复方案（设计稿） |
| `ui-rootcause.md` | Settings/Projects 模态框空白根因与最小修复 |
| `models-inventory.md` | Models 扩展盘点（`xiaomi-ocr` 加载路径） |
| `wps-mcp.md` | WPS MCP 扩展验收（注册、250 工具） |
| `upstream.md` | 上游源码体检（版本、依赖、构建面） |
| `functional-probes.md` | 功能探针清单（可复制执行） |
| `build-preheat.md` | 构建前预热与依赖预取，缩短构建窗口 |
| `local-host-prep.md` | 本机部署前准备（环境、依赖、存储） |
| `target-prep.md` | 760K 部署前准备（系统、依赖、数据保留） |
| `recon-builder.md` | 构建机事实侦察（CPU/内存/磁盘/网络） |
| `recon-target.md` | 760K 目标机侦察（硬件/内核/GPU/入口） |
| `~/a0-shots/verify-ui-fix-settings.png` | Settings 面板 1440×817 |
| `~/a0-shots/91-desktop-v12.png` | v12 桌面 2880×1800 |
| `~/a0-shots/80-browser-tool.png` | 浏览器工具 1024×768 |
| `~/a0-shots/a1-auth-query-key.png` / `a2-auth-no-key.png` | A 类 `?key` 与无 key 截图 |
| `~/a0-shots/01-home-233642.png` / `03-answered.png` | 首页与聊天回答 |
| `~/a0-shots/19-settings-populated.png` / `20-settings-models.png` | 设置与模型页 |
| `~/a0-shots/tts-v12.wav` | v12 TTS 证据（138,284 B / 2.88 s） |
| `~/a0-shots/tts-v10-final.wav` / `tts-v10-longer.wav` | v10 TTS 证据（130,604 B / 583,724 B） |
| `~/a0-shots/tts-probe.wav` / `tts-long300.wav` | v8 旧头对照（176,684 B / 3,225,644 B） |
| `~/a0-shots/headless-14500-2026-11-17T20-15-32-936Z.png` | 本机 headless 14500 密码提示（canvases=0） |
| `~/a0-shots/headless-desktop-2026-11-17T20-15-44-970Z.png` | 本机 headless 正确密码后 canvas=1、红测试窗 |
| `~/a0-shots/headless-evidence-20261118-041603.log` | 本机 headless 原始断言输出 |

### 8.4 本轮脚本

| 路径 | 用途 |
|---|---|
| `scripts/deploy-760k.sh` | 760K 一键部署：预检连通与磁盘、按主包→Cuda→Wps 装入、起服务、跑 health 与 verify 断言，任一失败即停 |
| `scripts/test-760k-acceptance.sh` | 760K 端上验收执行器：A1–A4、C44–C57、E1–E3 等只能目标机跑的用例；破坏性分支与 reboot 需显式开关 |
| `scripts/test-760k-acceptance-selftest.sh` | 上者的故障注入自测：临时 `PATH` 前置 fake `systemctl`/`curl`/`flatpak`/`sudo`/`reboot`，不触真机 |

## 9. 本轮（v14 → v20）修复总结

| 轮次 | 缺陷数 | 关键修复 | 三件套 sha256 前缀（主 / Cuda / Wps） |
|---|---:|---|---|
| v15 `72842c7a` | 4 | D42 插件补丁守卫首版、D43 `cp` 幂等 + 请求前自愈、D48/D49 浏览器超时与生命周期 | `72842c7a` / — / — |
| v16 `0eda9fe1` | 4 | D44/D45/D46 文件 API 写边界与错误脱敏、D47 八条 `nofilesystem`（`--talk-name` 保留） | `4d88526b` / `6dd2ef68` / `818feb21` |
| v17 `d8c5b96a` | 4 | D50 `_TeeLog.fileno`、D53 `A0_COMMIT_TIME` 分离、D54 MCP 串行化、D55 缓存本地化 | `d8c5b96a` / — / — |
| v18 `be957363` | 2 | D51 desktop 延迟 import、D52 health 与 session 同源；四键 build-info 全量重打 | `cad50831` / `5a1b5c41` / `e84bbed0` |
| v19 `a9aa6ebf` | 3 | D56 截断 PDF 抛错、D57 尾注写明 `A0_OCR_MAX_PAGES`、D58 STT 默认 `language` 改空串；12 页视觉验收 | `a9aa6ebf` / — / — |
| v20 `21b0e23a` | D50 确认 + MT1/MT2 实测 | 同补丁集重建（deps tarball 重打）；D56 复验通过 | `5f8f1ee1` / `e66e8d73` / `4c451457` |
| v21 `053ed951` | MT9 落盘 + D54 锁 600 s（实测） | `_TeeLog` 写 `mcp-wps_office.log`、MCP 锁 120→600 s（5 并发 5/5，无 `MCP_BUSY`）、250 工具；12/12 与 6/6 回归 | `8c8e1e53` / `e5c12af3` / `63b51ce2` |

- **为什么连做四轮**：v15 的 12 项安全断言只过 9 项——守卫打在 `/app` 的 handler 副本上，运行实例读的却是 `$DATA/api/*`，另外 3 项静默未生效；v16 改按 live 模块 patch 才到 12/12。v17 出包时 V12（desktop 延迟 import）在 06:10:47 才落盘，晚于 06:09 的主包；v18 重新 `cp -a` 全量出包，是唯一同时含插件守卫、安全项、`_TeeLog`、四键 build-info 与 V12 的版本。
- **D42/D43 同一根因**：插件命名空间被 `purge_namespace("plugins")` 换新，补丁留在旧对象，失效时没有任何信号。修一次 `plugin_guard` 覆盖 6 个受影响的 `apply()`（TTS、STT、文件 API、浏览器、desktop、MCP）；之后新增补丁只需 `register`/`register_module`。
- **已修并实测通过的 4 条**：D56（v20，0.095 s 抛 `damaged page tree`）、D57（v19，尾注 `A0_OCR_MAX_PAGES=4`）、D58（v19，中文 3/3 汉字）、D63（v19，413 `SPEECH_INPUT_TOO_LONG`）。此前的失败记录分别来自 v14/v18，改判依据见 §3.1。
- **v21 实测（09:30–09:39）**：MT9 的 `note()` 与 `_TeeLog` 落盘成立（`usr/logs/mcp-wps_office.log` 首行 `[2026-11-18T01:39:27.160Z] session start: /usr/bin/flatpak-spawn …`，`_TeeLog` AttributeError 0 次）；MCP 锁由 120 s 改为 600 s，并发 5 个 `check_connection` 依次 32.3/64.6/96.9/129.2/161.5 s 全部返回，无 `MCP_BUSY`；250 工具仍注册；`verify-security-fix.sh` 12/12、`verify-ui-fix.sh` 6/6。原始输出见 `v21-fix-run.md`。
- **仍未修的 4 条 + 2 项**：D59（空消息返回 200）、D60（低分辨率 OCR 无拒识）、D61（STT 无静音判定）、D62（空串嵌入静默编码）；另两项未登记 D 编号——D47 的 `--talk-name=org.freedesktop.Flatpak`（WPS MCP 依赖，只能靠 8 条 `nofilesystem` 收窄暴露面）、`A0_AUTH_KEY` 默认空（本机任意进程可取 CSRF 后调 `/api/message`）。
- **口径**：本轮只改打包层 `flatpak/`，未改上游 checkout、未 commit；C01–C61 的判定与 85.4 不变，新增 C62–C77 独立列在 §3.1。

---

## 10. 最终交付判定

| 项 | 结论 |
|---|---|
| 基线 | v22 `d7749980`，主包 60,506,136 B / `97615832`；Cuda `b0633fcb`（bundle `1a5196a4`）；Wps `790cee09`（bundle `3ddbd350`） |
| 功能 | A/B/C/D/E/F/G/I/K 全通过；H 有条件通过（headless 技术路径通过，C48 记未执行）；J 环境不具备（760K 已弃用）；AMD Radeon 780M Vulkan 加速 1.81× |
| 缺陷 | 台账 63 行（D01–D63）：**58 条已修**（含 4 条 v19/v20 实测通过）+ **1 条非缺陷**（D19，已排除）+ **4 条未修：D59–D62**；另有 2 项无 D 号（`--talk-name`、`A0_AUTH_KEY`） |
| 新增用例 | C62–C77：13 通过 / 3 失败 / 0 待复验（§3.1） |
| 判定 | **可交付**；未修项与已知限制均不阻塞本机部署，见下 |

- **不阻塞交付的已知限制**：`--talk-name=org.freedesktop.Flatpak`（WPS MCP 依赖，已用 8 条 `nofilesystem` 遮蔽凭据目录）；`A0_AUTH_KEY` 默认空（本机 CSRF 可取，需部署侧设 key）；V5/V6/V7（上游 speech 模型选择、models/mcp 页面文案，不改功能）；D59–D62（空消息、低分辨率 OCR、静音 STT、空串嵌入）；MCP 锁 `LOCK_TIMEOUT_SECONDS=600`（v21 实测 5 并发 5/5 返回、无 `MCP_BUSY`；单次 30–70 s，尾部等待仍存在）；K06（FD 高水位，非泄漏，空闲回落 62，峰值 171 < 1024）。
- **760K 目标机已弃用（2026-11-18）**：换内核后 10.5 小时未回连，且无带外恢复手段；J 类（C53–C57 systemd）与 CUDA 可见性（A1–A4）不再计划验收，H 的 C48 记未执行。本机改为 AMD Vulkan 路径，D42–D63 缺陷台账与 61 条用例结论不变。

## 11. v20 复测（修复验证）

| 缺陷 | v14 现象 | v20 复测 | 判定 |
|---|---|---|---|
| D44 写操作无边界 | `/etc`、`$HOME` 可写可删 | upload→`/etc` 403、→`$HOME` 403、→`/tmp` 403、→`/a0` 200；delete `~/.bashrc` 403、rename `/etc/hostname` 403；文件原样未动 | **已修并实测** |
| D45 500+traceback | 下载不存在文件 500 + 完整栈 | 404 `NOT_FOUND`，90 B JSON，`grep 'Traceback\|File "'` = 0 | **已修并实测** |
| D46 递归删除无确认 | 非空目录直接 rmtree | 409 `NON_EMPTY_DIRECTORY`；加 `recursive:true` 才 200 | **已修并实测** |
| D47 凭据目录可读 | `~/.ssh/id_ed25519` 可读 | 8 条 `!~` 在 metadata；沙盒内 8 目录 `ls -A` 全 0；`test -r` BLOCKED | **已修并实测**（`--talk-name` 仍存） |
| D56 截断 PDF 静默降级 | `ok=true` + 白跑 45 s | **0.063 s** `ValueError: PDF could not be read: damaged page tree…`，无重复前缀 | **已修并实测** |
| D57 OCR 预算文案 | 一律写 timeout | `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).` | **已修并实测** |
| D58 STT 拼音 | 3/3 拼音 | 中文 3/3 出汉字（2/3 字面正确）、英文正确、`language=""` | **已修并实测**（有质量保留） |
| D63 TTS 超长 200 | 5,500 字 200 + spacy 错 | **413** `SPEECH_INPUT_TOO_LONG`，0.018 s | **已修并实测** |

1. **读仍全盘开放**（`/etc/passwd` 200、download 200），只有 8 个凭据目录 403——这是设计取舍，不是遗漏：Agent Zero 的定位就是在真实机器上工作，写边界与凭据遮蔽才是安全面。
2. **D59/D60/D62 确认仍未修**：空消息 200、低分辨率图 `ok=true` 幻觉、空串嵌入非零向量；三者与本次复测的修复项无关，不因复测而改判。
3. **新发现（质量观察，不记缺陷）**：D58 修好后中文识别 3 次里 1 次字面错误（`这是一次震温热营试飞的测试。` vs 原句 `这是验收探针，请合成语音。`），属模型能力，不是语言参数问题；因此 C72 记「通过（准确率 2/3）」。

## 12. v20 浏览器与 MCP 复测

原始输出见 `browser-retest-v20.md`（55 行）与 `mcp-retest-v20.md`（49 行）；均在已安装 v20 上只读实测，未构建、未重启。

| 项 | 缺陷 | v14 | v20 实测 | 判定 |
|---|---|---|---|---|
| B1 | 导航无上限 | 45 s 页 45.1 s 挂死、600 s 页 >60 s | 20 s 慢页 **15,483 ms**、45 s 慢页 **15,083 ms**，均 `{"error":"TIMEOUT"}`（`Page.goto: Timeout 15000ms`） | **已修**：15 s 导航预算 |
| B2 | DNS 失败不冒泡 | `open` 成功 + 仅 stderr warning | **1,740 ms** 返回 `{"error":"NAVIGATION_FAILED","detail":"…net::ERR_NAME_NOT_RESOLVED…"}` | **已修** |
| B3 | 状态码不透出 | 无 `status` 字段 | `/404` → `"status":404`（92 ms）；`example.com` → `"status":200`（1,277 ms） | **已修** |
| B4 | 关会话不释放 | 231,780→228,824 KB 不回落 | 3 会话 RSS 247,748 KB；`close_all` 后 240,176 KB（Chrome 仍在，语义如此）；逐个 `close_runtime` 后 **0 进程、RSS 0** | **已修**（`close_all` 语义不变） |
| B5 | 文档预期缺失 | `browser_agent` 不存在 | 同 | 文档问题，未变 |
| B6 | profile 只增不减 | 3.0M→40M | `$DATA/tmp/browser/sessions/shared` 在 `close_runtime` 后真被删除（`E_PROFILE_EXISTS False`、`sessions` 列表 `[]`） | **已修** |

| 项 | 缺陷 | v14 | v20 实测 | 判定 |
|---|---|---|---|---|
| MT1 | 缓存不跨调用 | 写入后读回「缓存键不存在、availableKeys:[]」 | `cache_data` 后**紧接着另一次 `call_tool`** 的 `get_cached_data` 命中 `{"success":true,"data":"retest-value","cachedAt":"…"}` | **已修** |
| MT2 | 并发无串行化 | 5 并发中 4 个静默超时 | 5 个依次在 32.32 / 64.64 / 96.95 / 129.26 s 完成；第 5 个在 **120.01 s** 返回 `MCP_BUSY` | **已修**（无静默超时） |
| MT9 | stderr 不落盘 | `_TeeLog` 报 `fileno` AttributeError | `usr/logs/` 仅 `a0flatpak.log`，无 `mcp-wps_office.log`（惰性建文件 + bun 全程无 stderr）；AttributeError **0 次**；源码已补 `note()` | **部分**：待 v21 构建 |

`browser_guard.py`（12,602 B，`__init__.py` 104–106 行调用）与 `mcp_cache` 均已实测生效：B1/B2/B3/B4/B6 与 MT1/MT2 全部从 v14 旧行为切到新行为，D42 未复发（`_a0flatpak_patched` 三处均 True）；`mcp_servers_status` 为 `connected:true`、`tool_count:250`。MT9 的会话头 `note()` 已在 v21 构建后实测通过（`usr/logs/mcp-wps_office.log` 首行即 session start，见 §9）。

## 13. 本机 AMD Vulkan 加速（v22）

760K 弃用后，交付目标改为本机：Ryzen 9 7940HS + Radeon 780M 核显。

**根因**：Ollama 0.40.13 自带 `libggml-vulkan.so`，`vulkaninfo` 枚举到 `AMD Radeon 780M Graphics (RADV PHOENIX)`（硬件 RADV，非 llvmpipe），但 Ollama 默认丢弃核显，日志原文 `dropping integrated GPU; to enable, set OLLAMA_IGPU_ENABLE=1`。

**修复**：`flatpak/agent-zero.sh` 在 Ollama 启动前加 10 行——`export OLLAMA_IGPU_ENABLE=1` 与 `GGML_VK_VISIBLE_DEVICES=0`，仅在未设置时赋值；`A0_OLLAMA_IGPU=0` 可关闭。

**验证**（原始输出 `v22-vulkan-fix.md`、`vulkan-recon.md`）：

| 项 | CPU（v21） | Vulkan（v22） |
|---|---|---|
| `size_vram` lfm3-omni | 0 | 1.82 GiB（1,958,341,507 B） |
| `size_vram` qwen3-embedding | 0 | 7.25 GiB（7,779,836,231 B） |
| tps（三次 / 中位） | 32.27 / 31.52 / 33.92 → **32.27** | 58.36 / 57.30 / 67.03 → **58.36** |
| 加速比 | — | **1.81×**（均值比 1.89×） |

日志出现 `load_backend: loaded Vulkan backend from /app/share/agent-zero/models/lib/ollama/vulkan/libggml-vulkan.so` 与 `library=Vulkan name=Vulkan0 … type=iGPU`。回归 `verify-security-fix.sh --expect new` 12/12。

**回退**：`flatpak run --env=A0_OLLAMA_IGPU=0 …` 临时关闭；`flatpak override --user --env=A0_OLLAMA_IGPU=0 …` 持久关闭；或重装 v21（`~/a0-local-backup/bundles-v21/`）。

---

**一句话收束**：v22 交付包可部署——已装入并重启到 `d7749980`、health 200、`verify-security-fix.sh` 12/12、`verify-ui-fix.sh` 6/6、AMD Radeon 780M 经 Vulkan 推理（`size_vram` 1.82/7.25 GiB，tps 32.27 → 58.36，1.81×）、MCP 锁 600 s 下 5 并发 5/5、卸载不删数据（空安装演练由 v13 验证，安装路径相同）；台账 63 行中 58 条已修（D56–D58、D63 在 v19/v20 实测通过）、1 条非缺陷（D19）、4 条未修（D59–D62），`--talk-name`、`A0_AUTH_KEY` 仍为已知缺口且不阻塞本机交付；A/B/C/D/E/F/G/I/K 全通过，H 的 shadow 与 headless 技术路径通过、C48（清 sessions 服务重启）记未执行，J 因无 systemd/无 sudo 与 760K 弃用记环境不具备；宿主无 WPS Office 只限制文档操作，不否定 MCP 启动、注册与 250 工具。
