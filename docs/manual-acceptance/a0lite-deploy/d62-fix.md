# D62 空字符串被静默编码
## 现象
`embed_query("")` 返回 2560 维非零单位向量（L2≈1.0000001），与真实嵌入无法区分；空串进入 FAISS 后成为可被任意查询匹配的零信息文档。
## 调用方调查（v22 实例）
- `_memory/helpers/memory.py:214` 用 `embed_query("example")` 探维度，输入非空。
- `_50_recall_memories.py:209` 检索前已有 `if not query or len(query) <= 3: return {}`，空查询到不了嵌入层。
- `tools/memory.py:54`、`memory_consolidation.py`、`monologue_end/_50_memorize_fragments.py:211`、`_51_memorize_solutions.py:203` 的 `insert_text` 无文本校验，LLM 可能传空。
- `agent.py:1207` 工具执行只有 `finally`；`handle_exception` 直接 `raise`。
## 策略
返回零向量作显式空标记，并写 warning 到 `$A0_BASE_DIR/usr/logs/a0flatpak.log`，**不抛异常**。
理由：真实嵌入是单位向量（L2≈1），零向量可判定且不混淆；FAISS 内积为 0，阈值过滤后返回"未找到"，语义正确；抛异常会经 `handle_exception` 中断 message loop，`memory_save(text="")` 将打断当轮对话。
## 改法（flatpak/a0flatpak/embeddings.py）
- `_is_blank`：None、非 str、纯空白都算空；`_log_warning` 追加带时间戳的 warning。
- `embed_query`：空输入 → 零向量；正常文本照旧走 Ollama `/api/embed`。
- `embed_documents([])` 仍返回 `[]`；部分空只把非空项发 Ollama，空位填零向量并记录位置；全空返回全零。
- `_post_embed` 校验返回条数等于输入数；维度随成功调用更新，默认 2560（`A0_EMBEDDING_DIM` 可覆盖）。
## 验证（沙盒 venv python + 本机 Ollama）
```text
embed_query('')       len=2560 all_zero=True  L2=0.0000000
embed_query('   ')    len=2560 all_zero=True  L2=0.0000000
embed_query('Paris?') len=2560 all_zero=False L2=0.9999999
batch ['hello',' ','  ','second'] → [非零, 零, 零, 非零]，均 2560；[] → []
```
日志 3 行，均含 `empty text cannot be embedded`；`py_compile` 通过。
## 构建后复验
```sh
APP=~/.local/share/flatpak/app/org.agentzero.AgentZero/current/active/files/share/agent-zero
PY=~/.var/app/org.agentzero.AgentZero/data/agent-zero/venv/bin/python
A0_BASE_DIR=/tmp/a0-d62 "$PY" - <<PY
import importlib.util; s=importlib.util.spec_from_file_location("e","$APP/flatpak/a0flatpak/embeddings.py")
m=importlib.util.module_from_spec(s); s.loader.exec_module(m); e=m._build_wrapper_class()("qwen3-embedding:4b-q4_K_M")
print(len(e.embed_query("")), all(x==0 for x in e.embed_query("   ")), len(e.embed_query("hello")))
PY
grep 'empty text cannot be embedded' ~/.var/app/org.agentzero.AgentZero/data/agent-zero/usr/logs/a0flatpak.log | tail -3
```
