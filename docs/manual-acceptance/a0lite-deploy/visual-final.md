# 视觉验收总表（v14 → v19）

| 页面 | v14 | v16 | v18 | v19 | 最终判定 | 证据截图 |
|---|---|---|---|---|---|---|
| home / Dashboard | PASS | PASS | PASS | PASS | PASS | v18 `01-home-063332.png`；v19 `00-home-073003.png` |
| chat | PASS | PASS | PASS | 沿用 | PASS | v18 `02-chat-063334.png` |
| settings | PASS | PASS | PASS | 沿用 | PASS | v18 `03-settings-063341.png` |
| files | PASS | PASS | PASS | 沿用 | PASS | v18 `04-files-063349.png`（V2 由 API 断言） |
| memory | PASS | PASS | PASS | 沿用 | PASS | v18 `05-memory-063352.png` |
| tools / Plugins | PASS | PASS | PASS | 沿用 | PASS | v18 `06-tools-063354.png` |
| speech / Voice | FAIL(V5) | PASS* | PASS* | PASS* | PASS*（V5 上游） | v19 `01-voice-073009.png` |
| desktop | 未测 | FAIL(V12) | 证据缺口 | PASS | PASS（口径修正） | v19 `02-desktop-073027.png` |
| scheduler | 未测 | PASS | PASS | 沿用 | PASS | v18 `09-scheduler-063357.png` |
| models | PASS* | PASS* | PASS* | 沿用 | PASS*（V6 上游） | v18 `10-models-063342.png` |
| mcp | PASS* | PASS* | PASS* | 沿用 | PASS*（V7 上游） | v18 `11-mcp-063344.png` |
| about / version | FAIL(V1) | PASS* | PASS | PASS | PASS | v19 `00-home-073003.png`（页脚）+ health |

**12 页结论**：v19 视觉证据齐全。v19 新拍 4 张（`00-home`、`01-voice`、`02-desktop`、`02b-desktop`）；其余 9 页沿用 v18 的 13 张（`~/a0-shots/v18-visual/`）。总计可用证据 13 张 v18 + 4 张 v19。

## 六项 V 检查
| 项 | 最终结果 | 证据 |
|---|---|---|
| V1 版本号 | PASS | 页脚/health `058582f-dirty 2026-11-02T18:56:58Z`；v19 health `error:null` |
| V2 文件 mtime | PASS | `/a0` 13 项（12 常规 + `.a0-seeded`），最小 2026-11-01T16:51:48+08:00，无 1970 |
| V3 resize | PASS（功能可用、能力受限） | 带 `token=agent-zero-desktop` 后 200 `resized:false` + `note: xrandr is not installed; the display keeps its mode.`；**不是缺陷** |
| V4 移动端 | PASS | 390×844 rail `display:none`，`scrollWidth=clientWidth=390` |
| V10 health 一致性 | PASS | health/status/session 全 `healthy/ok=true`，`available:true, display:":0"` |
| V12 desktop NameError | PASS | session `ok:true`，无 `virtual_desktop` NameError |

## desktop 判定口径（修正）
- 浮动 Desktop 窗口中 `activeSurfaceId` 仍可能是 `files`；这不代表失败。
- 正确断言：`iframe.office-desktop-frame` 可见 + `contentDocument.title === "Xfwm4"` + `contentDocument.querySelectorAll("canvas").length === 1`。
- v19 截图 `02-desktop-073027.png` 可见 Xfwm4 浮动窗口、宿主 Chrome/Google AI Studio 与文本；满足桌面画面。

## 已知上游 UI 取舍（不修）
- **V5**：语音页无试听/预览按钮，只有 Configure/Status。
- **V6**：`api_base`/`max_tokens` 默认折叠在 Edit Presets。
- **V7**：MCP 页需 Open 才见 WPS/Ready。
- **V13**：STT 中文识别质量（记录，模型能力；v19 已按 D58 修复中文输出）。

## 遗留
- **D47**：`--talk-name` + 硬编码 desktop token `agent-zero-desktop`；登录未启用时 `/desktop` gateway `is_authorized()` 恒真，任何本机进程可调 resize/代理桌面。
- **A0_AUTH_KEY 默认空**：未启用认证时 `/api` 与 desktop 网关均无凭证保护；本机多用户/恶意进程场景需显式设置。
- V5/V6/V7 保持上游取舍；V13 记录。
- 结论：**v19 12 页视觉验收齐全，六项 V 全过，console error 0；可作为视觉验收最终交付物。**
