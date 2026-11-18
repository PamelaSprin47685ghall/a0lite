# 视觉巡检报告（运行实例）

- 日期：2026-11-18 04:01–04:19（本地）。
- 实例：commit `4d0ccd2c`，`http://127.0.0.1:5080`，`/api/health` 200。
- Chrome：`Google Chrome 156.0.8078.79`，`--headless=new`。
- CDP：9333 桌面 1440×900；9335 移动 390×844（dpr 2）。独立 profile：`~/a0-local-backup/chrome-visual`、`chrome-visual-9335`。
- 截图：`~/a0-shots/visual/`，共 64 张（含探针）；本报告引用 18 张。
- 方法：CDP `Page.navigate` / `Runtime.evaluate` / `Page.captureScreenshot`；禁用缓存与 Service Worker；每页统计 `window.__errs`、console error、HTTP ≥400。
- 口径：`visibleDialogs` 会把 `display:none` 的 `[role=dialog]` 计入（如 `.context-window-popover`），下表“异常”只统计真实运行时异常。
- 约束：按协调要求本轮**不构建、不重装、不改源码**；下列缺陷均未修复，复验为 N/A。

## §2 12 页结果

| # | 页面 | 截图 | bodyTextLen | emptyBlocks | 横向溢出 | 异常 | 判定 |
|---|---|---|---|---|---|---|---|
| 01 | 首页 | `01-home-040151.png` | 1377 | 0 | 无 | 0c | PASS* |
| 02 | 聊天·一句话 | `02-chat-answer-041055.png` | 1040 | 0 | 无 | 0c | PASS |
| 03 | 聊天·表格+代码 | `03-chat-table-041122.png` | 1788 | 0 | 无 | 0c | PASS |
| 04 | 设置·Agent 配置 | `04-agent-config-041606.png` | 13489 | 0 | 无 | 0c | PASS |
| 05 | 设置·模型/provider | `05-models-041608.png`；`05c-models-api-base-041540.png`；`05d-models-max-tokens-041541.png` | 13489 | 0 | 无 | 0c | PASS* |
| 06 | 设置·记忆 | `06-memory-041619.png` | 3522 | 0 | 无 | 0c | PASS |
| 07 | 设置·MCP | `07-mcp-041609.png`；`07b-mcp-servers-041138.png` | 2953 | 0 | 无 | 0c | PASS* |
| 08 | 设置·语音 | `08-voice-041611.png` | 13581 | 0 | 无 | 0c | **FAIL** |
| 09 | 设置·开发者 | `09-developer-041612.png` | 2462 | 0 | 无 | 0c | PASS |
| 10 | 文件浏览器 | `10-file-browser-040637.png` | 2771 | 0 | 无 | 0c | PASS |
| 11 | 桌面 surface | `11-desktop-041555.png`；`11-desktop-frame-final.png` | 2310 | 0 | 无 | 0 + 5×HTTP 400 | PASS* |
| 12 | 移动端首页/聊天 | `12-mobile-home-041240.png`；`12-mobile-chat-041246.png` | 1317 / 1296 | 0 | 无 | 0c | PASS* |

`0c` = `window.__errs` 为 0，但 console error 1 条，全部是 V1（自更新缺 git）。

02 的单句回答本身没有代码块；代码块与表格由 03 覆盖。02 的复制按钮在 DOM 中 2 个（静态截图不可见，hover 显示）；03 的复制按钮 5 个。

## §3 缺陷清单（V1–V8）

**V1｜版本号显示 “Version unknown unknown” + 每页自更新 console error**
- 现象：侧栏页脚固定显示 `Version unknown unknown`；页面加载/打开设置时 console 报 `Failed to load self-update info: Error: [Errno 2] No such file or directory: 'git'`；`/api/health` 返回 `{"gitinfo":null,"error":"…/data/agent-zero"}`。
- 根因：Flatpak 沙箱内没有 `git` 二进制。`helpers/git.get_git_info()` 走 GitPython 失败；`ui_server.serve_index` 回退 `version/commit_time="unknown"`；`helpers/self_update.get_update_info()` 直接 `subprocess.run(["git",…])` 失败。`agent-zero.sh` 只设了 `GIT_PYTHON_REFRESH=quiet`，不提供 git。
- 修复面：`flatpak/org.agentzero.AgentZero.yml`（随包提供 git 或构建版本元数据）、`flatpak/agent-zero.sh`、`flatpak/a0flatpak` 运行时补丁，或上游 `helpers/ui_server.py` / `helpers/self_update.py`。
- 复验：通过（commit `ab3d8e6150f7`）。health `version=058582f-dirty`、`error=null`；页脚 `Version 058582f-dirty 2026-11-17T20:31:57Z`；首页与设置页 console error 0。修复前：`01-home-040151.png`；修复后：`~/a0-shots/v14/01-home-version.png`。

**V2｜文件浏览器 7/12 行时间为 1/1/70 8:00 AM**
- 现象：`agents, api, conf, extensions, plugins, prompts, webui` 七个目录显示 `1/1/70, 8:00 AM`；`knowledge/tmp/usr/venv/ollama.log` 正常。
- 根因：flatpak-builder 把源文件 mtime 归一为 Unix epoch；`flatpak/agent-zero.sh` 的 `cp -a` 又保留该 mtime，文件浏览器按真实 mtime 渲染。
- 修复面：`flatpak/agent-zero.sh` 的 seed/copy 段（不保留时间戳或写入固定构建时间），或上游 file-browser 渲染层（epoch 显示 `—`）。
- 复验：通过（commit `ab3d8e6150f7`）。`/api/get_work_dir_files?path=%2Fa0` 的 12 项 modified 全部 ≥ 2026-11-01，无 1970；`usr/memory` mtime 保持 01:38。修复前：`10-file-browser-040637.png`；修复后：`~/a0-shots/v14/02-file-browser.png`。

**V3｜桌面 surface 每次 resize 都 400：`xrandr is not installed.`**
- 现象：dock 的桌面 iframe 能渲染且 canvas 像素在变；但 `/desktop/resize?token=agent-zero-desktop&width=647&height=852` 返回 400，body `{"ok":false,"error":"xrandr is not installed."}`（本轮 2 次；1118×770 时 3 次）。
- 根因：xpra 的 resize 路径要调用 `xrandr`；manifest 只装了 xpra/Xvfb，没有 xrandr 客户端。
- 修复面：`flatpak/org.agentzero.AgentZero.yml` 增加 xrandr（及 libXrandr 运行库），或 `flatpak/a0flatpak/desktop.py` 在无 xrandr 时跳过 resize/沿用初始分辨率。
- 复验：通过（commit `ab3d8e6150f7`）。700×800、1118×770、647×852 三次 `/desktop/resize` 均 200，body 含 `"resized":false`。修复前：`11-desktop-041555.png`、`11-desktop-frame-final.png`；修复后：`~/a0-shots/v14/03-desktop.png`。

**V4｜移动端右侧 rail 压住聊天/卡片**
- 现象：390 px 下 `.right-canvas-rail` 为 `position:fixed; z-index:4; rect (350,310) 40×224`，与消息气泡实际重叠 `20×95`、`10×14` 像素；首页 Quick Actions 卡片右缘也被压住。输入框 x63 y745 w198 h45，完全在视口内；无横向滚动条。
- 根因：上游 `webui/components/canvas/right-canvas.css` / `right-canvas.html` 在 `≤640px` 没有隐藏 rail 或为它预留布局空间；打包层未加补丁。
- 修复面：上游 webui 的移动端断点（隐藏 rail 或收进抽屉）；当前 Flatpak 无对应 patch。
- 复验：通过（commit `ab3d8e6150f7`）。390×844：`display=none`、`scrollWidth=390`、9 条气泡 0 重叠、console error 0。修复前：`12-mobile-home-041240.png`、`12-mobile-chat-041246.png`；修复后：`~/a0-shots/v14/04-mobile.png`。

**V5｜语音页没有试听/预览按钮（唯一 FAIL）**
- 现象：Local TTS 卡片显示 Ready、`Paradee-8M`、`Paradee · Heart`、Speed 1.1；Whisper STT 显示 Ready、`base`、`en`；但按钮只有 `Configure` / `Status`，两个子模态框内也没有 test/preview/play 控件。
- 根因：上游 `webui/components/settings/agent/voice.html` 与 `_kokoro_tts` 插件配置页均未提供试听动作，非打包层缺失。
- 修复面：上游 webui / 插件；当前只记录，不改。
- 复验：未修复，N/A。修复前：`08-voice-041611.png`；修复后：无。

**V6｜模型页的 `api_base` / `max_tokens` 默认不可见**
- 现象：Models 汇总只显示 `KW92 ZProxy / mistral/deepseek-v4-1-flash-1017`（Main、Utility）与 Embedding；`api_base`、`max_tokens` 要进 `Edit Presets` 并展开 4 个 `.advanced-toggle` 才出现。展开后 Main 的 `API base URL` = `http://127.0.0.1:18080/v1`，Vision sidecar 的 `Max tokens` = `2000`。
- 根因：上游 models-summary / preset editor 把高级字段折叠；不是数据缺失。
- 修复面：上游 `webui/components/settings/...`（默认展开或摘要展示）。低优先级发现性问题。
- 复验：未修复，N/A。修复前：`05-models-041608.png`、`05c-models-api-base-041540.png`、`05d-models-max-tokens-041541.png`；修复后：无。

**V7｜MCP 页默认看不到 WPS 与连接状态**
- 现象：`#section-mcp-client` 只有 “MCP Servers Configuration / Open”；点 `Open` 后才出现 `wps-office`（Local、ON）与 `wps_office / global / Ready / stdio / 250 tools`。
- 根因：上游 MCP 设置摘要页把服务器清单收进二级模态框；数据与状态本身正常。
- 修复面：上游 webui（摘要行显示 server 名称/状态）。发现性问题，非打包缺陷。
- 复验：未修复，N/A。修复前：`07-mcp-041609.png`、`07b-mcp-servers-041138.png`；修复后：无。

**V8｜重复打开同一模态会残留隐藏副本**
- 现象：连续 3 次 `openModal` 后 DOM 有 4 个 `.modal`，仅 1 个 `.show`；`.file-browser-modal` 出现多份，`querySelector` 命中隐藏副本时行文本为空、树 0 行；header 按钮出现 10 个。
- 根因：上游 `webui/js/modals.js` 的 modal 栈/回收逻辑；日常单次打开不受影响，属潜在 DOM 泄漏。
- 修复面：上游 webui；未修复。修复前：`10-file-browser-040619.png`（隐藏副本导致空列表的探针）；修复后：无。

**非视觉观察（不计缺陷）**
- 桌面 surface 是**宿主 `:0.0` 的实时镜像**（`spawn-diag.txt`：`host=':0.0' display=0 port=14501`；xpra 日志 `X11 display :0 size 3840x2160`），不是隔离的 `:120`。`flatpak/a0flatpak/desktop.py::_spawn_desktop_locked` 的文档写明这是 host-display 路径；隐私/隔离风险高，但与页面渲染无关。
- 14500 不是固定端口：实际会话为 **14501**，iframe src 是 `/desktop/session/agent-zero-desktop/index.html?...`，不含 `14500`。按“14500 是否嵌入”字面检查会误判；应按动态端口/iframe 是否存在检查。

## §4 与历史截图对比

- 首页：`01-home-233642.png` 有 10 张 Quick Actions，`Memory` 重复、前两张无描述、第 10 张被裁；当前 7 张、有描述、无重复，无退化。
- 设置：`19-settings-populated.png` / `20-settings-models.png` 只有 Agent 组且模型行被页脚裁切；当前 8 个导航组、面板有值、无空白模态框，明显改善。
- 聊天：`04-chat-view.png` 看不到输入框、首条用户消息被顶边裁切；当前输入框在 y798 可见，表格 661px 宽不溢出气泡（870px），代码块 832px，复制按钮 5 个，无退化。
- 桌面：`91-desktop-v12.png` 是 14500 的 noVNC 带工具栏；当前是 dock 内 xpra iframe（14501）且画面在刷新，无“连接中”卡死；工具栏消失，resize 失败是新问题（V3）。
- 文件浏览器：历史截图只有 `80-browser-tool.png`（浏览器工具页，不是文件浏览器），无同类基线；1/1/70 日期为本轮新发现（V2）。
- 三个已知已修缺陷均未再现：设置模态框有内容、jQuery 无 404、CSRF 无 403。`Version unknown unknown` 与历史一致，非本轮回归（V1）。

## §5 未覆盖页面与原因

- 设置内未巡检：Workdir、Locale、Interface、Plugins、File Browser 设置、Skills、External Services、Backup、A2A；本轮只要求 04–09。
- 登录/`/safe` 页面未测：实例未启用认证。
- 桌面 resize 修复未复验：按协调要求不构建、不重装；xpra 会话仍在 14501。
- 文件浏览器只验证了列表、树展开和面包屑，未执行上传、重命名、删除。
- 移动端只测 390×844 竖屏，未测横屏与平板宽度；仅 Chrome，未测 Firefox/Safari。
- 所有缺陷均未修复，未生成新 commit；运行实例仍为 `4d0ccd2c`。

## v14 复验（2026-11-18 05:07–05:21，commit `ab3d8e61`）

**采样区间（供 soak 排除）**：05:07:30–05:08:56 首页/菜单；05:11:51–05:12:02 一次失败批次（仅刷新）；05:12:13–05:12:46 主批次；05:13:01–05:13:14 文件/移动端；05:19:31–05:20:46 补测 chat/memory/scheduler；Chrome 于 05:21:10 杀掉。污染区间合计 **05:07:30–05:21:10**（段 B 内）。

| # | 页面 | 上次 | 本次 | 变化 | 证据（本次截图/时间） |
|---|---|---|---|---|---|
| 1 | home / Dashboard | PASS | PASS | **改善**（V1 修复） | `01-dashboard-051214.png` 05:12:14 |
| 2 | chat | PASS | **PASS** | 不变 | `02b-chat-052039.png` 05:20:39；2 条用户、3 条助手，输入框 y798 |
| 3 | settings | PASS | PASS | 不变 | `03-settings-agent-051224.png` 05:12:24 |
| 4 | files | PASS（V2 1970） | PASS（V2 修复） | **改善** | `04b-files-051304.png` 05:13:04；API 12 项均 ≥ 2026-11-01 |
| 5 | memory | PASS | **PASS** | 不变 | `05b-memory-052042.png` 05:20:42；Total 21、21 条、搜索框可用 |
| 6 | tools / Plugins | 上次 09 Developer PASS | PASS | 不变（口径映射） | `06-plugins-051241.png` 05:12:41，47 张插件卡 |
| 7 | speech / Voice | **FAIL**（V5） | **FAIL**（V5） | 不变 | `09-voice-051227.png` 05:12:27；仍只有 Configure/Status |
| 8 | desktop | PASS*（V3 400） | **未测** | 未知 | 按 soak 跳过页面；端点见下 |
| 9 | scheduler | 无基线 | **PASS** | 新增 | `09b-scheduler-052045.png` 05:20:45；Total 0，空态正常 |
| 10 | models | PASS*（V6） | PASS*（V6） | 不变 | `08-models-051225.png`；api_base/max_tokens 仍在折叠 Advanced |
| 11 | mcp | PASS*（V7） | PASS*（V7） | 不变 | `10-mcp-051228.png`；WPS/Ready 仍要 Open 后才出现 |
| 12 | about / version | **FAIL**（V1） | PASS | **改善** | 页脚 + `/api/health`，05:13:14 |

**V1–V4 五项**
- V1 版本：PASS。页脚与 health 均为 `058582f-dirty 2026-11-17T20:31:57Z`，`error:null`。
- V1 自更新：PASS。本次所有采样 console error **0**，`self_update_get` 请求 **0**。
- V2 文件时间：PASS。API 12 项，最小 `2026-11-01T16:51:48+08:00`（epoch 1793523060），无 1970；DOM 当时 13 项（多一个探针目录），同样无 1970。
- V3 桌面 resize：**未测/受阻**。无会话时 GET/POST `/desktop/resize` 均 400 `Virtual desktop session not found`；尝试 `POST desktop_session {action:"session"}` 返回 200 但 `ok:false`（依赖检查拒绝），故 200+`resized:false` 未复现，V3 仍不能判定已修。
- V4 移动端：PASS。390×844 下 `.right-canvas-rail` 为 `display:none`，`scrollWidth=clientWidth=390`，输入框在视口内；`11-mobile-051314.png` 05:13:14。

**回归清单**：未发现已确认回归。已确认改善 4 项（V1 版本、V1 自更新噪音、V2 日期、V4 移动端 rail）；V5–V7 仍确认存在（语音无试听、模型高级字段折叠、MCP 摘要隐藏），V3/V8 未复测。
**新缺陷**：V9（语音 TTS 后端）——`POST /api/plugins/_kokoro_tts/synthesize` 返回 HTTP 200 + `{"success": false, "error": "No module named 'spacy'"}`；语音页无试听是上游 UI 设计，但即使补按钮也会因该依赖缺失失败。V10（desktop 健康检查撒谎）已查到底，见下节，定级高。
**未测项（受 soak 保护约束）**：desktop 页面截图（按指示跳过）；V3 resize 无法复验——无会话时 GET/POST `/desktop/resize` 均 400 `Virtual desktop session not found`，启动会话又被依赖检查拒绝；移动端只测首页，未测聊天页。另 `flatpak ps` 收尾时仍有其他 worker 的探针实例，非本会话 Chrome；9333 已关闭。

### V10 桌面健康检查撒谎

**1. health 为什么说 healthy**：`/desktop/health` 路由（`helpers/virtual_desktop_routes.py:94-95`）调 `virtual_desktop.collect_status()`。原函数（`helpers/virtual_desktop.py:156-192`）检查 `xpra/Xvfb/xfce4-session/dbus-launch/xrandr/xdotool + xpra-x11 + html5`；a0flatpak 的 `_patch_status_checks`（`flatpak/a0flatpak/desktop.py:151-195`）把它缩到仅 `xpra + html5`。沙箱这 5 个二进制全缺，health 仍 `healthy:true`，因为它只看了 xpra/html5。
**2. session 的依赖检查**：`ensure_system_desktop` 在 `desktop_session.py:612-614` 调 `collect_desktop_status()`；原函数（`:1715-1764`）检查 `soffice/thunar/xfce4-terminal/xfce4-settings-manager/gio + 上述 6 个 X 工具`。`_patch_desktop_status`（`desktop.py:109-148`）同样缩到 xpra+html5，但当前运行实例返回的是**未打补丁的原始 5+ 项**；同一 bundle 起独立 Python，`apply()` 后 `_a0flatpak_patched=True`、`healthy=True`、`missing=[]`。最可能：`a0flatpak` 给 `/app` 的 `desktop_session` 模块打了补丁，而运行中的插件加载器用的是 `$BASE_DIR/plugins` 的可写副本（存在且原始未补丁），两个模块对象不一致。
**3. 五个依赖的存在性**：
| 二进制 | 沙盒 | 宿主 |
|---|---|---|
| soffice | MISSING | MISSING |
| thunar | MISSING | /usr/bin/thunar |
| xfce4-session | MISSING | /usr/bin/xfce4-session |
| xrandr | MISSING | /usr/bin/xrandr |
| xdotool | MISSING | /usr/bin/xdotool |
宿主也缺 soffice，所以“改用宿主二进制”修不全；host-display 路径本来不需要 LibreOffice/XFCE，补包不是正确方向。
**4. V3 现在能不能测**：不能。`pgrep Xvfb/xpra` 为空，14500/14501 无监听；GET/POST `/desktop/resize` 均 400 `Virtual desktop session not found`；`POST desktop_session {action:"session"}` 200 但 `ok:false`。v14-fix-run 的 200+`resized:false` 来自 04:54 的 headless `:120` 会话（session JSON `display:120, xpra_port:14500`，xpra 日志 `X11 display :120 size 1920x1080`，04:54:48 终止）；`03-desktop.png` 是终端裁剪，不是 Xfwm4 桌面 chrome。结论：主实例的 host-display `_desktop` 路径从未验证，V3 不能判已修。
**5. 修复方向与定级**：首选修模块副本——让 `a0flatpak` 在 `base_dir.apply()` 之后显式 patch `$BASE_DIR/plugins/_desktop/helpers/desktop_session.py` 的模块，或把该路径放到 `sys.path` 首位再 import；其次让 `ensure_system_desktop` 直接复用 `/desktop/health` 的 patched 状态。不要补 soffice/thunar。V10 定级：**高**——Desktop 页会直接失败，health 却报 healthy；同一代码的新进程与运行进程结果不同，不是单纯 stale-process，重启不能保证修好，需要一次代码/打包修正；无数据损失，但桌面验收不可过。

#### 波及范围
| 模块 | patch 内容 | 实际加载路径 | 当前 | 影响 |
|---|---|---|---|---|
| 11 个 helpers 类 apply（base_dir/compat/provider_urls/embeddings/vector_store/rfc_loop/serve/version/sensitive_paths/mcp_cache/code_exec） | 路径、协议、嵌入、API、版本 | `/app/helpers`（无 writable 副本） | 生效 | 启动/嵌入/向量/版本/文件底图 |
| browser.py + browser_guard.py | `_browser.hooks` 主机 Chrome、导航上限、生命周期 | `$BASE_DIR/plugins/_browser` | 基础可用，patch 未证 | G 类 5/5 仍成立；B1–B6 超时/错误处理不生效 |
| desktop.py | `_desktop`/`_office` 会话与状态 | `$BASE_DIR/plugins/_desktop` | 失效 | V10：桌面起不来、health 撒谎 |
| speech.py | `_kokoro_tts`/`_whisper_stt` 替换 | `$BASE_DIR/plugins` | 失效 | V9 TTS 后端；STT patch 也未证 |
| ocr.py + parsers.py | `_document_query` 图像/PDF/兜底解析 | `$BASE_DIR/plugins/_document_query` | 未验证 | OCR/PDF fallback 可能仍走原实现 |
| packages.py | `_desktop`/`_office` 清理钩子 | `$BASE_DIR/plugins` | 部分 | 包管理/清理钩子 |
| plugin_guard.py | 按 `sys.modules` 找活对象并重放 patch | 运行时 | fix-v 修复中 | 上述 6 个直补插件的公共修复 |

结论：`a0flatpak` 共 **19 个 `apply()`**；其中 **6 个直接改 `plugins.*`**（browser/desktop/ocr/parsers/packages/speech）+ browser_guard 间接，均有 `$BASE_DIR` 副本风险；建议单列 **V11（patch 架构根因）**，V10 只是桌面症状，G 类浏览器基础通过项仍成立但不能算 patch 验证通过。

#### 构建前基线（19 个 apply 清单）
读到时刻：2026-11-18 05:29（`fix-v` 可能仍在写，以下为当时状态）。
| 模块 | 改的对象 | plugins 命名空间 | plugin_guard | 失效风险 |
|---|---|---|---|---|
| helpers 类 11 个：base_dir, compat, code_exec, embeddings, mcp_cache, provider_urls, rfc_loop, sensitive_paths, serve, vector_store, version | helpers.files / asyncio / models / mcp_handler / providers / runtime / api / server_startup / faiss / git | 否 | 否 | 低（无 writable 副本） |
| browser | `_browser.hooks.prepare_playwright_cache/install` | 是 | 否 | 高 |
| browser_guard | `_browser` 的 `_goto/_state/open/navigate/close_runtime` | 是 | `ensure`×4，无 `register` | 中高；见下 |
| desktop | `_desktop.desktop_session`、`_office.libreoffice` | 是 | 否 | 高（V10） |
| ocr | `_document_query` image/pdf parser | 是 | 否 | 中 |
| parsers | `_document_query.unstructured` | 是 | 否 | 中 |
| packages | `helpers.plugins` + `_desktop`/`_office` hooks | 部分 | 否 | 中 |
| speech | `_kokoro_tts`/`_whisper_stt` runtime + API handler | 是 | `register`×2 + `ensure` | 低中（六者中唯一已接） |
| __init__ | 编排 19 个 apply；无直接 patch | — | — | — |

**当前接入情况**：6 个直改插件对象中只有 `speech` 显式 `plugin_guard.register`（2 个 key）；`browser/desktop/ocr/parsers/packages` 均未接。`browser_guard` 有 4 个 `plugin_guard.ensure`，但未 `register`。
**`__init__.py` 末尾风险**：`from . import browser_guard` / `browser_guard.apply()` 在模块导入时执行（`__init__.py:107-108`），位于 `def apply()` 之外；此时 `base_dir.apply()` 与 `plugin_guard.install_hooks()` 尚未运行，`browser_guard` 可能先导入 `/app` 的 `_browser` 副本并绑定错误对象。构建后需确认它是否移入 `a0flatpak.apply()` 且排在 `base_dir` 之后。
**构建后重点复验**：browser、desktop、ocr、parsers、packages、speech 六个；同时确认 `browser_guard.apply()` 不再在导入期执行。
