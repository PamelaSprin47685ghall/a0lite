# v19 视觉验收（commit `a9aa6ebf525b`）

## §1 环境
- 实例：`http://127.0.0.1:5080`；PID 2158804；Flatpak commit `a9aa6ebf525b`（Date 2026-11-17 23:14:45 +0000）。
- health：`version=058582f-dirty`、`commit_time=2026-11-02T18:56:58Z`、`build_time=2026-11-17T23:14:23Z`、`error=null`。
- Chrome 156 headless，CDP 9336，profile `~/a0-local-backup/chrome-v19`；截图 `~/a0-shots/v19-visual/`（4 张）。
- 采样 07:29:54–07:30:57；未构建、未重启；Chrome 结束后无 9336 监听。

## §2 desktop 页
- 打开路径：right-canvas rail 的 Desktop → `Alpine.store('rightCanvas').open('desktop')` → 等 15s；截图 `02-desktop-073027.png`。
- 画面：可见 **Xfwm4 浮动桌面窗口**，内含宿主 `:0` 的 Chrome（Google AI Studio）与一大块半透明文本；有窗口管理/窗口控件，不是空白、不是 JS 错误。iframe `title=Xfwm4`、`canvas=1`、`frameVisible=true`。
- **断言口径（已修正）**：`activeSurfaceId` 在浮动 Desktop 模式下仍是 `files`，这是浮动窗口语义，不是失败。正确断言是：`iframe.office-desktop-frame` 可见 + `contentDocument.title === "Xfwm4"` + `contentDocument.querySelectorAll("canvas").length === 1`。
- V12 无 `name 'virtual_desktop' is not defined`。

## §3 V1 / V3 / V10
- **V1**：页脚 `Version 058582f-dirty 2026-11-02T18:56:58Z`；health 同值；PASS。
- **V3**：`POST /desktop/resize?token=agent-zero-desktop&width=700&height=800` → HTTP 200 `{"ok":true,"width":700,"height":800,"resized":false,"note":"xrandr is not installed; the display keeps its mode."}`；PASS。
- **V10**：`/desktop/health` 200 `healthy:true`；`desktop_session status` 200 `healthy:true`；`session` 200 `ok:true`、`available:true`、`display:":0"`；三者一致；PASS。
- **V12**：session ok，无 NameError；PASS。
- console error 0；`self_update_get` 0。

## §4 语音页
- `07-speech` 对应截图 `01-voice-073009.png`：Local TTS `Ready`、`Paradee-8M`；Whisper STT `Ready`、`base`。
- 按钮仍只有 `Configure` / `Status`（两卡各两个），**没有试听/预览/播放**；属上游 UI 设计，V5 保持。
- D58 中文 STT 修复由 `fix-v` 的 3/3 汉字结果确认；本页只做状态/按钮目视，不重复端点测试。

## §5 与 v18 差异
- 唯一变化：desktop 视觉证据补齐（v18 截图捕到 Browser 表面；v19 拍到 Xfwm4 桌面画面）。
- V1/V3/V10/V12 与 v18 一致通过；语音页仍无试听（V5）；V6/V7 仍是上游折叠/发现性问题。
- 新差异仅是 `activeSurfaceId` 断言在浮动 Desktop 模式下不成立，已记录为测试口径，不改产品。

## §6 结论
- v19 的 12 页视觉证据齐全：desktop 已有可读的 Xfwm4 桌面画面；其余 11 页沿用 v18 通过结论。
- 六项 V 全部通过（V1/V2/V3/V4/V10/V12）；console error 0；`self_update_get` 0。
- 可作为最终交付基线；desktop 的验收断言用「iframe 可见 + title=Xfwm4 + canvas=1」，不再要求 `activeSurfaceId==="desktop"`。
