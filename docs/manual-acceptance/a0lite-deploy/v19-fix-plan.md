# v19 修复方案（D58 / D57 / D56）

- 基线：v18 `be957363ef7e`；本轮只改代码，**不构建**，等 07:12 soak 结束。
- 三条都在打包层/上游补丁里完成，不改 `~/Desktop/agent-zero` 工作树。

## D58｜STT 默认强制英文

**根因**：`plugins/_whisper_stt` 的 `runtime.DEFAULT_CONFIG`、`migration.DEFAULT_CONFIG`、`default_config.yaml` 和 `usr/plugins/_whisper_stt/config.json` 都是 `language: en`。Whisper 收到 `language=en` 就把中文转成拼音；`_resolve_language` 只把 `auto` 映射为 `None`，空串原本也会被 `if language` 挡住，但默认值把空串掩盖了。

**改法**：默认统一为空串。
- `default_config.yaml`：`language: ""`
- `migration.DEFAULT_CONFIG`：`"language": ""`
- `runtime.DEFAULT_CONFIG`：`"language": ""`
- `usr/plugins/_whisper_stt/config.json`（本机运行数据）：`"language": ""`
- UI：`whisper-stt-store.js` 两处默认/回退改空串；`config.html` placeholder 改 `auto (blank = auto)`，说明补“留空表示自动识别”。
- `normalize_config` 不再需要额外改动：空串保持空，`_resolve_language("") -> None`，`_transcribe` 的 `if language` 不会写入 `language` 键。不硬编码 `zh`。

**复验**：中文 WAV 直连 Ollama/HTTP → 汉字；英文 WAV → 英文；请求体 JSON 不含 `language`。

## D57｜OCR 尾注原因不准

**根因**：默认 `OCR_MAX_PAGES=4`、`OCR_TIMEOUT=45`、文档预算 135 s；5 页扫描件只出 2/5 时，`_ocr_pages` 的 `stopped` 是逐页超时，尾注只写 `timeout`，看不到 `MAX_PAGES` 上限。

**选择 B（保留 4 页）**：不降能力，只把真实原因写清。
```diff
 if processed < total:
-    reason = stopped or f"A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
+    if stopped:
+        reason = f"{stopped}; A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
+    else:
+        reason = f"A0_OCR_MAX_PAGES={OCR_MAX_PAGES}"
```
预算耗尽/逐页超时仍写原原因，同时附页数上限；页数截断写 `MAX_PAGES`。理由：降默认到 2 会直接损失两页能力，而问题只是文案。

**复验**：5 页扫描件尾注含 `timeout after ...; A0_OCR_MAX_PAGES=4`；4/5 页截断含 `A0_OCR_MAX_PAGES=4`；不出现 `0 of 5` 空文档。

## D56｜截断 PDF 静默降级

**根因**：`_pdf_pages` 逐页渲染时，MuPDF 对截断文件打印 `object out of range` 但返回可渲染的空页；随后 `_ocr_pages` 白跑 45 s 才返回 `0 of 5`。

**改法**：在 `_pdf_pages` 内逐页 try/except，并读取 `pymupdf.TOOLS.mupdf_warnings()`：
- 打开后/第一页渲染后出现 `object out of range`、`Page tree load failed`、`non-page object in page tree` → 立即 `ValueError("PDF could not be read: damaged page tree (...)")`。
- 第一页其他异常 → 立即 `ValueError("PDF could not be read: <类型>: <原因>")`。
- 中间页异常或损坏 → `continue`，按现有逻辑跳过并让 `_ocr_pages` 计数；不再让整份文档静默成功。

**复验**：`trunc50.pdf` 在 0.14 s 返回 `ValueError ... damaged page tree`，不再跑 45 s；`scan5.pdf` 正常。

## 改的文件

- `flatpak/a0flatpak/ocr.py`（D57/D56）
- `flatpak/patches/flatpak-ui.patch`（D58 的 5 个上游插件文件 hunk）
- `~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/plugins/_whisper_stt/config.json`（本机运行数据）

## 复验命令

```sh
# 中文 STT：期望汉字
curl ... /api/plugins/_whisper_stt/transcribe -d @zh.json | jq -r .text
# 英文 STT：期望英文
curl ... /api/plugins/_whisper_stt/transcribe -d @en.json | jq -r .text
# OCR 5 页：尾注含 timeout 与 A0_OCR_MAX_PAGES=4
# 截断 PDF：<1 s 返回 damaged page tree
flatpak run --command=sh org.agentzero.AgentZero -c 'python3 - <<PY ... _pdf_pages(open("trunc50.pdf","rb").read()) ... PY'
```

## 构建窗口

等 soak 07:12 结束、`flatpak ps` 只剩 1 行后，`A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`；预计 10–12 分钟。构建后安装主包 → Cuda → Wps，再跑中文/英文 STT、5 页 OCR、截断 PDF 四项。
