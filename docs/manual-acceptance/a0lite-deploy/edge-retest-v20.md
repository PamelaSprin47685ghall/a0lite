# v20 聊天 / 语音 / OCR / 嵌入复测（edge-retest-v20）

- 实例：`127.0.0.1:5080`，PID `2180949`（flatpak 实例 `2180934`）；health 全程 200
- 版本：已装 ostree `21b0e23a`；`gitinfo` 为 `058582f-dirty`、`build_time=2026-11-17T23:41:59Z`（同构建两层标识）
- 时间：2026-11-18 08:10–08:35；证据目录 `~/a0-shots/v20-retest-20261118/`（125 个文件）
- 口径：聊天/语音走 HTTP 端点；OCR/嵌入无 HTTP 端点，走沙盒内 `PdfParser`/`ImageParser`/`embed_query`

## §1 聊天（`POST /api/message`，CSRF + cookie）

| # | 用例 | 状态 | 耗时 | 关键 body | 判定 |
| --- | --- | --- | --- | --- | --- |
| 1 | 空消息 `{"text":""}`、`{}`、`{"text":null}` | 200×3 | 27.59 / 23.60 / 23.60 s | 三条均 `"I'm ready — what would you like me to do?"`，`context=AydPBQMe` | D59 未修：仍 200，落最近会话 |
| 2 | 同 context 并发 5（9+3、12-5、6×7、81÷9、20+22） | 5/5 200 | 5.56–5.57 s | 五条全部 `{"message":"12"}`（即第 1 题答案） | E3 仍在：4 条被吞，无 409 |
| 3 | 错 Origin `http://evil.example` + 有效 token | 200 | 5.07 s | `{"message":"**1 + 1 = 2** ✅"}` | E4 仍在：Origin 不参与校验 |
| 4 | 无 token（带正确 Origin） | 403 | 0.008 s | `CSRF token missing or invalid` | 通过 |
| 5 | `--max-time 2` 中断长散文 → 立刻短问题 | 000 / 200 | 2.00 / 7.09 s | 恢复响应 1,400 字，开头 `2+2 = 4`，随后接完整散文 | E5 仍在：答案合并 |
| 6 | 并发 10（独立 context，10 道算术） | 10/10 200 | 最大 17.44 s，墙钟约 17.5 s | 11/21/31/41/51/61/71/81/91/101 全对 | 通过（v14 最大 41.24 s） |

## §2 语音（`/api/plugins/_kokoro_tts/synthesize` → `/api/plugins/_whisper_stt/transcribe`）

| # | 用例 | 状态 | 耗时 | 关键 body | 判定 |
| --- | --- | --- | --- | --- | --- |
| 7 | 中文 TTS→STT ×3（不同句子） | 200×3 / 200×3 | TTS 2.20–3.02 s；STT 0.63–0.82 s | 17 / 12 / 13 个汉字；2/3 逐字一致；第 3 句「中文语音识别」→「震温热营试飞」；`language=""` | **3/3 汉字，通过**（转写精度 2/3） |
| 8 | 英文 TTS→STT | 200 / 200 | 2.20 / 0.63 s | `The quick brown fox jumps over the lazy dog.`；0 个汉字 | 通过（不硬编码 zh） |
| 9 | TTS 5,500 字 | 413 | 0.018 s | `{"success":false,"error":"SPEECH_INPUT_TOO_LONG","message":"speech input is 5500 characters, the limit is 1200 (A0_SPEECH_MAX_CHARS)…"}` | 通过（D63） |
| 10 | TTS 空串 | 400 | 0.012 s | `Missing text`（`text/html`） | 通过 |

## §3 OCR（沙盒内 `PdfParser` / `ImageParser`）

| # | 用例 | 状态 | 耗时 | 关键输出 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 11 | `trunc50.pdf`（截断 50%） | `ValueError` | 0.063 s（进程含导入 3.9 s） | `PDF could not be read: damaged page tree (object missing 'endobj' token)`；仅一个 `PDF could not be read:` 前缀 | 通过（D56） |
| 12 | `scan5.pdf` 5 页，默认配置 | ok（部分） | 61.59 s（首跑）/ 5.62 s（热跑） | 尾注 `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).` | 通过（D57） |
| 13 | `lowres100x50.png` | ok=true | 2.12 s | 76 字符无关数学题：`① 已知 (a)、(b)、(c) 是正三角形…`，无 `OCR incomplete` | D60 未修 |

## §4 嵌入

| # | 用例 | 状态 | 耗时 | 关键输出 | 判定 |
| --- | --- | --- | --- | --- | --- |
| 14 | `embed_query("")` | ok | 0.069 s | `len=2560`、`l2=1.0000001`、`nonzero=2560`、`first3=[0.001437, 0.045354, 0.001158]` | D62 未修：空串静默编码 |

## §5 修复确认

- **D58｜中文 STT 拼音**：通过。3 轮中文 TTS→STT 均为汉字（0 拼音），`language` 不再被强制 `english`（本次为空串）；英文句仍正确，证明不是硬编码 zh。转写精度 2/3，第 3 句有同音误识。
- **D63｜TTS 超长 HTTP 上限**：通过。5,500 字在 handler 前置返回 **413** + `SPEECH_INPUT_TOO_LONG`，未落到 Paradee/spacy，错误可读。
- **D56｜截断 PDF 静默降级**：通过。0.063 s 抛 `ValueError: PDF could not be read: damaged page tree…`，无重复前缀，不再空跑 45 s。
- **D57｜默认预算到不了页数上限**：通过。默认配置 5 页出 **4/5**，尾注原文含 `A0_OCR_MAX_PAGES=4`，不再只报 timeout。

## §6 未修确认

- **D59｜空消息**：仍 200 + 通用寒暄，三条都写进最近会话 `AydPBQMe`；无 400。
- **D60｜低分辨率 OCR**：100×50 仍 `ok=true`，返回 76 字符无关数学题，无拒识/低置信标注。
- **D62｜空串嵌入**：仍返回 2,560 维非零单位向量（L2=1.0），调用方无法区分空输入。

## §7 与 v14 的差异

- 聊天行为未变：D59 仍 200；同 context 5 条仍返回同一答案（v14 `51` / v20 `12`）；错 Origin 仍 200；中断仍合并答案（v14 3,700 字 / v20 1,400 字）。
- 聊天时延下降：并发 10 最大 41.24 → 17.44 s；同 context 5 条 13.83 → 5.57 s；中断恢复 28.75 → 7.09 s。空消息反而变慢（7.3–10.5 → 23.6–27.6 s），与冷/热模型状态有关。
- 语音从“HTTP 层不可用”变为可用：v14 TTS/STT 均为 200 `success:false`（spacy / whisper stub），v20 TTS 2.2–3.0 s、STT 0.6–0.8 s 且中文 3/3 汉字。
- TTS 超长从 200 `success:false` 变为 413 `SPEECH_INPUT_TOO_LONG`；空串仍 400 `Missing text`。
- 截断 PDF 从 `ok=true` + `0 of 5 pages` + 45.34 s 变为 0.063 s `ValueError`；5 页默认从 2/5 + timeout 变为 4/5 + `A0_OCR_MAX_PAGES=4`。
- 低分辨率 OCR 未变：v14/v20 都是同一段 76 字符无关数学题（幻觉稳定复现）。
- 空串嵌入未变：2560 维、L2=1.0、非零。
