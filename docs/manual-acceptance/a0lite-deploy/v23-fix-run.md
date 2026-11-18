# v23 修复验收运行记录

- 日期：2026-11-18
- 构建：`A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`，EXIT=0，**578 s**
- 日志：`~/a0-local-backup/build-v23-1030.log`（脚本无 `set -x`，以末尾 `ls -lh` 与三包 mtime 为证据）
- v22 备份：`~/a0-local-backup/bundles-v22/`（三包完整）

## 1. 构建产物

| 包 | 大小 | mtime | v23 sha256（前 16） | v22 sha256（前 16） |
|---|---|---|---|---|
| agent-zero | 58M | 10:31:43 | `3bc35092fbf9bffc` | `97615832fa8ee5b8` |
| agent-zero-cuda | 821M | 10:38:48 | `9b5cf760d3affffd` | `1a5196a4d3e025fb` |
| agent-zero-wps | 48M | 10:39:56 | `835ecbd0a9d5cd74` | `3ddbd3504f8b72aa` |

主包 commit `5a44b30e3f40`；Cuda commit `2b420e4254e0`；Wps commit `6b3932e36102`。

## 2. D59 空消息（chat_guard）

| 用例 | 状态码 | 响应体 |
|---|---|---|
| `{"text":""}` | **400** | `{"ok":false,"error":"EMPTY_MESSAGE","message":"message text is required"}` |
| `{}` | **400** | 同上 |
| `{"text":"1+1=?"}` | **200** | `{"message": "2", "context": "AydPBQMe"}` |

## 3. D60 OCR（尺寸门限 + 低可信度尾注）

进程：沙盒 venv python3.14，`PYTHONPATH=/app/share/agent-zero/flatpak:/app/share/python-deps:/app/share/agent-zero`。

| 用例 | 结果 |
|---|---|
| 100×50 白图 | `ValueError: image too small for OCR: 100x50, minimum 64px on the short edge and 40000 total pixels`；`_vision_markdown` 调用计数 **0** |
| 1200×800（三行英文） | 返回 110 字符，含 `Invoice 2026 total 123456 USD`、`Hello OCR acceptance test line two`、`The quick brown fox…`；**无** `OCR low confidence` 尾注 |

偏差：测试进程内 `ocr.apply()` 在 `_patch_document_timeout()` 处抛 `ModuleNotFoundError: No module named 'faiss'`（`helpers.vector_db` → `faiss_monkey_patch`），`ImageParser` 未被替换；两条用例直接调用补丁目标 `ocr._parse_image`（与 patch 后的 `ImageParser._parse_sync` 为同一函数体）。服务进程日志 `Application startup complete`、health 200，说明服务内 `a0flatpak.apply()` 未中断（[INFERENCE]），生产路径未观察到该错误。

## 4. D61 STT（静音/过短判定）

| 用例 | 结果 |
|---|---|
| 1 s 16 kHz 全零 WAV | `{'success': True, 'text': '', 'silence': True, 'duration_s': 1.0}`；日志 `speech.stt: silence: rms=0.000000 peak=0.000000 duration=1.0s min_rms=0.005` |
| 中文 TTS「你好，这是一次语音识别验收测试。」 | 199 724 B WAV → `text='你好，这是一次语音师爷验收测试。'`、`language='chinese'`、`duration=4.16`；非空、**无** `silence` |

## 5. D62 嵌入（空串零向量）

| 用例 | 结果 |
|---|---|
| `embed_query("")` | **2560** 维，L2 = **0.0**（全零） |
| `embed_query("hello")` | **2560** 维，L2 = **1.0** |

## 6. 回归

- `scripts/verify-security-fix.sh --expect new` → **12/12 PASS, 0 FAIL, 0 SKIP**
- `A0_DEBUG_PORT=9228 ~/a0-local-backup/verify-ui-fix.sh 5a44b30e` → **PASS (6/6)**：commit `5a44b30e3f40`；asset-bundle version `4f7d50dd40dd8612f242`；runtime==bundle webui（0 差异）；welcome-screen 1015 行、slot=1；DOM channels=1/teleports=1/settings pane 可见、exceptions=0；截图 `/home/kunweiz/a0-shots/verify-ui-fix-settings.png`
- `GET /api/health` → **200**：`{"gitinfo":{branch,commit_hash,commit_time,build_time,tag,short_tag,version},"error":null}`，version `058582f-dirty`
- Vulkan：`GET 127.0.0.1:11434/api/ps` → `qwen3-embedding:4b-q4_K_M size=7779836231 size_vram=7779836231`（100% 驻留 VRAM，未回退 CPU）

## 7. 偏差与遗留

1. D60 的 `ImageParser` 层未在测试进程验证（faiss 缺失，见 §3）；函数级行为（门限、零调用、无尾注）均已通过。`desktop_session` 端点本轮未测。
2. D61b 把「识别」听成「师爷」：判定逻辑正确（非空、无 `silence`），属模型精度。
3. security 脚本仅保留尾部摘要（12/12），逐条 1–4 项未抄录。
4. 未 commit，git 由另一 worker 处理。
