# 语音 / OCR / 嵌入边界测试（edge-media）

- 时间：2026-11-18 05:00–05:15 CST
- 实例：`http://127.0.0.1:5080`，PID 1995463，启动 04:42:42；`GET /api/health` 全程 200
- 构建：源码 `058582f-dirty` ↔ 包 ostree commit `ab3d8e61`，同一构建，非版本差异（`report.md` §2.6 已有说明）
- 证据目录：`~/a0-shots/edge-media-20261118-050021/`（118 个文件，约 1 MB；`*.out` 为逐条原始 stdout+stderr，`*-resources.txt` 为采样）
- 判定口径：HTTP 层 = 实例对外端点；部署层 = 同一份 `/app` 代码在沙盒内直接调用（绕开失效的补丁）。两层都记，避免把“端点坏”误读成“能力不存在”

## 1. 模型清单与环境

| 项 | 实测 |
|---|---|
| Ollama | `127.0.0.1:11434`，`/api/tags` 三个模型如下 |
| `xiaomi-ocr:latest` | 736,644,441 B，Q4_K_M |
| `lfm3-omni:2b-q4_K_M` | 2,049,482,162 B，1.7B，Q4_K_M（TTS 与 STT 共用） |
| `qwen3-embedding:4b-q4_K_M` | 2,496,704,041 B，4.0B，Q4_K_M |
| TTS 端点 | `POST /api/plugins/_kokoro_tts/synthesize`（`/api/tts_get` 不存在，404） |
| STT 端点 | `POST /api/plugins/_whisper_stt/transcribe`（body 为 base64 WAV） |
| OCR / 嵌入 | **无 HTTP 端点**（`/api/ocr_get`、`/api/memory_*` 均 404）；只能走沙盒内部署代码路径 |
| 认证 | CSRF：先 `GET /api/csrf_token`（带 `Origin`），再带 `X-CSRF-Token` |
| 沙盒调用 | `flatpak run --user --command=sh org.agentzero.AgentZero -c 'cd /app/share/agent-zero && GIT_PYTHON_REFRESH=quiet PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps A0_BASE_DIR=/var/data/agent-zero /var/data/agent-zero/venv/bin/python <probe> <case>'` |

## 2. A/B/C/D 四组结果

### A. TTS

| 用例 | 输入 | 状态 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| A1 | 19 字中文 | HTTP 200 `success:false` | 0.004 s | `No module named 'spacy'` | **缺陷 M1** |
| | 同句 | 部署层 ok | 5.26 s（05:02 无并发）/ 25.24 s（05:08 与 OCR 并发） | 207,404 B；RIFF 头自洽；24 kHz、4.32 s（首跑 184,364 B / 3.84 s） | 能力通过 |
| A2 | 5,500 字 | HTTP 200 `success:false` | 0.004 s | 仍是 `spacy`；**未出现** `SpeechInputTooLong` | **缺陷 M2** |
| | 同文 | 部署层拒绝 | 5.87 s | `SpeechInputTooLong: speech input is 5500 characters, the limit is 1200 (A0_SPEECH_MAX_CHARS)` | 上限正确 |
| A3 | 空串 | HTTP 400 | 0.002 s | `Missing text`（`text/html`） | 通过 |
| | 空串 | 部署层返回空 | 0.000 s | 0 B，`wave` 报 `EOFError` | 通过（调用方须判空） |
| A4 | 5 emoji + 纯标点 | HTTP 200 `success:false` | 0.004 s | `spacy` | **缺陷 M1** |
| | 同文 | 部署层 ok | 9.74 s | 7,724 B，24 kHz、0.16 s（未拒识） | 记录行为 |
| A5 | 英 + 阿 + 中 45 字 | HTTP 200 `success:false` | 0.004 s | `spacy` | **缺陷 M1** |
| | 同文 | 部署层 ok | 22.42 s | 276,524 B，24 kHz、5.76 s | 记录行为 |

### B. STT

| 用例 | 输入 | 状态 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| B6 | A1 的 WAV（184,364 B） | HTTP 200 `success:false` | 0.005 s | `module 'whisper' has no attribute 'load_model'` | **缺陷 M1** |
| | 同文件 | 部署层 ok | 1.77 s | `Today's weather is very good. Let's go for a walk in the park together.`；`language=english` | **缺陷 M7**（中文→英文） |
| B7 | 1 s 全零静音 | HTTP 同上 | 0.003 s | whisper stub | **缺陷 M1** |
| | 同文件 | 部署层 ok | 1.57 s | `Oh,`（`success:true`） | **缺陷 M6** 静音幻觉 |
| B8 | 1 s 粉噪（anoisesrc） | HTTP 同上 | 0.004 s | whisper stub | **缺陷 M1** |
| | 同文件 | 部署层 ok | 0.71 s | `Okay.` | **缺陷 M6** |
| B9 | 0.2 s 截断音频 | HTTP 同上 | 0.003 s | whisper stub | **缺陷 M1** |
| | 同文件 | 部署层 ok | 0.59 s | `So,` | **缺陷 M6** |
| B10 | 文本改名 `.wav`（50 B） | HTTP 同上 | 0.004 s | whisper stub | **缺陷 M1** |
| | 同文件 | 部署层可读错误 | 6.22 s | `RuntimeError: Ollama transcription failed: model=lfm3-omni:2b-q4_K_M status=400 ... 'Failed to load image or audio file'` | 通过（错误可读） |

### C. OCR / PDF（部署层，`ImageParser` / `PdfParser`）

| 用例 | 输入 | 状态 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| C11 | `text.png` 1200×800 | ok | 1.245 s（热；独立首跑 9.52 s） | 86 字符，4 行逐字正确（含 `12345`、`Agent Zero`） | 通过 |
| C12 | `rot90.png` 旋转 90° | ok | 4.353 s | 86 字符，与 C11 逐字相同 | 通过（旋转不影响） |
| C13 | `lowres100x50.png` | ok | 2.854 s | 76 字符，内容是无关数学题 | **缺陷 M5** 幻觉、无拒识 |
| C14 | `scan5.pdf` 5 页，默认配置 | ok（部分） | 119.54 s | 页 1 表格、页 2 公式正确；尾注 `> OCR incomplete: 2 of 5 pages processed (timeout after 45.0s).` | **缺陷 M3** 上限不可达 |
| C15 | `trunc50.pdf`（截断 50%） | ok（未抛错） | 45.34 s | `> OCR incomplete: 0 of 5 pages processed (timeout after 45.0s).`；stderr 54 条 MuPDF `object out of range` | **缺陷 M4** |
| C16 | `fake.pdf`（非 PDF 文本） | `ValueError` | 0.157 s | `PDF could not be read: FileDataError: Failed to open stream` | 通过 |
| C15b | `trunc10.pdf`（截断到 500 B） | ok | 45.36 s | 同 C15，`0 of 5` + timeout | 复现 M4 |
| C16b | `notpdf.pdf` | `ValueError` | 0.108 s | 同 C16 | 通过 |
| C14b | `scan5.pdf` + `A0_OCR_TIMEOUT=135` | ok（部分） | 129.99 s | 仍 `> OCR incomplete: 2 of 5 pages processed (the 130.0s document budget ran out).` | **缺陷 M3 复现** |
| C14c | `scan5.pdf` + `per_document_timeout=300` | ok（部分） | 54.25 s | 4 页内容完整；尾注 `> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).` | 通过（上限生效） |

注：C14b/C14c 用于区分“`A0_OCR_MAX_PAGES=4` 上限是否生效”与“预算先耗尽”。结论：上限逻辑正确（4/5），默认配置到不了。

### D. 嵌入（`models.get_embedding_model` → Ollama `/api/embed`）

| 用例 | 输入 | 状态 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| D17 | 1 条 | ok | 0.201 s | 2560 维 × 1；本进程 RSS +76 KB | 通过 |
| D18 | 20 条 | ok | 4.013 s | 2560 × 20，维度一致；RSS +5.3 MB，峰值 2.8 MB | 通过 |
| D19 | 100,000 字符 | ok | 62.68 s | 2560 × 1，未报错；RSS +76 KB，峰值 0.7 MB | 通过（未观测到截断） |
| D20 | 空字符串 | ok | 0.335 s | 2560 × 1，L2=1.0、非零；RSS +76 KB | **缺陷 M8** 空串静默编码 |
| D21 | 100 条 | ok | 38.90 s | 2560 × 100，维度一致；**RSS +37.5 MB**，峰值 14.0 MB | 通过 |

## 3. 资源采样（实例 PID 1995463）

| 时点 | RSS (KB) | fd | 说明 |
|---|---|---|---|
| 05:00:21 起始 | 515,868 | 84 | 测试前 |
| 05:02:54 A 组 HTTP 完 | 554,988 | 71 | 4 次 TTS 失败调用 |
| 05:05:25 D 组完 | 567,940 | 65 | 10 万字符 + 100 条批量 |
| 05:06:51 C 组完 | 569,552 | 74 | 5 页 OCR + 截断 PDF |
| 05:11:07 收尾 | 717,880 | 208 | C14b 刚结束，无残留 probe 进程，health 200 |
| 05:13:12 空闲 2 分钟后 | 796,604 | 334 | 本组已无调用，仍在上涨 |
| 05:15:19 C14c 后 | 825,352 | 330 | 54 s 的 4 页 OCR |

判读：RSS 从 504 MB（515,868 KB）升到 806 MB（825,352 KB），fd 从 84 升到峰值 334。**这不是本轮矩阵单独造成的**：05:11–05:13 本组已停止调用，RSS 仍由 701 MB 涨到 778 MB；`ss` 显示实例有 17 条到 `127.0.0.1:18080`（LLM 上游）的 ESTAB 连接、69 个 eventpoll，说明共享实例上还有其它会话在跑。因此本表只作并发窗口记录，不能当作泄漏证据；空闲不回落这一点值得单独立项复测（M9）。

## 4. 缺陷（M1–M9）

- **M1（阻断）TTS/STT 补丁在运行实例中失效。** 两个端点都返回 HTTP 200 + `success:false`，正文是内部模块错误：`No module named 'spacy'`（TTS 回落到 Paradee）与 `module 'whisper' has no attribute 'load_model'`（STT 回落到空 stub）。同一份代码在沙盒内 `a0flatpak.apply()` 后 `runtime.synthesize_sentences.__module__ == 'a0flatpak.speech'`；若执行 `modules.purge_namespace("plugins")` 再导入，则变回 `plugins._kokoro_tts.helpers.runtime`。根因一句话：**补丁只改启动时已导入的模块对象，插件命名空间被 purge 后不会重打，且 `speech.apply()` 用 `except ImportError: pass` 静默吞掉失败。**
  - **触发条件（补查）**：`journalctl --user` 显示 04:50:09–04:56:17 共建 9 次 `flatpak run` scope，其中 04:52:34 与 04:53:47 两次各存活 67 s / 61 s、内存 388 MB / 392 MB，符合完整 launcher 启动。`agent-zero.sh` 第 103–110 行每次启动都执行 `cp -a --no-preserve=timestamps` 覆盖 `api plugins extensions webui`；`plugins/*.py` 的 mtime 恰为 04:53:47.92–04:53:57，共 2,353 个文件。运行实例的插件 watchdog 把这次重刷当成代码变更，`after_plugin_change(python_change=True)` → `purge_namespace("plugins")`，启动时的补丁随之丢失。pyc 佐证：`status`/`hooks` 于 04:54:08 重编译，`synthesize`/`transcribe` 于 05:00:00 重编译（正是本轮首次调用）。**结论：同 app 的第二次 `flatpak run` 即可让运行实例的 TTS/STT 失效，无需改配置。**
  - **发起方**：session 记录中 `flatpak run --user org.agentzero.AgentZero`（完整启动，非 `--command=sh`）出现 69 次，另有 138 次带 `--env=`；journal 只能看到 systemd scope，无法把 04:52/04:53 那两次绑定到具体 agent。已排除三类假设：设置页打开（无插件 toggle 记录）、edge-files 调 API（其调用在 05:16 之后）、显式 reload 插件（日志无 toggle/reload 行）。触发面是**部署/重启验证流程本身**，不是用户操作。
  - **持续性（05:18:07 复测，同一 PID）**：TTS `HTTP 200 / 0.0073 s / {"success":false,"error":"No module named 'spacy'"}`；STT `HTTP 200 / 0.0059 s / {"success":false,"error":"module 'whisper' has no attribute 'load_model'","text":""}`。隔 18 分钟仍同样失败，**持续坏，非偶发**。
- **M2 超长输入的上限在 HTTP 层不可达。** 5,500 字先撞 Paradee（spacy），永远走不到 `SpeechInputTooLong`；1,200 字上限只在部署层可见，且错误以 200 返回。
- **M3 OCR 默认预算到不了页数上限。** `A0_OCR_MAX_PAGES=4` 的逻辑本身正确：`per_document_timeout=300` 时 54.25 s 跑完 4/5 页并给出正确尾注。但默认 45 s/页 + 135 s 文档预算只能出 2/5（C14、C14b），尾注报 `timeout after 45.0s` / `130.0s document budget ran out`，用户看不到“页数上限”这个真实原因。
- **M4 截断 PDF 静默降级为空文档。** `trunc50`、`trunc10` 都 `ok=true`，返回 `0 of 5 pages` 注释，白跑 45 s，stderr 54 条 MuPDF `object out of range`；`ValueError: PDF could not be read` 分支永远走不到。
- **M5 低分辨率无拒识。** 100×50 图返回无关的数学题文本，`ok=true`，没有 `OCR incomplete` 标记；调用方无法区分“识别”和“编造”。
- **M6 STT 无静音判定。** 1 s 静音返回 `Oh,`，1 s 噪声返回 `Okay.`，0.2 s 返回 `So,`，全部 `success:true`；`silence_threshold` 配置在补丁路径中未使用。
- **M7 中文回灌被识别为英文。** B6 的 19 字中文合成音频返回英文译文（`language=english`），字符相似度接近 0；语义正确但语言与原文不一致。
- **M8 空字符串被静默编码。** D20 返回非零 2560 维单位向量，调用方无法从返回值区分空文本；空输入没有任何错误或空向量。
- **M9（观察，未定性）空闲期资源不回落。** 05:11–05:13 本组已无调用，实例 RSS 仍从 701 MB 升至 778 MB、fd 从 208 升至 334，并保持 17 条到 `127.0.0.1:18080` 的 ESTAB 连接。共享实例上还有其它会话，不能归因于本轮用例，但“空闲不回落”与 probe-stability 记录的 fd 锯齿不同，建议单独复测。

## 5. 与既有结论的差异

| 既有 | 本轮实测 | 说明 |
|---|---|---|
| TTS 2.56 s | HTTP 层不可用；部署层 5.26 s / 25.24 s，音频 3.84/4.32 s | 既有值来自**同一 PID** 04:44–04:50（补丁尚未被 04:53:47 的重刷清除）；05:00 起补丁失效 |
| OCR 3.5 s / 39 字符 | C11 1.245 s / 86 字符（首跑 9.52 s） | 模型已热；字符数翻倍因本轮图片内容不同 |
| 维度 2560 | 2560，20/100 条均一致 | 一致 |
| 5 页 4/5 | 默认 2/5（`timeout after 45.0s`）；`A0_OCR_TIMEOUT=135` 仍 2/5（130 s 预算耗尽）；只有 `per_document_timeout=300` 的历史配置达到 4/5 | 既有 4/5 不是默认配置的结果；本轮两档预算都没到 4 页 |
| commit `ab3d8e61` | 源码 `058582f-dirty` / 包 commit `ab3d8e61` | 两者是不同层：源码状态 vs ostree commit，同一构建，非版本差异 |
