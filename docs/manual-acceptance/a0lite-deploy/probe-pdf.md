# F 类（OCR 与文档解析）边界路径实机验收

执行时间：2026-11-18 02:19–02:38（Asia/Shanghai）
执行者：probe-pdf
对象：`org.agentzero.AgentZero`，Flatpak user 安装，commit `7a55c085a2…`（v10），运行中，`127.0.0.1:5080`。
约束遵守：未改仓库源码、未改 `conf/`、未重启 5080 实例；全部用例用 `flatpak run --user --command=sh` 子进程执行，`A0_OCR_*` 只存在于子进程环境；测试件在 `~/a0-shots/pdf-probe/`。

---

## 0. 结论摘要

| # | 用例 | 判定 | 关键数据 |
|---|---|---|---|
| 1 | 数字 PDF 走文本提取 | **通过** | 0.062 s，输出与写入文本逐字一致 |
| 2 | 3 页扫描 PDF | **部分通过** | 55.28 s，2/3 页（`timeout after 7s`）；预算 300 s 时 63.62 s、3/3 页、无截断 |
| 3 | 5 页扫描 PDF（默认配置） | **不满足期望** | 54.40 s，2/5 页（`the 55s document budget ran out`），未命中 `A0_OCR_MAX_PAGES=4` |
| 4 | 5 页扫描 PDF（预算 300 s） | **通过** | 64.77 s，4/5 页（`A0_OCR_MAX_PAGES=4`），页数上限逻辑正确 |
| 5 | `pdf_ocr_fallback=false` | **通过** | 0.136 s，返回 `""`，`OLLAMA_HOST` 指向死端口仍无连接错误 |
| 6 | `A0_OCR_TIMEOUT=2`（3 页） | **通过** | 2.259 s，`> OCR incomplete: 0 of 3 pages processed (timeout after 2s).` |
| 7 | `A0_OCR_TIMEOUT=0.01`（3 页） | **通过** | 0.361 s，`> OCR incomplete: 0 of 3 pages processed (timeout after 0s).` |
| 8 | `A0_OCR_TIMEOUT=0.01`（单张 PNG） | **通过** | 0.015 s，`> OCR incomplete: the vision request did not finish within 0s.` |
| 9 | `per_document_timeout=10`（5 页） | **通过（语义为 0 页）** | 0.294 s，`0 of 5 pages processed (the 5s document budget ran out)` |
| 10 | `per_document_timeout=60`（5 页） | **复现用例 3** | 52.98 s，2/5 页 |
| 11 | 空 content | **通过** | 0.117 s，返回 `""`，不崩 |
| 12 | 非 PDF 字节 | **通过（异常未统一包装）** | 0.173 s，`pymupdf.FileDataError: Failed to open stream` |
| 13 | 1×1 PNG | **不满足断言** | 31.62 s，返回 `""`；不崩，但没有 `OCR incomplete` 说明 |
| 14 | 表格/公式质量 | **如实记录** | 表格 OTSL 结构完整；公式是 `\[...\]`，分式未用 `\frac` |

一句话：**视觉回退、超时降级、关闭回退、页数上限四套机制都按设计工作；真正的问题是单页扫描页要 20–25 s，默认 60 s 文档预算只够 2 页，3 页以上的扫描件在默认配置下必然截断。**

---

## 1. 环境与前置

### 1.1 应用与运行时

```text
$ ss -ltnp | grep 5080
LISTEN 0 2048 127.0.0.1:5080 0.0.0.0:* users:(("python",pid=1913196,fd=31))

$ pgrep -af run_ui.py
1913196 .../venv/bin/python -c import a0flatpak; a0flatpak.apply();
        import runpy; runpy.run_path('run_ui.py', run_name='__main__') --port=5080 --host=127.0.0.1
```

`/health` 为 404，`/api/health` 为 200，body 是
`{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}`。
这与 `README.md` 的 Known limitations 一致：`/api/health` 200，`error` 字段是 git probe 对数据目录的 `InvalidGitRepositoryError` 文本，不是本次验收引入。

注：5080 进程在 02:21 被外部重启（旧 PID 1912059 → 新 PID 1913196），不是本验收触发；本验收从 02:19 起只做只读探测与独立子进程解析。

### 1.2 运行时文件与仓库一致

```text
$ flatpak run ... sha256sum flatpak/a0flatpak/ocr.py flatpak/a0flatpak/parsers.py
b01782702bf0ddef0226bdd42b55af240679350263c9a485f8b28e17e94c9627  flatpak/a0flatpak/ocr.py
79c415edd4680b625e7d75118553e3dd957d4097c7cb5c8deb0a5b6ec61a75b7  flatpak/a0flatpak/parsers.py
```

与宿主仓库 `flatpak/a0flatpak/{ocr,parsers}.py` 的 sha256 相同。下文所有行为都对应这两份文件。

### 1.3 Ollama

```text
$ curl -s http://127.0.0.1:11434/api/ps | jq -c '[.models[].name]'
["qwen3-embedding:4b-q4_K_M"]
```

- 模型：`xiaomi-ocr:latest`（`/api/tags` 可见）。
- `OLLAMA_MAX_LOADED_MODELS=1`：每次 OCR 前 xiaomi-ocr 会被加载，embedding 请求穿插时会互相换出；下面的 `elapsed_seconds` 含这部分加载时间。
- 用例结束后已卸载：

```text
$ curl -s -X POST http://127.0.0.1:11434/api/generate \
    -d '{"model":"xiaomi-ocr","keep_alive":0}' | jq -c '{model,done,done_reason}'
{"model":"xiaomi-ocr","done":true,"done_reason":"unload"}

$ curl -s http://127.0.0.1:11434/api/ps | jq -c '.models'
[]
```

### 1.4 沙盒前置（每条用例原样使用）

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export A0_BASE_DIR="$B" GIT_PYTHON_REFRESH=quiet
export PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
cd /app/share/agent-zero
"$B/venv/bin/python" "$HOME/a0-shots/pdf-probe/probe.py" <case>'
```

沙盒内 `HOME=/home/kunweiz`，与宿主相同，所以 `~/a0-shots/pdf-probe/` 两边是同一目录。

### 1.5 调用代码

`probe.py` 先 `import a0flatpak; a0flatpak.apply()`，再直接调用解析器：

```python
from plugins._document_query.helpers.fetch import FetchedDocument
from plugins._document_query.helpers.parsers.pdf import PdfParser
from plugins._document_query.helpers.parsers.image import ImageParser

def file_document(name, mimetype):
    path = os.path.join(BASE, name)
    with open(path, "rb") as handle:
        content = handle.read()
    return FetchedDocument(
        uri=path, scheme="file", mimetype=mimetype,
        content=content, local_path=path,
    )

# PDF
PdfParser()._parse_sync(document, config)
# 图片
ImageParser()._parse_sync(document, config)
```

`FetchedDocument` 的字段取自 `helpers/fetch.py:23-33`（frozen dataclass：`uri / scheme / mimetype / content / encoding / charset / local_path / source_uri`）。`_parse_sync` 内部通过 `document.local_file()` 取路径；本验收传 `local_path`，避免临时文件噪声。

`import_seconds` 是每条子进程冷导入（约 3.5–5.4 s），不计入 `elapsed_seconds`。

---

## 2. 测试件

### 2.1 生成方法

- 3 张 PNG（中文表格、公式、纯文本）用 ImageMagick `convert`，字体
  `/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc`（`fc-match -f '%{file}' 'Noto Sans CJK SC'` 的结果）。
- `scan3.pdf` / `scan5.pdf` 用沙盒 venv 里的 PyMuPDF 1.25.3：每页 `insert_image`，无文本层（`gen_pdf.py`）。
- `digital.pdf` 用 PyMuPDF `insert_text`，`china-s` 写中文、`helv` 写英文。
- `onepx.png` 是 ImageMagick 生成的 1×1 白图。

### 2.2 路径

```text
/home/kunweiz/a0-shots/pdf-probe/
├── table.png     12564 B
├── formula.png   11221 B
├── text.png      30182 B
├── onepx.png       294 B
├── digital.pdf    1694 B
├── scan3.pdf     49321 B
├── scan5.pdf     49989 B
├── gen_pdf.py / probe.py / inspect.txt / results/
```

### 2.3 `identify` 与 `pdfinfo` 原文

```text
$ identify table.png formula.png text.png onepx.png
table.png PNG 1200x800 1200x800+0+0 8-bit Grayscale Gray 256c 12564B
formula.png PNG 1200x800 1200x800+0+0 8-bit Grayscale Gray 256c 11221B
text.png PNG 1200x800 1200x800+0+0 8-bit Grayscale Gray 256c 30182B
onepx.png PNG 1x1 1x1+0+0 8-bit Grayscale Gray 2c 294B

$ pdfinfo digital.pdf | grep -E '^(Pages|Encrypted|Page size|File size|PDF version)'
Pages:           1
Encrypted:       no
Page size:       612 x 792 pts (letter)
File size:       1694 bytes
PDF version:     1.7

$ pdfinfo scan3.pdf | grep -E '^(Pages|Encrypted|Page size|File size|PDF version)'
Pages:           3
Encrypted:       no
Page size:       612 x 792 pts (letter)
File size:       49321 bytes
PDF version:     1.7

$ pdfinfo scan5.pdf | grep -E '^(Pages|Encrypted|Page size|File size|PDF version)'
Pages:           5
Encrypted:       no
Page size:       612 x 792 pts (letter)
File size:       49989 bytes
PDF version:     1.7
```

文本层校验（沙盒内 PyMuPDF）：

```text
scan3.pdf: pages=3
  page 1: text_len=0 images=1
  page 2: text_len=0 images=1
  page 3: text_len=0 images=1
scan5.pdf: pages=5
  page 1: text_len=0 images=1
  ...
digital.pdf: pages=1
  page 1: text_len=71 images=0
    text='这是一份数字 PDF 测试文档。\n第二段：文本提取应当直接返回这段内容。\nDigital PDF text layer check 2026.'
```

`pdftotext scan3.pdf - | wc -c` 为 `3`（只有换行），确认扫描件无文本层。

---

## 3. 用例逐条

### 3.1 数字 PDF：走文本提取（任务 2a）

**目的**：确认 `PdfParser._parse_sync` 对带文本层的 PDF 直接返回文本，而不是送视觉模型。

**代码**：

```python
document = file_document("digital.pdf", "application/pdf")
t = time.monotonic()
out = PdfParser()._parse_sync(document, {})
```

**原始输出**：

```json
{"case": "digital", "import_seconds": 3.622, "parser": "PdfParser",
 "config": {}, "elapsed_seconds": 0.062, "ok": true,
 "output": "这是一份数字 PDF 测试文档。\n第二段：文本提取应当直接返回这段内容。\nDigital PDF text layer check 2026."}
```

**期望**：非空；耗时 < 5 s；内容与写入文本一致。

**实际**：0.062 s；输出与 `insert_text` 写入的 3 行逐字一致；无 `OCR incomplete`；调用前后 `/api/ps` 只有 `qwen3-embedding`。

**结论**：**通过**。0.062 s 与视觉路径的 4–25 s 差两个数量级，可确认走的是 PyMuPDFLoader 文本提取，不是视觉。

---

### 3.2 3 页扫描 PDF（默认配置）

**目的**：确认扫描件触发视觉回退；记录耗时、页数；检查 `A0_OCR_MAX_PAGES=4` 是否命中。

**代码**：

```python
document = file_document("scan3.pdf", "application/pdf")
out = PdfParser()._parse_sync(document, {})   # 默认 config
```

**原始输出**：

```json
{"case": "scan3", "import_seconds": 4.004, "parser": "PdfParser",
 "config": {}, "elapsed_seconds": 55.282, "ok": true, "output_len": 253}
```

stdout 另有一行被吞掉的原策略错误：

```text
Error: PyMuPDF parsing failed: Cannot handle this data type: (1, 1, 1), |u1
```

正文（253 字符）：

```text
<fcel>姓名<fcel>年龄<fcel>城市<nl><ecel><ecel><ecel><nl><fcel>张三<fcel>28<fcel>北京<nl><ecel><ecel><ecel><nl><fcel>李四<fcel>35<fcel>上海<nl>

公式测试

\[E = mc^2\]

\[a^2 + b^2 = c^2\]

\[x + 1\]

\[x - 1\]

> OCR incomplete: 2 of 3 pages processed (timeout after 7s).
```

**期望**：非空；包含 3 页内容或 `> OCR incomplete:` 说明；3 页应全处理（上限 4 页）。

**实际**：非空；有截断说明；**只处理 2 页**，第 3 页在剩余 7 s 时超时。总耗时 55.28 s，其中 OCR 预算是 `per_document_timeout(60) - OCR_MARGIN(5)` = 55 s，另有约 0.3 s 页面渲染。单页实测约 20–28 s（Ollama 日志 `/api/chat` 20.78–28.24 s），所以 55 s 只够 2 页。

**补充：预算充足时的同一文件**。传 `{"per_document_timeout": 300}`：

```json
{"case": "scan3_long", "elapsed_seconds": 63.622, "ok": true,
 "output_len": 279}
```

```text
<fcel>姓名<fcel>年龄<fcel>城市<nl><ecel><ecel><ecel><nl><fcel>张三<fcel>28<fcel>北京<nl><ecel><ecel><ecel><nl><fcel>李四<fcel>35<fcel>上海<nl>

公式测试

\[E = mc^2\]

\[a^2 + b^2 = c^2\]

\[x + 1\]

\[x - 1\]

这是一段用于 OCR 测试的中文文本。

第二行包含数字 12345 和英文 Agent Zero。

第三行：扫描件应当被识别为可读的 Markdown。

第四行结束。
```

3 页全部处理，**没有** `OCR incomplete` 行；`output_len` 279，正好三页。63.62 s 也说明默认 55 s 预算差一点点：3 页需要约 64 s。

**结论**：**部分通过**。视觉回退本身工作正常，输出质量良好；但默认预算下 3 页扫描件无法完整解析。`A0_OCR_MAX_PAGES=4` 未被命中——先被文档预算截断。

---

### 3.3 5 页扫描 PDF（默认配置）

**目的**：断言只处理 4 页，并出现 `OCR incomplete: 4 of 5 pages`。

**代码**：

```python
document = file_document("scan5.pdf", "application/pdf")
out = PdfParser()._parse_sync(document, {})
```

**原始输出**：

```json
{"case": "scan5", "import_seconds": 4.104, "elapsed_seconds": 54.401,
 "ok": true, "output_len": 268}
```

```text
<fcel>姓名<fcel>年龄<fcel>城市<nl>...
公式测试 ...
\[E = mc^2\]
...
> OCR incomplete: 2 of 5 pages processed (the 55s document budget ran out).
```

**期望**：`> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).`

**实际**：`2 of 5`，原因是 `the 55s document budget ran out`，不是页数上限。

**结论**：**不满足期望**（但机制无错：预算在页数上限之前耗尽）。这是本报告中影响最大的可用性问题。

---

### 3.4 5 页扫描 PDF（预算 300 s，验证页数上限）

**目的**：绕开 60 s 默认预算，单独验证 `A0_OCR_MAX_PAGES=4`。

**代码**：

```python
PdfParser()._parse_sync(document, {"per_document_timeout": 300})
```

**原始输出**：

```json
{"case": "scan5_long", "elapsed_seconds": 64.771, "ok": true, "output_len": 473}
```

```text
<表格页 1>...
公式页 ...
纯文本页 ...
<表格页 4>...
> OCR incomplete: 4 of 5 pages processed (A0_OCR_MAX_PAGES=4).
```

**期望**：4 页 + `A0_OCR_MAX_PAGES=4` 说明。

**实际**：完全一致；4 页耗时 64.77 s（热态约 16 s/页）。

**结论**：**通过**。页数上限逻辑正确；默认配置的问题是预算，不是页数上限。

---

### 3.5 `pdf_ocr_fallback=false`（任务 3）

**目的**：关闭回退时不触发视觉，且不产生任何 Ollama 请求。

**代码**：

```python
config = {"pdf_ocr_fallback": False}
out = PdfParser()._parse_sync(document, config)
```

子进程额外设置 `OLLAMA_HOST=http://127.0.0.1:59999`（死端口）。若代码仍走视觉，必然出现 `ConnectError`。

**原始输出**：

```json
{"case": "fallback_off", "import_seconds": 4.048,
 "env": {"OLLAMA_HOST": "http://127.0.0.1:59999"},
 "config": {"pdf_ocr_fallback": false},
 "elapsed_seconds": 0.136, "ok": true, "output": ""}
```

stdout 只有原策略的本地错误：

```text
Error: PyMuPDF parsing failed: Cannot handle this data type: (1, 1, 1), |u1
```

**期望**：不触网；耗时 < 2 s；返回空或原始异常文本；无 `ConnectError`。

**实际**：0.136 s；返回 `""`；无连接错误；调用前后 `/api/ps` 都只有 `qwen3-embedding`，没有 xiaomi-ocr 加载记录。

**结论**：**通过**。这是比"看日志"更强的判据：指向死端口仍能正常返回，说明视觉分支根本没被进入。

---

### 3.6 超时语义：`A0_OCR_TIMEOUT=2`（3 页扫描）

**目的**：确认单页超时降级为 Markdown 说明，而不是抛异常。

**代码**：子进程 `export A0_OCR_TIMEOUT=2`，默认 config，调 `scan3.pdf`。

**原始输出**：

```json
{"case": "timeout2", "env": {"A0_OCR_TIMEOUT": "2"},
 "elapsed_seconds": 2.259, "ok": true,
 "output": "> OCR incomplete: 0 of 3 pages processed (timeout after 2s)."}
```

**期望**：以 `> OCR incomplete:` 开头；不抛异常；记录处理页数。

**实际**：完全一致；0 页；2.259 s 返回。

**结论**：**通过**。客户端 2.259 s 返回时只是关闭了 httpx 连接；Ollama 日志里扫描页的 `/api/chat` 请求都在 20–28 s 后以 200 完成（本次 20.78–28.24 s），说明断开的请求不会留下客户端可见的异常，但服务端计算是否立即停止不在本条判据内。

---

### 3.7 超时语义：`A0_OCR_TIMEOUT=0.01`（3 页扫描）

**目的**：断言极端超时返回 `> OCR incomplete:`，不是 `ValueError`。

**代码**：子进程 `export A0_OCR_TIMEOUT=0.01`；`PdfParser()._parse_sync(scan3, {})`。

**原始输出**：

```json
{"case": "timeout001", "env": {"A0_OCR_TIMEOUT": "0.01"},
 "elapsed_seconds": 0.361, "ok": true,
 "output": "> OCR incomplete: 0 of 3 pages processed (timeout after 0s)."}
```

**期望**：返回以 `> OCR incomplete:` 开头的 Markdown，不抛 `ValueError`。

**实际**：0.361 s；0 页；文本以 `> OCR incomplete:` 开头。

**结论**：**通过**（不抛异常）。文案 `timeout after 0s` 是 `:.0f` 的显示结果，实际值是 0.01；见问题 P4。

---

### 3.8 超时语义：`A0_OCR_TIMEOUT=0.01`（单张 PNG）

**目的**：验证单页图片路径（`ImageParser` → `_parse_image`）的超时分支。

**代码**：子进程 `export A0_OCR_TIMEOUT=0.01`；`ImageParser()._parse_sync(text.png, {})`。

**原始输出**：

```json
{"case": "timeout001_img", "env": {"A0_OCR_TIMEOUT": "0.01"},
 "elapsed_seconds": 0.015, "ok": true,
 "output": "> OCR incomplete: the vision request did not finish within 0s. The image was not converted."}
```

**期望**：返回 `> OCR incomplete:` 说明，不抛 `ValueError`。

**实际**：0.015 s，返回上述说明。

**结论**：**通过**。单页路径没有 `ValueError`，返回可读说明。

---

### 3.9 `per_document_timeout=10`（5 页扫描）

**目的**：确认 10 s 内返回、含截断说明、不挂死。

**代码**：`PdfParser()._parse_sync(scan5, {"per_document_timeout": 10})`。

**原始输出**：

```json
{"case": "budget10", "config": {"per_document_timeout": 10},
 "elapsed_seconds": 0.294, "ok": true,
 "output": "> OCR incomplete: 0 of 5 pages processed (the 5s document budget ran out)."}
```

**期望**：10 s 内返回（含截断说明），不挂死。

**实际**：0.294 s，含说明，不挂死；但处理 0 页。原因是 `_document_budget` 把 `10 - OCR_MARGIN(5) = 5` 作为全部预算，而页循环的第一道判断是 `remaining <= OCR_MARGIN`；函数开销让 `remaining` 略小于 5，立刻命中，一页都没发。

**结论**：**通过（按"不挂死 + 有说明"判据）**；语义上 10 s 实际等于 0 页，见问题 P2。

---

### 3.10 `per_document_timeout=60`（5 页扫描）

**目的**：与 10 s 对比，确认预算增大后的页数与耗时差异。

**代码**：`PdfParser()._parse_sync(scan5, {"per_document_timeout": 60})`。

**原始输出**：

```json
{"case": "budget60", "config": {"per_document_timeout": 60},
 "elapsed_seconds": 52.979, "ok": true,
 "output": "... > OCR incomplete: 2 of 5 pages processed (the 55s document budget ran out)."}
```

**与 10 s 的差异**：

| per_document_timeout | 内部预算 | 耗时 | 处理页数 | 截断原因 |
|---|---|---|---|---|
| 10 | 5 s | 0.294 s | 0 | `the 5s document budget ran out` |
| 60 | 55 s | 52.979 s | 2 | `the 55s document budget ran out` |

**期望**：在 60 s 内返回，含截断说明；页数应多于 10 s 的情况。

**实际**：52.979 s，2 页，说明为 `the 55s document budget ran out`。

**结论**：60 s 与 `scan5` 默认结果一致，两次相差 1.4 s，属模型加载/热态波动；可复现。

---

### 3.11 空 content

**目的**：空字节不应崩，也不应触网。

**代码**：`FetchedDocument(uri=".../empty.pdf", content=b"", mimetype="application/pdf")`；`PdfParser()._parse_sync(document, {})`。

**原始输出**：

```json
{"case": "empty", "elapsed_seconds": 0.117, "ok": true, "output": ""}
```

stdout 有被吞的原策略错误：`Error: PyMuPDF parsing failed: Cannot open empty file...`。

**期望**：返回 `""`，不崩。

**实际**：`""`，0.117 s。

**结论**：**通过**。

---

### 3.12 非 PDF 字节

**代码**：`FetchedDocument(uri=".../notpdf.pdf", content=b"not a pdf", mimetype="application/pdf")`。

**原始输出**：

```json
{"case": "notpdf", "elapsed_seconds": 0.173, "ok": false,
 "error_type": "FileDataError", "error": "Failed to open stream",
 "traceback_tail": ["document = pymupdf.open(stream=content, filetype=\"pdf\")",
                    "raise FileDataError(f'Failed to open stream') from e"]}
```

**期望**：异常可读（含类型与原因），不是裸 traceback。

**实际**：`FileDataError: Failed to open stream`——类型与原因都可见，没有被脚本之外的裸 traceback 打断；但它是 PyMuPDF 的原始异常，不是统一 `ValueError`。此前 `_parse_with_pymupdf` 已经吞掉了更具体的一条 `Failed to open file '/tmp/...pdf'`。

**结论**：**通过（可读）**；异常类型不统一，见问题 P4。

---

### 3.13 1×1 像素 PNG

**目的**：极小图片不应崩，至少要给出可读结果或降级说明。

**代码**：`ImageParser()._parse_sync(file_document("onepx.png", "image/png"), {})`。

**原始输出**：

```json
{"case": "onepx", "elapsed_seconds": 31.624, "ok": true, "output": ""}
```

`identify onepx.png`：`PNG 1x1 1x1+0+0 8-bit Grayscale Gray 2c 294B`。

**期望**：返回非空，或可读的 `OCR incomplete`，不崩。

**实际**：31.62 s 后返回 `""`；不崩，但既没有内容也没有说明。Ollama 日志显示该请求 `POST /api/chat` 用时 31.61 s、返回 200，模型对 1×1 图输出空字符串。`_parse_image` 把空字符串原样返回。上游 `_parse_document` 会把 `""` 当作"本 parser 无结果"继续下一个候选（`UnstructuredParser`），最终可能给用户一个空文档而没有解释。

**结论**：**不满足断言**。见问题 P3（中）。

---

## 4. 表格与公式质量（非断言）

### 4.1 中文表格页

返回原文（完整，共 5 个 OTSL 行）：

```text
<fcel>姓名<fcel>年龄<fcel>城市<nl><ecel><ecel><ecel><nl><fcel>张三<fcel>28<fcel>北京<nl><ecel><ecel><ecel><nl><fcel>李四<fcel>35<fcel>上海<nl>
```

- 结构：`<fcel>`（表头/内容单元格）、`<ecel>`（空单元格）、`<nl>`（换行）都是 OTSL 标记；三列表头与两行数据齐全，列序正确。
- 缺陷：每行数据后多插了一行全空 `<ecel>` 行——对应图片里表格线之间的空白带，模型把线当成了空行。内容没有丢失。

### 4.2 公式页

返回原文（完整）：

```text
公式测试

\[E = mc^2\]

\[a^2 + b^2 = c^2\]

\[x + 1\]

\[x - 1\]
```

- 标题正确；两条公式用 LaTeX 行间公式 `\[...\]` 保留，`^2` 正确。
- 分式 `(x+1)/(x-1)` 被拆成两个独立公式 `\[x + 1\]`、`\[x - 1\]`，**没有** `\frac`。公式语义丢失。
- 上游 README 已声明 Q4_K_M 精度未评估；本结果与"能识别但结构不完整"一致。

### 4.3 纯文本页（对照）

`text.png` 走 `ImageParser`：

```json
{"case": "image_text", "elapsed_seconds": 4.133, "ok": true,
 "output": "这是一段用于 OCR 测试的中文文本。\n\n第二行包含数字 12345 和英文 Agent Zero。\n\n第三行：扫描件应当被识别为可读的 Markdown。\n\n第四行结束。"}
```

四行逐字正确，数字与英文混排也正确；耗时 4.13 s，与 README 的 3.5–6.3 s 一致。

---

## 5. 发现的问题

### P1（高）默认 60 s 预算不足，3 页以上扫描件必然截断

- 实测单页扫描页 OCR 20–28 s（Ollama 日志：20.78、20.85、20.87、21.06、21.88、22.81、24.69、25.43、25.76、27.90、28.24 s），而 `_document_budget` 只给 `per_document_timeout(60) - OCR_MARGIN(5) = 55 s`。
- 3 页 → 2 页后 `timeout after 7s`；5 页 → 2 页后 `the 55s document budget ran out`。
- `A0_OCR_MAX_PAGES=4` 在默认配置下几乎不可达；用户拿到的是"前两页 + 一行引用说明"。
- 影响：任何 3 页以上的扫描合同/发票/试卷，默认设置下都会静默丢掉后半部分。
- 证据：3.2、3.3、3.4、3.10。

### P2（中）`per_document_timeout=10` 时预算被 margin 吃光，0 页且不发请求

- `_document_budget` 返回 `max(10 - 5, 5) = 5`；`_ocr_pages` 的第一道判断 `remaining <= OCR_MARGIN` 对约 4.99 s 成立，循环立即 `break`。
- 结果 `> OCR incomplete: 0 of 5 pages processed (the 5s document budget ran out).`，耗时 0.294 s。
- 用户把超时设为 10 s，期望"至少处理一页"，实际一页都不发。
- 证据：3.9。

### P3（中）1×1 图返回空字符串，没有降级说明

- `_parse_image` 对模型返回的空内容不做区分，直接返回 `""`；不像超时那样输出 `> OCR incomplete:`。
- 上游会把它当作"无结果"继续下一个 parser，最终用户可能得到空文档且不知道原因。
- 证据：3.13。

### P4（低）非 PDF 异常未统一包装

- `_parse_pdf_with_fallback` 只把超时转成说明；非超时异常直接上抛，`_pdf_pages` 的 `pymupdf.FileDataError` 没有转成 `ValueError`。
- 同时 `original` 的异常被无条件吞掉（`try/except: text = ""`），更具体的 `Failed to open file` 丢失，只剩 `Failed to open stream`。
- 证据：3.12。

### P5（低）超时文案精度不足

- `timeout after {min(...):.0f}s` 把 0.01 s 显示成 `0s`，把 7.4 s 显示成 `7s`。
- "timeout after 0s" 读起来像逻辑错误，实际是格式化截断。
- 证据：3.7、3.6。

### P6（信息）Ollama 单模型限制放大延迟

- `OLLAMA_MAX_LOADED_MODELS=1` 下，OCR 与 embedding 交替时 xiaomi-ocr 反复加载；`/api/chat` 日志中多次出现 `starting llama-server` + `model loaded`。
- 单页耗时里含模型加载；这是环境约束，不是解析器 bug，但会让 P1 更容易发生。

---

## 6. 对照 `test-matrix.md` 的 F 类（C33–C39）

| CASE | 矩阵期望 | 本次实测 | 状态 |
|---|---|---|---|
| C33 图片 → Markdown | `len > 0`；文本含 `42`；`OCR_OK` | 上次已验单图正常路径；本次 `text.png` 4.13 s，4 行逐字正确；1×1 边界返回空 | **通过**（正常路径）；边界见 P3 |
| C34 数字 PDF 文本提取 | `len > 0`；含 `A0 PDF PROBE 42`；`OCR_OK` | 0.062 s，3 行与写入文本逐字一致 | **通过** |
| C35 扫描 PDF 视觉回退 | `len > 0`；含 `42`；`OCR_OK` | 回退发生，表格/公式/文本三页内容正确；默认 3 页只完成 2 页，预算 300 s 时 3/3 | **部分通过**：回退可用，页数完整性不达标（P1） |
| C36 `pdf_ocr_fallback=false` | 返回空；`NO_FALLBACK_OK`；无 `ConnectError` | 0.136 s，`""`，死端口零连接 | **通过** |
| C37 多页超时 | 打印 `EXC:` 与 `TIMEOUT_OK`；异常消息含 timeout | 返回 `> OCR incomplete: 0 of 3 pages processed (timeout after 2s).`，不抛异常 | **判据已过时**：当前产品语义按任务 4 要求返回 Markdown 引用行；按旧矩阵"必须抛异常"的写法会误判。建议把 C37 期望改为"以 `> OCR incomplete:` 开头，消息含 timeout" |
| C38 OCR 模型缺失 | `EXC:` 与 `MODEL_MISSING_OK`；消息含 404/not found | `A0_OCR_MODEL=no-such-model:latest` → `ValueError: OCR failed within 45s: HTTPStatusError: Client error '404 Not Found' ...`，0.008 s | **通过** |
| C39 损坏 PDF | `EXC:` 与 `BADFILE_ERR_OK`；消息可读（≤4 KB，无裸 Traceback） | `FileDataError: Failed to open stream`，0.173 s | **通过**（可读；类型未统一，见 P4） |

C37 的差异需要单独说明：`test-matrix.md` 写的是"异常消息含 timeout/timed out"，而 `a0flatpak/ocr.py` 从 D4 起把超时设计成 Markdown 引用行（`> OCR incomplete:`），本任务第 4 条也明确要求"不是抛异常"。两者不可能同时成立，矩阵该行应更新，否则后续验收会按错误判据判失败。

---

## 7. 清理与环境复原

```text
$ curl -s -X POST http://127.0.0.1:11434/api/generate \
    -d '{"model":"xiaomi-ocr","keep_alive":0}'
{"model":"xiaomi-ocr","done":true,"done_reason":"unload"}

$ curl -s http://127.0.0.1:11434/api/ps | jq -c '.models'
[]
```

- 未改仓库源码、`conf/`、运行中的 `settings.json`；未重启 5080。
- 测试件与原始结果保留在 `~/a0-shots/pdf-probe/`（`results/*.json` 是每条用例的机器可读原文，`results-summary.jsonl` 是汇总）。
- `probe.py` 与 `gen_pdf.py` 是可复现脚本，均已留在同目录。
