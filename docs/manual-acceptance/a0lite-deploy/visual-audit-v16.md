# v16 视觉巡检（commit `0eda9fe1`）

## §1 环境与采样
- 实例：`http://127.0.0.1:5080`，health 200；PID 2094295；Flatpak commit `0eda9fe1`（Date 2026-11-17 21:50:29 +0000）。
- Chrome 156.0.8078.79，headless；CDP 9334；profile `~/a0-local-backup/chrome-v16`；截图 `~/a0-shots/v16-visual/`，共 15 张。
- 采样：06:07:07–06:07:57（12 页+移动端）；06:08:55 补文件根目录；06:09:20 补首页版本。无构建、无重启。
- 运行实例为 v16 重启后的进程；`/api/health` 的 `commit_time` 已由构建时间决定，见 V1。

## §2 V1–V4 + V10 + M1（原始输出）
- **V1 版本**：页脚 `Version 058582f-dirty 2026-11-17T21:50:08Z`；health `version=058582f-dirty`、`commit_time=2026-11-17T21:50:08Z`、`error=null`。**不是 unknown**；但题面字面值 `20:31:57Z` 是 v14 的构建时间，v16 已变为 `21:50:08Z`。严格按字面 = 不匹配；按“修掉 unknown” = 通过（PASS*）。
- **V1 console/self-update**：12 页采样 console error **0**，`self_update_get` 请求 **0**；桌面错误是 UI 内服务端返回，不是 console error。
- **V2 文件时间**：`GET /api/get_work_dir_files?path=%2Fa0` 返回 **13** 项（12 个常规项 + `.a0-seeded-058582f`），最小 modified `2026-11-01T16:51:48+08:00`（epoch 1793523060），无 1970；浏览器 13 行同样无 1970。题面“12 项”差 1 是种子标记，不是时间缺陷。
- **V3 桌面 resize**：先 `POST /api/plugins/_desktop/desktop_session {"action":"session"}` → HTTP 200，但 body `{"ok": false, "error": "name 'virtual_desktop' is not defined"}`；**没有 session**，因此 resize 700×800 未执行，无法复验 200+`resized:false`。
- **V4 移动端**：390×844、dpr2；`.right-canvas-rail` `display:none`；`scrollWidth=390`、`clientWidth=390`；输入框在视口内；截图 `13-mobile-060757.png`。PASS。
- **V10 health/session 一致性**：`/desktop/health` → 200 `healthy:true`、`missing:[]`；`desktop_session {action:"status"}` → 200 `healthy:true`；但 `{action:"session"}` → 200 `ok:false`（NameError）。health 真、session 假，**V10 未修**。
- **V10 根因（v16 新回归）**：`flatpak/a0flatpak/desktop.py:232` 的 `_apply_desktop_session` 没有导入 `virtual_desktop`，其闭包 `_spawn_desktop_locked` 在 `:287` 使用 `virtual_desktop.XPRA_START_ENV` → NameError。健康检查与 resize 补丁不经过该行，所以 health 正常、session 失败。修复只需在该函数内 `from helpers import virtual_desktop`（本轮不改）。
- **M1 TTS**：`POST /api/plugins/_kokoro_tts/synthesize`（19 个汉字）→ HTTP 200 `success:true`，`mime_type=audio/wav`，base64 长度 **358460**；status `enabled:true, engine:paradee, model.ready:true`。
- **M1 STT 回灌**：同一音频 `POST /api/plugins/_whisper_stt/transcribe` → HTTP 200 `success:true`，`text` 非空，但为英文音译乱码：`Yetze yoniu yanzhang yu yin he xing, the shi yozer, Manzhuan se xie ha.`，`language:english`。按“success+非空”通过，按中文识别质量不合格（V13）。

## §3 12 页判定
| 页面 | 判定 | 截图 | 证据 |
|---|---|---|---|
| home / Dashboard | PASS | `01-dashboard-060715.png` | 1863 字符；版本行可见 |
| chat | PASS | `02-chat-060717.png` | 2 用户/3 助手；输入框 y798 |
| settings | PASS | `03-settings-agent-060724.png` | Agent 0；字段有值 |
| files | PASS | `04b-files-060855.png` | 13 行；无 1970；根 `/a0` |
| memory | PASS | `05-memory-060735.png` | Total 22；10 行/页；搜索可用 |
| tools / Plugins | PASS | `06-tools-060738.png` | 47 张插件卡 |
| speech / Voice | PASS* | `09-speech-060727.png` | Ready；Paradee-8M；仍无试听（V5） |
| desktop | **FAIL** | `11-desktop-060745.png` | 面板错误 `name 'virtual_desktop' is not defined` |
| scheduler | PASS | `07-scheduler-060741.png` | Total 0；空态 `No tasks found` |
| models | PASS* | `08-models-060725.png` | kw92 存在；V6 仍未展开 |
| mcp | PASS* | `10-mcp-060728.png` | 仍要 Open 才见 WPS/Ready（V7） |
| about | PASS | `12-about-060746.png` | 版本页脚 + health；无独立页面 |

## §4 与 v14 对照
- V1：v14 `20:31:57Z` → v16 `21:50:08Z`；格式/commit 正确，时间戳随重建变化，不视为视觉回归，但字面验收需改期望。
- V2：v14 无 1970 → v16 无 1970；一致通过。
- V4：v14 通过 → v16 通过；一致。
- V10：v14 health 真/session 假（模块副本）→ v16 仍真/假，但根因变为 NameError；**未修**。
- 12 页：chat/memory/scheduler 补测通过；voice 后端由 spacy 失败变为 TTS/STT 成功，但 UI 仍无试听（V5）；models/MCP 不变；desktop 由“依赖检查拒绝”变为“代码 NameError”，仍 FAIL。
- M1：v14 TTS `No module named 'spacy'` → v16 TTS 成功；STT 成功但中文识别质量差（V13）。
- V11：v16 已开始按活模块重放（plugin_guard），desktop 的 NameError 正是这次重构引入的回归；其余 6 个插件补丁仍需构建后复验。

## §5 新缺陷
- **V12｜桌面 session NameError**：`desktop.py:232` 的 `_apply_desktop_session` 缺 `virtual_desktop` 导入，`:287` 使用即抛错；Desktop 页直接 FAIL，V3 无法测。定级高。
  - **修复**：在 `_apply_desktop_session` 内延迟 `try: from helpers import virtual_desktop`，`ImportError` 写 stderr 并 return（不在模块顶部裸导入）；`py_compile` 通过。
  - **沙盒验证**（用仓库版 `flatpak/` 覆盖 PYTHONPATH）：`module=/home/.../flatpak/a0flatpak/__init__.py`、`healthy=True`、`manager_patched=True`、`closure_has_virtual_desktop=True`、`closure=('desktop_session','original_spawn','virtual_desktop')`；不再 NameError。v17 构建后需用 `/app` 版重跑同一命令。
- **V13｜STT 中文回灌质量（记录，不计缺陷）**：同一 WAV 连跑 3 次，3/3 都是同一英文音译、`language:english`，`success:true`、text 非空；属模型能力问题，不定级为不稳定缺陷。
- 无 V14；`13` 项中的 `.a0-seeded` 是环境种子标记，不计缺陷。

## §6 结论
- console error 总数 **0**，来源无；`self_update_get` **0**。
- v16 **不能**作为交付基线：desktop FAIL、V10 未修、V3 未复验；其余 11 页通过（V5/V6/V7 为已知上游 UI 取舍）。
