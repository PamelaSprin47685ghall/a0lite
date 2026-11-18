# V1–V4 修复运行记录（v14）

- 时间：2026-11-18 04:31–04:50 CST。
- 基线：运行进程 `4d0ccd2ceeb4`，安装包 `5631f3ab75d7`。
- 新包：`ab3d8e6150f78872c3221c0304477d5adb4746c1be92f0a0b98f78220bf1ac7d`，安装后已重启到该 commit。
- 构建：`A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`，**623 s**，日志 `~/a0-local-backup/build-v14-0431.log`。

## 产物

| 包 | mtime | size | sha256 |
|---|---|---:|---|
| `agent-zero.flatpak` | 04:33:23 | 59,920,792 | `e9fc289aef0b0d50cb3a22fb672b4ec3bb5f4aea173e51513993c50b6be40f73` |
| `agent-zero-cuda.flatpak` | 04:41:04 | 859,752,760 | `39c3f403f9926907ed6d3945a715cf3ea5aa19ea92536b451e1f11d820f10592` |
| `agent-zero-wps.flatpak` | 04:42:20 | 50,210,888 | `1971d99f7c16afa48e12030c3612c942d3ee88bcf01f652943ec9786df186bf7` |

## 方案与实际的差异

1. **V1 版本来源**：方案 `git -C "$A0_SRC" describe`。实际 `$A0_SRC` 的 `flatpak/` 是复制进来的层，`git describe` 必须对打包仓库 `$HERE` 跑。已改为 `$HERE`。
2. **V1 自更新错误有两条路径**：只改 `settings-store.refreshUpdateStatus` 只能挡住“打开设置”。`self-update-store.refresh()` 还会被模态框 `x-init`、Refresh 按钮和重启收尾触发。patch 在两处都加了守卫。
3. **V2 只改 `cp` 修不了旧数据**：`~/.var/app` 已有 1.4 GB 用户树，7 个顶层目录的 mtime 已经是 epoch；`conf/agents/...` 只在首次 seed，`prompts` 用 `-n`，都不会重写。新增 `refresh_dir_mtime` 只 touch 仍 <2000 年的顶层目录，文件 mtime 不动。
4. **V3 签名**：`resize_display` 是 keyword-only；两处桌面调用和 `interactive_view` 的第三处调用全用 kwargs，`**kwargs` 包装成立。方案漏了 `max_width`/`max_height` 的转发，且第三处还传 `settle_seconds=0`；实现保留前两个，忽略 settle。
5. **V4 行号**：`refreshUpdateStatus` 实际在 `settings-store.js:553`，方案写 551；`right-canvas.css` 确实 402 行，末尾 `}`，但 patch 用 3 行上下文而非 `@@ -402,1`。`flatpak/patches/` 原本不存在，已新建。
6. **V2 实验**：`cp -a` 保留 epoch 0；`cp -a --no-preserve=timestamps` 落当前时间（1794947440）。GNU cp 行为与预期一致。

## 改动文件（均对应 V1–V4）

- `flatpak/a0flatpak/version.py`（新）— V1，用 build-info 回答 `get_git_info()`。
- `flatpak/a0flatpak/__init__.py` — V1，`base_dir.apply()` 后调用 `version.apply()`。
- `scripts/build.sh` — V1，构建前写 `A0_BUILD_VERSION/COMMIT/TIME`，describe 对 `$HERE`。
- `flatpak/org.agentzero.AgentZero.yml` — V1/V4，安装 `.a0-build-info` 并 `patch -p1` 应用 UI 补丁。
- `flatpak/agent-zero.sh` — V1 source build-info；V2 四处 `cp -a --no-preserve=timestamps` 与 `refresh_dir_mtime`。
- `flatpak/a0flatpak/desktop.py` — V3，`_patch_resize_display`，保留 `XPRA_LOG_TO_FILE=1` 与 `XPRA_DESKTOP_GREETER=0`。
- `flatpak/patches/flatpak-ui.patch`（新）— V4 media query；V1 `data-a0-flatpak` 标记与两处 self-update 守卫。

## 四条复验（原始输出）

**V1**：`/api/health` → `{"gitinfo":{"branch":"flatpak","commit_hash":"058582f","commit_time":"2026-11-17T20:31:57Z","tag":"058582f-dirty","short_tag":"058582f-dirty","version":"058582f-dirty"},"error":null}`。首页页脚 `Version 058582f-dirty 2026-11-17T20:31:57Z`；首页 console error 0，设置页 console error 0，`self_update_get` 请求 0。截图 `~/a0-shots/v14/01-home-version.png`。

**V2**：`GET /api/get_work_dir_files?path=%2Fa0` 12 项 modified 全部 ≥ 2026-11-01：`agents/api/conf/extensions/plugins/prompts/webui` 为 04:42:42，`knowledge` 23:53、`usr` 02:09、`tmp` 01:24、`venv` 11-01、`ollama.log` 04:46。`find -maxdepth 1 ! -newermt 2020-01-01` 为空。`usr/memory` 仍为 01:38:53，未被改动。截图 `~/a0-shots/v14/02-file-browser.png`。

**V3**：`700x800` → 200 `{"ok":true,"width":700,"height":800,"resized":false,"note":"xrandr is not installed; the display keeps its mode."}`；`1118x770`、`647x852` 同为 200 且 `resized:false`。截图 `~/a0-shots/v14/03-desktop.png`（Xfwm4，canvas=1）。

**V4**：390×844 下 `.right-canvas-rail` 的 `display=none`，`innerWidth=390`、`scrollWidth=390`，无横向滚动；9 条真实聊天气泡与 rail 重叠 0；console error 0。截图 `~/a0-shots/v14/04-mobile.png`。

## 回归

- `A0_DEBUG_PORT=9224 ~/a0-local-backup/verify-ui-fix.sh ab3d8e61`：**PASS 6/6**（commit、asset bundle、runtime webui 0 差异、welcome slot 1/1015 行、DOM exceptions=0、截图）。
- 聊天：`POST /api/message` 200，`{"message":"pong"}`，完整回答 8.4 s（不是 3 s）；UI `globalThis.sendMessage` 走 `/message_async`，ack **60 ms**，`pong` 在 0.5 s 内出现在 DOM。
- 嵌入：`OllamaEmbeddings / qwen3-embedding:4b-q4_K_M`，`len=2560`。
- OCR：`_vision_markdown` 返回 39 字符，内容 `Agent Zero OCR 测试 2026 / 第二行文字，用于验证视觉解析。`，耗时约 3.5 s。
- TTS：RIFF/WAVE，24 kHz，`ffprobe` 时长 **2.56 s**。
- headless：`XDG_DATA_HOME=~/a0-headless.*`、`DISPLAY=`、`A0_PORT=5081`、`A0_AUTH_KEY=probe-headless-key`；`Xvfb-for-Xpra-120 :120`、`xpra start-desktop :120 --tcp-auth=env`、`XPRA_LOG_TO_FILE=1`、`XPRA_DESKTOP_GREETER=0`、`14500` 200（`Server: Xpra-WebSocket-Server`）。清掉第二实例与其数据目录。
- 结束状态：`flatpak ps` 1 个实例；5080 health 200；5081/14500 未监听；`~/.var/app` 未删。

## 边界

- 上游 checkout 未改源码；`build.sh` 只写 `$A0_SRC/flatpak` 的构建副本与 WPS 依赖 pin（既有行为）。
- 未 git commit；未动 pacman/grub/用户数据。
- 通过项仍为 55/61，H 仍 4/5，平均分 85.4 不变；V1–V4 原本已计入 PASS*/PASS，修复只提升证据质量，不改判定表。
- 只能 760K 验：J 类 `C53–C57`（systemd unit、服务重启、开机自启）与 A 类 `A1–A4`（NVIDIA/CUDA 可见性）。本机无 NVIDIA、无 systemd user 路径。
