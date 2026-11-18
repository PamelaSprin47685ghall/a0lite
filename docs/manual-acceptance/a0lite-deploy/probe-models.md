# 本地模型探针：嵌入（D 类）与语音（E 类）

- 日期：2026-11-18（01:20–01:40 +08:00）
- 对象：Flatpak user 安装 `org.agentzero.AgentZero`，commit `0e6c50820257d7b409f2c8dc5ccd0688d693fea648436669c3fd59af84d456a4`
- 运行实例：`http://127.0.0.1:5080`（未重启），Ollama `http://127.0.0.1:11434`
- 沙盒 Python：`~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python`
- 框架：`/app/share/agent-zero`；补丁：`/app/share/agent-zero/flatpak/a0flatpak`
- 产物目录：`~/a0-shots/`（`tts-probe.wav`、`tts-long300.wav`、探针脚本与日志）

## 0. 环境与前置

### 0.1 固定的沙盒前置

所有命令都走这一层包装，下文只列 `<python 代码>` 或脚本路径：

```sh
flatpak run --user --command=sh org.agentzero.AgentZero -c '
B="$HOME/.var/app/org.agentzero.AgentZero/data/agent-zero"
export A0_BASE_DIR="$B" GIT_PYTHON_REFRESH=quiet
export PYTHONPATH=/app/share/agent-zero:/app/share/agent-zero/flatpak:/app/share/python-deps
cd /app/share/agent-zero
"$B/venv/bin/python" "$HOME/a0-shots/<脚本>.py"
'
```

### 0.2 5080 health

```
$ curl -s -o /dev/null -w 'HTTP %{http_code} %{time_total}s\n' http://127.0.0.1:5080/api/health
HTTP 200 0.011578s
$ curl -s http://127.0.0.1:5080/api/health
{"gitinfo": null, "error": "/home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero"}
```

状态码 200，但 body 的 `error` 字段直接给出数据目录路径。这不像错误，更像 health 端点把某个可选字段（git 信息）的空值路径化了。**监控若只看 HTTP 码，会把这个 body 当成健康；若解析 `error` 非空，会误报警。** 记为低严重度语义问题（见 §3 P3-1）。

### 0.3 Ollama 实际加载情况

开测时 `qwen3-embedding` 已被前序工作加载（`expires_at` 约 10 分钟后）。D 组直接用热模型跑完，结束时显式卸载：

```
$ curl -s -X POST http://127.0.0.1:11434/api/generate \
    -d '{"model":"qwen3-embedding:4b-q4_K_M","keep_alive":0}'
{"model":"qwen3-embedding:4b-q4_K_M",...,"done_reason":"unload"}
$ curl -s http://127.0.0.1:11434/api/ps
{"models":[]}
```

TTS/STT 之后：

```
$ curl -s http://127.0.0.1:11434/api/ps
{"models":[{"name":"lfm3-omni:2b-q4_K_M","model":"lfm3-omni:2b-q4_K_M",
"size":1389101054,"digest":"4c0ee9400634babb880868b873bcebf09fbbf1a5328e550bdbaff25888f1f7e2",
"details":{"format":"gguf","family":"lfm3","parameter_size":"1.7B","quantization_level":"Q4_K_M"},
"size_vram":0,"context_length":4096,"runner":"llamacpp",
"expires_at":"2026-11-18T01:40:49+08:00"}]}
```

`size` 是内存驻留量（1.39 GB），与磁盘 2.00 GB 不同。`size_vram=0`，纯 CPU 推理。

宿主内存实测（`free -m`）：total 63496 MiB、available 47921 MiB。任务描述中的 “available 约 6 GB” 与实测不符；本次串行执行没有遇到内存压力，但仍按串行纪律执行。

### 0.4 串行纪律

嵌入组（D）与语音组（E）分时执行。D 组结束后 `keep_alive:0` 卸载 `qwen3-embedding`，`/api/ps` 为空后才开始 E 组。E 组结束后同样卸载 `lfm3-omni`（见 §4 清理）。

---

## 1. D 类：嵌入与记忆

### D1 嵌入维度

**目的**：确认 `models.get_embedding_model` 被 a0flatpak 替换为 Ollama 后端，维度为 2560。

**命令**（`~/a0-shots/d1_embed.py`）：

```python
import time
import a0flatpak; a0flatpak.apply()
import models
t0=time.time()
m = models.get_embedding_model("huggingface", "qwen3-embedding:4b-q4_K_M")
t1=time.time()
v = m.embed_query("测试")
t2=time.time()
print("MODELTYPE", type(m).__name__, "MODULE", type(m).__module__)
print("LOAD_SEC %.3f QUERY_SEC %.3f" % (t1-t0, t2-t1))
print("DIM", len(v), "HEAD", list(v[:5]))
vs = m.embed_documents(["第一段", "第二段"])
print("BATCH_LEN", len(vs), "DIMS", [len(x) for x in vs], "HEAD2", list(vs[1][:3]))
```

**原始输出**：

```
MODELTYPE OllamaEmbeddings MODULE a0flatpak.embeddings
LOAD_SEC 0.000 QUERY_SEC 0.095
DIM 2560 HEAD [0.000233904, 0.024939163, -0.02817071, 0.0029296456, 0.00093592686]
BATCH_LEN 2 DIMS [2560, 2560] HEAD2 [-0.0001920112, -0.0023738097, 0.044011805]
```

**期望**：类名 `OllamaEmbeddings`；`len(v)==2560`；前 5 个数值可打印；耗时合理。
**实际**：全部符合。模型已在 Ollama 内存中，所以构造耗时为 0、单次查询 95 ms。
**结论**：**通过**。D2（批量）同一次执行通过：2 条文本、每条 2560 维。

**补充：模型名替换分支**（对齐 `test-matrix.md` C23 的 S-EMB 脚本）：

```
$ python d1b_replace.py     # 传入 "sentence-transformers/all-mpnet-base-v2"
CLASS OllamaEmbeddings MODEL qwen3-embedding:4b-q4_K_M LOAD 0.000
DIM 2560 FIRST3 [-0.00015179327, 0.016437953, -0.02148209]
```

`embeddings.py` 把任何 `huggingface` 提供方的模型名替换为 `A0_EMBEDDING_MODEL`（默认 `qwen3-embedding:4b-q4_K_M`），替换生效。

### D2 批量嵌入

**目的**：`embed_documents` 一次传两条，返回条数与维度一致。

**命令**：D1 脚本最后两行：

```python
vs = m.embed_documents(["第一段", "第二段"])
print("BATCH_LEN", len(vs), "DIMS", [len(x) for x in vs])
```

**原始输出**：

```
BATCH_LEN 2 DIMS [2560, 2560] HEAD2 [-0.0001920112, -0.0023738097, 0.044011805]
```

**期望**：`len(vs)==2`，每条 2560 维，且不是同一条被复制。
**实际**：2 条、均 2560 维；第二条前 3 个数值与第一条不同，说明是独立嵌入。
**结论**：**通过**。

### D3 记忆写入与检索

**目的**：用框架自己的 `Memory.initialize` / `insert_text` / `search_similarity_threshold_with_scores` 写入两条语义不同的文本，验证召回顺序与 score 范围。

**命令**（`~/a0-shots/d3_memory.py`，核心）：

```python
import a0flatpak; a0flatpak.apply()
import models
from plugins._memory.helpers.memory import Memory, abs_db_dir

SUBDIR = "probe-d3-embed"
CFG = models.ModelConfig(type=models.ModelType.EMBEDDING,
                         provider="huggingface", name="qwen3-embedding:4b-q4_K_M")
db, created = Memory.initialize(None, CFG, SUBDIR)
mem = Memory(db, SUBDIR)
i1 = await mem.insert_text("猫喜欢在阳光下打盹。", {"area": "main"})
i2 = await mem.insert_text("量子计算机使用超导比特进行计算。", {"area": "main"})
docs = await mem.search_similarity_threshold("小猫晒太阳睡觉", limit=5, threshold=0.0)
pairs = await mem.search_similarity_threshold_with_scores("小猫晒太阳睡觉", limit=5, threshold=0.0)
```

**原始输出**：

```
Initializing VectorDB...
CREATED True INIT_SEC 0.100 NTOTAL 0
INSERT jYJqWwSQwM SEC 0.199 TEXT 猫喜欢在阳光下打盹。
INSERT NfRBSdps2W SEC 0.217 TEXT 量子计算机使用超导比特进行计算。
IDS ['jYJqWwSQwM', 'NfRBSdps2W'] NTOTAL 2
SEARCH_SEC 0.139 N 2
DOC jYJqWwSQwM '猫喜欢在阳光下打盹。'
DOC NfRBSdps2W '量子计算机使用超导比特进行计算。'
WITH_SCORES_N 2
SCORE 0.858004 ID jYJqWwSQwM TEXT '猫喜欢在阳光下打盹。'
SCORE 0.644255 ID NfRBSdps2W TEXT '量子计算机使用超导比特进行计算。'
DB_DIR /home/kunweiz/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/memory/probe-d3-embed
FILE embedding.json 76
FILE index.faiss 10426
FILE index.faiss.sha256 64
FILE index.pkl 401
```

**期望**：写入返回 10 位 id；查询“小猫晒太阳睡觉”时“猫”在前；score 在 0–1。
**实际**：顺序正确（0.858 vs 0.644），score 在 0–1。索引落点为 numpy pickle，扩展名仍是 `index.faiss`（10,426 B），伴随 `index.pkl`（401 B）、`index.faiss.sha256`（64 B）、`embedding.json`（76 B）。
**结论**：**通过**。`search_similarity_threshold` 只回 `Document`；带分数要用 `search_similarity_threshold_with_scores`（任务里说的 `_with_scores` 即此方法）。

### D4 删除

**目的**：直接验证 `vector_store.py` 的 `remove_ids` 与 langchain `adelete` 的配合。

**命令**（D3 脚本末尾）：

```python
victim = docs[1].metadata["id"]          # NfRBSdps2W
before = db.index.ntotal
await db.adelete(ids=[victim])
after = db.index.ntotal
mem._save_db()
docs2 = await mem.search_similarity_threshold("小猫晒太阳睡觉", limit=5, threshold=0.0)
```

**原始输出**：

```
DELETE_ID NfRBSdps2W NTOTAL_BEFORE 2 NTOTAL_AFTER 1 DELTA -1 SEC 0.000
AFTER_DELETE_IDS ['jYJqWwSQwM']
VICTIM_RETURNED False
```

**期望**：`ntotal` 减少 1；被删 id 不再出现在检索结果；docstore 同步删除。
**实际**：完全符合。`langchain_community.vectorstores.faiss.FAISS.delete` 走 `index.remove_ids(np.fromiter(...))`，shim 的 `remove_ids` 用布尔掩码重建 `_vectors` 并更新 `ntotal`。
**结论**：**通过**。这是 `vector_store.py` 补 `remove_ids` 的直接证据。

### D5 持久化（新进程重新加载）

**目的**：验证索引落盘后能被新进程重新读出。用“第二次 `python` 进程重新构造 Memory”替代重启 5080（避免额外重启）。

**命令**（`~/a0-shots/d5_reload.py`）：

```python
db, created = Memory.initialize(None, CFG, SUBDIR)
mem = Memory(db, SUBDIR)
print("RELOAD_CREATED", created, "NTOTAL", db.index.ntotal)
docs = await mem.search_similarity_threshold("小猫晒太阳睡觉", limit=5, threshold=0.0)
```

**原始输出**：

```
Initializing VectorDB...
RELOAD_CREATED False NTOTAL 1
RELOAD_IDS ['jYJqWwSQwM']
RELOAD_TEXTS ['猫喜欢在阳光下打盹。']
SURVIVOR_PRESENT True
FILE embedding.json 76
FILE index.faiss 10426
FILE index.faiss.sha256 64
FILE index.pkl 401
```

**期望**：`created=False`、`ntotal=1`、只剩 D3 的存活文档。
**实际**：符合。文件大小与 D3 结束时一致。
**结论**：**通过**。索引持久化与新进程加载正常；`embedding.json` 匹配时不会重建。

### D6 旧 faiss 索引不兼容

**目的**：检查 `usr/memory` 是否存在真 faiss 格式的旧索引；若存在，`read_index` 是否给出可读错误；框架是否有“读不了就重建”的分支。

**检查 1：现网索引格式**

```
$ od -An -tx1 -N16 $DATA/usr/memory/default/index.faiss
 80 05 95 af f0 00 00 00 00 00 00 7d 94 28 8c 06
$ head -c 60 .../index.faiss | strings
format
a0flatpak-numpy
$ python - <<'PY'   # 读 pickle
FORMAT a0flatpak-numpy DIM 2560 VECTORS (6, 2560)
DOCSTORE InMemoryDocstore COUNT 6 MAP 6
PY
```

现网 `default` 是 **a0flatpak numpy pickle**，不是真 faiss。sha256 与 `index.faiss.sha256` 一致。目录里没有真 faiss 格式的遗留文件。

**检查 2：把真 faiss 头放进一个隔离 subdir**

```
FAKE_MAGIC b'IxFI'                         # faiss IndexFlatIP 的真实 magic
READ_INDEX_EXC builtins.ValueError MSG could not convert string to int
Initializing VectorDB...
INIT_EXC builtins.ValueError MSG could not convert string to int
TRACEBACK_LAST ['  File ".../a0flatpak/vector_store.py", line 85, in read_index',
                '    payload = pickle.load(handle)',
                'ValueError: could not convert string to int']
```

**期望（按 `test-matrix.md` C27）**：第一次 load 抛 `ValueError`，消息含 `is not a a0flatpak numpy index`；删除索引文件后能重建。
**实际**：抛的是 `ValueError: could not convert string to int`，来自 `pickle.load` 本身，**没有走到** `vector_store.py` 的格式检查（`payload.get("format") != "a0flatpak-numpy"`），也**没有**“读不了就重建”的回退。`Memory.initialize` 与 langchain `FAISS.load_local` 都没有 try/except。
**结论**：**不通过（与矩阵期望不符）**。见 §3 P1-1。

现有唯一的安全网是 `_verify_index_hash`：哈希不匹配时跳过加载并重建，但重建时 `docs=None`，原有文档会**静默丢失**；哈希缺失时直接返回 `True`，仍然会走 `load_local` 并崩溃。哈希只能发现“文件被改坏”，不能发现“格式不兼容”。

**另外**：`default/embedding.json` 写着 `sentence-transformers/all-MiniLM-L6-v2`，而索引实际是 2560 维 qwen3。元数据与数据不一致。若下次 `Memory.get_by_subdir("default")` 读到该元数据，会判定模型不匹配并全量重嵌入（功能上能自愈，但会白耗一次嵌入）。

---

## 2. E 类：语音

### E1 TTS 出 WAV

**目的**：确认 `synthesize_sentences` 返回非空 base64、解码是 RIFF/WAV、采样率与时长可读。

**命令**（`~/a0-shots/e_tts.py`）：

```python
import a0flatpak; a0flatpak.apply()
from plugins._kokoro_tts.helpers import runtime as tts

b64 = await tts.synthesize_sentences(["你好，这是 Agent Zero 的语音测试。"])
raw = base64.b64decode(b64)
print(len(b64), raw[:4] == b"RIFF")
open(os.path.expanduser("~/a0-shots/tts-probe.wav"), "wb").write(raw)
```

**原始输出（冷启动，模型首次加载）**：

```
B64_LEN 225340 SEC 8.785 PREFIX UklGRv////9XQVZFZm10IBAAAAABAAEA
RAW_LEN 169004 MAGIC b'RIFF' RIFF True
WROTE /home/kunweiz/a0-shots/tts-probe.wav 169004
```

**原始输出（热，模型已在内存，同一文本重跑）**：

```
B64_LEN 235580 SEC 9.934 PREFIX UklGRv////9XQVZFZm10IBAAAAABAAEA
RAW_LEN 176684 MAGIC b'RIFF' RIFF True
```

**ffprobe / file**：

```
$ ffprobe -v error -show_entries format=format_name,duration,size,bit_rate \
    -show_entries stream=codec_name,sample_rate,channels,bits_per_sample -of json tts-probe.wav
{
  "streams": [{"codec_name":"pcm_s16le","sample_rate":"24000","channels":1,"bits_per_sample":16}],
  "format": {"format_name":"wav","duration":"3.680000","size":"176684","bit_rate":"384100"}
}
$ file tts-probe.wav
RIFF (little-endian) data, WAVE audio, Microsoft PCM, 16 bit, mono 24000 Hz
```

**期望**：非空 base64；`raw[:4]==b"RIFF"`；采样率在 8000–48000；时长 > 0.5 s；字节数 > 1000。
**实际**：16 bit / mono / 24000 Hz / 3.68 s / 176,684 B；冷启动 8.785 s，热启动 9.934 s。TTS 输出**不确定**：同一文本两次分别为 169,004 B（3.52 s）与 176,684 B（3.68 s）。
**结论**：**通过**（元数据与时长合理），但 WAV 头有严重问题，见下。

**WAV 头的严重问题**：

```
$ od -An -tx1 -N48 tts-probe.wav
52 49 46 46 ff ff ff ff 57 41 56 45 66 6d 74 20
10 00 00 00 01 00 01 00 c0 5d 00 00 80 bb 00 00
02 00 10 00 64 61 74 61 ff ff ff ff ...
```

RIFF chunk size（偏移 4）与 data chunk size（偏移 40）都是 `0xFFFFFFFF`。这是流式写 WAV 时的占位值。ffprobe 用实际文件长度算出了正确的 3.68 s；Python 标准库 `wave` 则直接相信头：

```
$ python3 -c "import wave; w=wave.open('tts-probe.wav'); print(w.getnframes(), w.getnframes()/w.getframerate())"
2147483647 89478.48529166667
```

`wave` 报 **2147483647 帧 / 89478 秒**。这意味着：

- `test-matrix.md` C28 用 `wave` 并只断言 `n / sr > 0.5`，会**误通过**；
- 任何严格按头解析 WAV 的客户端（部分浏览器/播放器/转码器）会读到错误时长，甚至尝试读取 4 GB 数据。

见 §3 P1-2。

### E2 STT 往返

**目的**：把 E1 的 WAV base64 送回 `transcribe`，验证 dict 形状、非空 text，并计算与原文的相似度。

**命令**（`~/a0-shots/e_stt.py`）：

```python
b64 = base64.b64encode(open("~/a0-shots/tts-probe.wav","rb").read()).decode()
out = await stt.transcribe(b64)
print(sorted(out.keys()), repr(out["text"]), out.get("language"))
difflib.SequenceMatcher(None, TEXT, out["text"]).ratio()
```

**原始输出**：

```
STT_SEC 1.050 TYPE dict KEYS ['duration', 'language', 'segments', 'task', 'text']
STT_TEXT '你好,这是Agent Zero的语音测试。'
STT_LANG 'english' SEGMENTS 1
NONEMPTY True
SIMILARITY 0.9091 MATCHED 0.9090909090909091
RAW_JSON {"task": "transcribe", "language": "english", "duration": 3.52,
          "text": "你好,这是Agent Zero的语音测试。", "segments": "<1 items>"}
```

**期望**：返回 dict；含 `text`/`segments`/`language`；`text` 非空；与原文语义一致。文档把“STT 逐字回译”标为 **Unverified behaviour**，本次是首次实测，不假设逐字相等。
**实际**：输入为 3.52 s 的 WAV（E1 冷启动版本），STT 在 1.05 s 内返回；`text` 与原文仅差标点与空格，相似度 **0.9091**；`language` 却报 **`english`**。
**结论**：**通过（文本往返）**，但 `language` 字段错误，见 §3 P2-2。

> 时间顺序说明：E1 冷启动落盘 169,004 B / 3.52 s；E2 紧接着读该文件，STT 返回 `duration: 3.52`，与输入一致。之后为测“热”耗时又重跑了一次 TTS，覆盖为 176,684 B / 3.68 s，所以现在 `ffprobe tts-probe.wav` 看到的是 3.68 s。两次文本相同，不影响 E2 的相似度。

### E3 边界

#### E3a 空文本

**命令**（`~/a0-shots/e_empty.py`）：

```python
for arg in ([], [""], ["   ", ""]):
    r = await tts.synthesize_sentences(arg)
    print(repr(r))
```

**原始输出**：

```
EMPTY_LIST_OK '' SEC 0.000
EMPTY_STR_OK '' SEC 0.000
WHITESPACE_OK '' SEC 0.000
```

**期望**：返回空字符串或空 audio，不抛异常、不发起请求。
**实际**：三种输入均返回 `''`，0 秒，无异常。
**结论**：**通过**。`synthesize_sentences` 先过滤空白句子，全空时直接返回 `""`。

#### E3b 超长文本

**目的**：1500 字中文，记录是否成功、耗时、是否截断。

**命令**（`~/a0-shots/e_long.py`）：

```python
unit = "这是一段用于测试超长文本语音合成的中文句子，它需要重复很多次。"
text = (unit * (1500 // len(unit) + 1))[:1500]
r = await tts.synthesize_sentences([text])
```

外层 `timeout 200`，`A0_SPEECH_TIMEOUT=150`。

**原始输出**：

```
LONG_CHARS 1500 UNIQUE_UNITS 30
（200 秒后外层 timeout 终止，无 LONG_OK / LONG_EXC）
```

**结论**：**1500 字在 200 秒内未完成**。`A0_SPEECH_TIMEOUT=150` 没有在 150–200 秒窗口内触发 `ReadTimeout`（原因待查：可能是生成期间 TCP 仍在流动，httpx 的 read timeout 按“两次读之间”计时）。矩阵 C31 的 `real ≤ 200s` **不达标**。

**补充：300 字对照**（同一模型、同一前台进程，`timeout 270`，`A0_SPEECH_TIMEOUT=180`）：

```
LEN 300
OK B64 4300860 RAW 3225644 SEC 135.653 MAGIC b'RIFF'
WROTE /home/kunweiz/a0-shots/tts-long300.wav
```

ffprobe：

```
streams: pcm_s16le, 24000 Hz, mono
format: duration 67.200000, size 3225644, bit_rate 384005
```

- 300 字 → 67.2 s 音频 / 135.65 s 墙钟，约 **0.452 s 墙钟/字**，**2.02× 实时**。
- 按线性外推，1500 字约需 **336 s 音频 / 678 s 墙钟**，与“200 s 未完成”一致。
- 输出 WAV 头同样带 `0xFFFFFFFF`；`wave` 同样报 89478 s。
- 未见截断：67.2 s 与 300 字的语速比例合理（E1 的 23 字为 3.52 s）。

**结论**：长文本**能完成，但极慢**；矩阵要求的 200 s 上限对 1500 字不成立。产品侧若允许“朗读整篇文档”，需要分句发送或流式播放，而不是一次 1500 字。

#### E3c 错误模型

**目的**：子进程把 `A0_SPEECH_MODEL` 指到不存在的模型，验证错误可读（含模型名与 HTTP 状态），不是裸 traceback。

**命令**（`~/a0-shots/e_badmodel.py`）：

```sh
export A0_SPEECH_MODEL="no-such-model:latest"
python e_badmodel.py
```

**原始输出**：

```
ENV_SPEECH_MODEL no-such-model:latest
MODULE_MODEL no-such-model:latest
EXC_TYPE httpx.HTTPStatusError
EXC_STR Client error '404 Not Found' for url 'http://127.0.0.1:11434/v1/audio/speech'
For more information check: https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/404
SEC 0.014
TB_LAST For more information check: https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/404
```

**期望**：错误含模型名与 HTTP 状态，不是裸 traceback。
**实际**：含 HTTP 404；**不含模型名**；不含 Ollama 响应体；`httpx.HTTPStatusError` 的 `str` 是两行可读文本，不是 traceback（调用方若不捕获，仍会看到完整 traceback）。
**结论**：**部分通过**。状态可读，模型名缺失，见 §3 P2-1。

#### E3d Ollama 未启动（黑洞端口）

**目的**：不改系统 Ollama，用 `OLLAMA_HOST=http://127.0.0.1:9` 模拟不可达，验证快速失败而非挂 180 秒。

**命令**（`~/a0-shots/e_blackhole.py`）：

```sh
export OLLAMA_HOST="http://127.0.0.1:9"
python e_blackhole.py
```

**原始输出**：

```
MODULE_URL http://127.0.0.1:9 TIMEOUT 180.0
EXC_TYPE httpx.ConnectError
EXC_STR [Errno 111] Connection refused
SEC 0.015
```

**期望**：0.1–1 s 内失败；错误含“连接拒绝”；服务不崩。
**实际**：**0.015 s** 失败，`ConnectError: [Errno 111] Connection refused`；整个 `flatpak run` 8.26 s（含沙盒启动与 Python 导入）。
**结论**：**通过**。快速失败，无 180 秒挂起。错误消息不含目标 URL，排障时略欠信息（P3-2）。

---

## 3. 发现的问题（按严重度）

### P1-1（高）旧 faiss 索引会让记忆初始化崩溃，且没有重建分支

- 证据：§D6。`faiss.read_index` 先 `pickle.load`，读到真 faiss 的 `IxFI` magic 时抛 `ValueError: could not convert string to int`，位置 `a0flatpak/vector_store.py:85`。
- 为什么严重：`Memory.initialize` 与 `langchain FAISS.load_local` 都没有 try/except。升级/换实现后，`usr/memory/<subdir>/index.faiss` 一旦是旧格式，应用侧任何走记忆初始化的路径都会抛异常；没有“格式不兼容 → 备份 → 重建”的路径。
- 与文档不符：`test-matrix.md` C27 期望消息 `is not a a0flatpak numpy index`。该消息只在 pickle 是合法 dict 但 `format` 不对时出现；真 faiss 二进制到不了这一步。
- 建议（不在本次改动范围）：`read_index` 先检查文件头（`IxFI`/`IxFl`/`IxF2` 等），抛带文件路径与“旧 faiss 格式，需重建”的自定义错误；`Memory.initialize` 捕获后把旧文件改名 `.bak` 并新建索引。

### P1-2（高）TTS 返回的 WAV 头长度字段是 0xFFFFFFFF

- 证据：§E1 的 `od`；Python `wave` 读出 2147483647 帧 / 89478 秒；ffprobe 用实际文件大小算出 3.68 s。
- 影响：严格解析器会得到错误时长；某些播放器/转码器可能尝试读 4 GB。`test-matrix.md` C28 的 `wave` 断言 `n/sr > 0.5` 会**误通过**，因为 89478 > 0.5。
- 建议：在 `a0flatpak/speech.py` 里对返回字节做最小修补——把 RIFF size（偏移 4）与 data size（偏移 40）改成 `len(raw)-8` 与 `len(raw)-44`；或让 Ollama 端不要流式写占位头（取决于上游）。

### P2-1（中）语音错误信息不含模型名与响应体

- 证据：§E3c。404 只给 URL 与状态码；模型名 `no-such-model:latest` 不在消息里。
- 影响：用户/支持无法从错误判断是“模型不存在”“端点不支持”还是“名字拼错”。
- 建议：捕获 `HTTPStatusError` 后补上 `SPEECH_MODEL` 与 `response.text[:500]`。

### P2-2（中）STT 把中文音频的 language 报成 english

- 证据：§E2 `STT_LANG 'english'`，而 `text` 是正确的简体中文。
- 影响：Web UI 或下游若按 `language` 选择后续处理（翻译、分词、字幕样式），会走错分支。
- 建议：要么不信任该字段（用文本检测），要么在 `_transcription_request` 里显式传 `language=zh`（当配置为中文时）。

### P2-3（中）1500 字超长文本在 200 s 内不返回，超时参数未按预期生效

- 证据：§E3b。1500 字 200 s 无结果；300 字 135.65 s；线性外推 1500 字约 678 s。
- 影响：矩阵 C31 的 `real ≤ 200s` 不达标；`A0_SPEECH_TIMEOUT=150` 没有在 150 s 触发，说明超时语义不覆盖整个请求时长。若 UI 同步等待，用户会长时间无反馈。
- 建议：按句切分（`synthesize_sentences` 已接受列表，但当前实现用 `\n` 拼接成一次请求），或流式返回。

### P3-1（低）health 200 带 `error` 字段

- 证据：§0.2。`{"gitinfo": null, "error": "<data dir>"}`。
- 影响：监控若解析 `error` 会误报；若只看状态码会漏掉真正的错误。
- 建议：明确字段语义，或在无 git 时不输出 `error`。

### P3-2（低）连接错误不含目标 URL

- 证据：§E3d。`ConnectError: [Errno 111] Connection refused`。
- 影响：多端点配置时难以定位是哪个地址。
- 建议：补 `OLLAMA_URL`。

### P3-3（低）`default` 的 `embedding.json` 与索引维度不一致

- 证据：§D6。`embedding.json` 写 `sentence-transformers/all-MiniLM-L6-v2`（384 维），`index.faiss` 是 2560 维 qwen3。
- 影响：下次 `Memory.get_by_subdir("default")` 会判定模型不匹配并全量重嵌入（6 条文档，代价小，但会写盘）。
- 建议：写入索引时同步更新 `embedding.json`；或把元数据与索引放在同一次原子写入里。

### 观察项（不计缺陷）

- TTS 输出非确定性：同一文本两次 169,004 B / 176,684 B。
- `size_vram=0`：`lfm3-omni` 纯 CPU 推理，TTS 约 2× 实时。
- 宿主内存实测 available 47.9 GiB，与任务描述的 6 GB 不符；本次未遇到内存压力。

---

## 4. 清理与状态

- 嵌入模型与语音模型均已用 `keep_alive:0` 卸载；结束前 `/api/ps` 为空（见下）。
- 保留证据：`~/a0-shots/tts-probe.wav`（176,684 B，3.68 s）、`tts-long300.wav`（3,225,644 B，67.2 s）、全部探针脚本与 `e-long300.log`。
- 测试记忆 subdir 已删除（`probe-d3-embed`、`probe-old-faiss`），`usr/memory` 只剩原有 `default`；D6 的旧格式证据保留在本文的原始输出中。
- 未重启 5080 实例；D5 用新进程重载替代。

结束前：

```
$ curl -s http://127.0.0.1:11434/api/ps
{"models":[]}
```

---

## 5. 对照 `test-matrix.md` 的 D/E 类用例

| CASE | 用例 | 本次探针 | 结果 | 与矩阵期望的差异 |
|---|---|---|---|---|
| C23 | 嵌入维度 2560 | D1 | **通过** | 已复测两条路径：显式 `qwen3-embedding:4b-q4_K_M`，以及传 `all-mpnet-base-v2` 被替换成 qwen3 |
| C24 | 记忆写入 | D3 | **通过** | 未用 `Memory.get_by_subdir("default")`，改用 `Memory.initialize` + 独立 subdir，避免写 `default` |
| C25 | 记忆检索 | D3 | **通过** | 同上；命中顺序与 score 符合 |
| C26 | 记忆删除 | D4 | **通过** | 用 `db.adelete`（矩阵用 `delete_documents_by_ids`）；两者都落到 `remove_ids` |
| C27 | 旧 faiss 索引不兼容 | D6 | **不通过** | 矩阵期望 `is not a a0flatpak numpy index`；实际是 `could not convert string to int`，且无重建 |
| C28 | TTS 出 WAV | E1 | **通过（有条件）** | RIFF/WAVE/24000 Hz/3.68 s 均符合；但 `wave` 解析时长错误，矩阵的 `wave` 断言会误通过 |
| C29 | STT 回译 | E2 | **通过（有条件）** | `text` 非空、相似度 0.9091；`language` 误报 english |
| C30 | 空文本 TTS | E3a | **通过（runtime 层）** | 矩阵还要求 HTTP `/api/plugins/_kokoro_tts/synthesize`；本次未测 HTTP 层 |
| C31 | 超长文本 | E3b | **不通过** | 1500 字 200 s 未完成；矩阵要求 `real ≤ 200s`。300 字 135.65 s 可完成 |
| C32 | Ollama 不可达 | E3d | **通过** | 0.015 s 快速失败；随后 `health` 实测 HTTP 200 |

---

## 6. 未覆盖项

1. **HTTP API 层**：`POST /api/plugins/_kokoro_tts/synthesize`、`/api/plugins/_whisper_stt/transcribe` 的 CSRF/鉴权、JSON 形状与 UI 按钮未测；本次只到插件 runtime。
2. **应用重启**：D5 用“新进程重载索引”替代了真正的 `flatpak kill` + 重启；未验证 5080 进程内的 Memory 单例在重启后的行为。
3. **`Memory.get_by_subdir("default")` 的完整路径**：依赖 `initialize.initialize_agent()`；本次绕开它，未验证 agent 配置缺失/错误的报错。
4. **真实旧 faiss 文件**：现网没有；D6 用人工 `IxFI` 头模拟，未用真 faiss 库生成的文件（沙盒无 faiss）。
5. **多句 TTS**：`synthesize_sentences` 用 `\n` 拼接多句，未测多句的韵律/停顿/长度。
6. **多语言 STT**、无语音/纯噪声音频、长音频（>1 分钟）未测。
7. **并发**：未测同时两个 TTS/STT 请求；Ollama `OLLAMA_MAX_LOADED_MODELS=1` 下并发会排队。
8. **`A0_SPEECH_VOICE`**：只用了默认 `female`，未测其他音色是否被 Ollama 接受。
9. **OCR（F 类）**：不属于本次范围。

---

## 附：关键文件与证据

| 文件 | 说明 |
|---|---|
| `~/a0-shots/d1_embed.py` | 维度 + 批量 |
| `~/a0-shots/d3_memory.py` | 写入/检索/删除 |
| `~/a0-shots/d5_reload.py` | 新进程重载 |
| `~/a0-shots/d6_oldindex.py` | 旧索引格式 |
| `~/a0-shots/e_tts.py` | TTS + 落盘 |
| `~/a0-shots/e_stt.py` | STT 往返 + 相似度 |
| `~/a0-shots/e_empty.py` | 空文本边界 |
| `~/a0-shots/e_long.py` / `e_long300.py` | 1500 字 / 300 字 |
| `~/a0-shots/e_badmodel.py` | 错误模型 |
| `~/a0-shots/e_blackhole.py` | 黑洞端口 |
| `~/a0-shots/tts-probe.wav` | 3.68 s / 176,684 B |
| `~/a0-shots/tts-long300.wav` | 67.2 s / 3,225,644 B |
