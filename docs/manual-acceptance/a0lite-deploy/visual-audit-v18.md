# v18 视觉验收（commit `be957363ef7e`）

## §1 环境
- 实例：`http://127.0.0.1:5080`，health 200；PID 2123135；Flatpak commit `be957363ef7e`。
- health：`version=058582f-dirty`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T22:18:48Z`、`error=null`。
- Chrome 156，headless，CDP 9335，profile `~/a0-local-backup/chrome-v18`；截图 `~/a0-shots/v18-visual/`，13 张（12 页 + 移动端）。
- 采样 06:33:24–06:34:25；Chrome **06:35:36** 已杀，9335 无监听。全程未构建、未重启。

## §2 12 页判定
| 页面 | 判定 | 截图 | 证据 |
|---|---|---|---|
| home | PASS | `01-home-063332.png` | 1788 字；页脚版本正确 |
| chat | PASS | `02-chat-063334.png` | 2 用户/3 助手；输入框 y798 |
| settings | PASS | `03-settings-063341.png` | Agent 0；字段有值 |
| files | PASS | `04-files-063349.png` | 文件浏览器可见（`/a0/usr/workdir` 2 行）；V2 用 API 断言 |
| memory | PASS | `05-memory-063352.png` | Total 22；搜索框可用；10 行/页 |
| tools | PASS | `06-tools-063354.png` | 47 张插件卡 |
| speech | PASS* | `07-speech-063343.png` | Ready；Paradee-8M；仍无试听（V5） |
| desktop | **证据缺口** | `08-desktop-063413.png` | DOM `iframe`/`Xfwm4`/canvas=1；截图实际捕到 Browser 标签，非空白/JS 错误；视觉未确认 |
| scheduler | PASS | `09-scheduler-063357.png` | Total 0；`No tasks found` 空态 |
| models | PASS* | `10-models-063342.png` | kw92 存在；V6 高级字段仍折叠 |
| mcp | PASS* | `11-mcp-063344.png` | 仍要 Open 才见 WPS/Ready（V7） |
| about | PASS | `12-about-063415.png` | 页脚 + health；无独立页面 |
- **desktop 截图误捕原因**：CDP `Page.captureScreenshot` 截的是**页面视口**（headless，无浏览器 chrome），不是整窗；`08-desktop` 中 right-canvas 的活动 tab 仍是 Browser（Google AI Studio），Desktop iframe 已挂载（`Xfwm4`、canvas=1）但未激活，所以看到 Browser 而不是桌面。不是空白/JS 错误；下次先点 `.right-canvas-tab` 的 Desktop，或断言 `rightCanvas.activeSurfaceId==="desktop"` 后再截。

## §3 六项 V 检查
- **V1 版本**：页脚 `Version 058582f-dirty 2026-11-02T18:56:58Z`；health 同值，`error:null`。PASS。
- **V2 mtime**：API 13 项（12 常规 + `.a0-seeded-058582f`），最小 `2026-11-01T16:51:48+08:00`，最大 2026-11-18；无 1970。PASS（题面 12 项差 1 为种子标记）。
- **V3 resize**：`POST /desktop/resize?width=700&height=800` 无 token → 400 `Virtual desktop session not found`；加 `token=agent-zero-desktop` → **200** `{"ok":true,"width":700,"height":800,"resized":false,"note":"xrandr is not installed; the display keeps its mode."}`。PASS（端点要求 token）。
- **V4 移动端**：390×844，rail `display:none`，`scrollWidth=clientWidth=390`；输入框在视口内；`13-mobile-063425.png`。PASS。
- **V10 health/session 一致性**：`/desktop/health` 200 `healthy:true,missing:[]`；`status` 200 `healthy:true`；`session` 200 `ok:true`，`desktop.available:true`、`display:":0"`。三者一致。**PASS**。
- **V10 token/D47**：`SYSTEM_SESSION_ID="agent-zero-desktop"` 硬编码，session token 就是它；无 token 400，带 token 200。`/desktop` gateway 只在有登录时校验 session cookie；本实例未启用登录（`is_authorized()` 在 `credentials_hash` 为空时直接 `True`），所以任何本机进程都能用常量 token 调 resize/代理桌面。判定：这是 **D47（无认证）的具体入口**，不另立新缺陷；若 D47 已记，此条归入 D47。
- **V12 NameError**：session `ok:true`，DOM 出现 `Xfwm4` iframe 与 canvas=1；无 `name 'virtual_desktop' is not defined`。**PASS**。

## §4 与 v16 对照
- V1：v16 时间戳为构建时间 `21:50:08Z`；v18 为 `2026-11-02T18:56:58Z`，另有 `build_time`，符合题面。改善。
- V2：v16 13 项无 1970；v18 同样 13 项无 1970。不变。
- V3：v16 无 session；v18 session 可用，带 token resize 200。改善。
- V10：v16 health 真/session 假；v18 health/status/session 全真。改善。
- V12：v16 NameError；v18 无。改善。
- V4：v14/v16/v18 均通过。不变。
- V5/V6/V7：语音无试听、模型高级字段折叠、MCP 摘要隐藏，仍为上游取舍。不变。
- V13：STT 中文仍为英文音译（v16 3/3），v18 未复跑；记录，不计新回归。

## §5 剩余缺陷
- **V13（记录）**：Whisper 对中文 TTS 音频 3/3 返回英文音译（`Yetze yoniu...`，`language:english`）；`success:true`、text 非空，属模型能力，不影响 M1 的“成功+非空”。
- **V5**：语音页无试听按钮（上游 UI）。
- **V6**：`api_base`/`max_tokens` 默认折叠在 Edit Presets。
- **V7**：MCP 页需 Open 才见 WPS/Ready。
- 无新增产品缺陷；desktop 截图误捕 Browser 标签是**验收证据缺口**，不是应用报错。

## §6 console error
- 12 页 + 移动端 console error 总数 **0**；`self_update_get` 请求 **0**；无 HTTP ≥400（除 V3 无 token 的预期 400）。

## §7 截图清单与限制
- 13 张：01-home、02-chat、03-settings、04-files、05-memory、06-tools、07-speech、08-desktop、09-scheduler、10-models、11-mcp、12-about、13-mobile。
- **desktop 证据缺口**：`08-desktop-063413.png` 实际显示 Browser（Google AI Studio）标签，未显示 Desktop 画面；DOM 同时存在 `iframe.office-desktop-frame`（title `Xfwm4`、canvas=1），session API `available:true, display:":0"`，resize 200。视觉截图需 07:15 后补拍一张（soak 干净窗口结束），本轮不重开 Chrome。
- files 截图是 `/a0/usr/workdir`，不是 `/a0` 根；V2 的 12/13 项由 API 断言，根目录行数据未截图。
- 结论：v18 **功能面可作为交付基线**（六项 V 全过、无 console error）；但“12 页全部视觉通过”不成立，唯一缺口是 desktop 页截图，需补拍后封闭。

## §8 结论与后续
1. **v18 作为功能交付基线成立**：六项 V（V1/V2/V3/V4/V10/V12）全过；12 页功能面通过，desktop 仅视觉证据待补；console error 0、`self_update_get` 0。
2. **唯一证据缺口**：desktop 截图捕到 Browser 表面而非桌面画面。原因是 CDP 只截页面视口，且 `rightCanvas.activeSurfaceId` 仍是 `browser`；Desktop iframe 虽已挂载（Xfwm4/canvas=1）但未激活。补拍时先点 `.right-canvas-tab` 的 Desktop，或断言 `activeSurfaceId==='desktop'` 且 iframe 可见后再截。
3. **D58 STT 拼音已在 v19 修**：`language: en` 改为空串、请求体不带 language 键；v19 后复验中文回灌应出汉字，而不是 `Yetze yoniu...`。
4. **D47 具体入口**：desktop gateway 的 `SYSTEM_SESSION_ID="agent-zero-desktop"` 是硬编码常量 token；登录未启用时 `credentials_hash` 为空，`is_authorized()` 恒真，任何本机进程可用该 token 调 resize/代理桌面。归入 D47，不另立号。
5. **V5/V6/V7 是上游 UI 取舍**（语音无试听、模型高级字段折叠、MCP 摘要隐藏），不修；V13 为模型能力记录。
