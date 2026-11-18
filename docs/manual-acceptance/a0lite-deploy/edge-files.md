# 文件浏览器与记忆写操作边界实测

- 实例：`http://127.0.0.1:5080`，commit `ab3d8e61`，health 200
- 时间：2026-11-18 05:00–05:17 CST；执行：`edge-files`
- 认证：`GET /api/csrf_token`（Origin 头）+ session cookie；后续带 `X-CSRF-Token`
- 数据根：`~/.var/app/org.agentzero.AgentZero/data/agent-zero`（`/a0` 为其符号链接）

## 1. 端点清单（从运行中的 `/app/share/agent-zero` 代码读取）

| 方法 | 路径 | 参数 | 说明 |
|---|---|---|---|
| GET | `/api/csrf_token` | — | 返回 `{ok,token}` 并下发 session |
| GET | `/api/get_work_dir_files` | `?path=`，`?limits=1` | 列目录；limit 返回 4 项上限 |
| POST | `/api/upload_work_dir_files` | multipart `files[]` + form `path` | 上传；超限 413 |
| POST | `/api/rename_work_dir_file` | JSON `action=rename\|create-folder\|move`；`path`/`newName`/`parentPath`/`paths`/`destinationPath`/`currentPath` | 重命名/建目录/移动 |
| POST | `/api/delete_work_dir_file` | JSON `path`、`currentPath` | 单删 |
| POST | `/api/delete_work_dir_files` | JSON `paths[]`、`currentPath` | 批量删 |
| GET | `/api/download_work_dir_file` | `?path=` | 下载 |
| GET/POST | `/api/edit_work_dir_file` | `?path=` 或 JSON `content` | 文本编辑 |
| POST | `/api/file_info` | JSON `path` | 元数据（不校验根外路径） |
| POST | `/api/plugins/_memory/memory_dashboard` | `action=search\|delete\|bulk_delete\|update\|get_memory_subdirs\|get_current_memory_subdir`；`memory_subdir`、`memory_id(s)`、`search`、`threshold` | **无写入 action** |
| POST | `/api/plugins/_memory/knowledge_reindex` | `ctxid` | `Memory.reload()`，清空进程内索引缓存 |

**记忆写入边界**：HTTP 面没有 `/api/memory_save`。写入只存在于 agent 的 memory 工具（`plugins/_memory/tools/memory.py` → `Memory.insert_text`）。本次 B 组写入用同一 `Memory` 类、同一数据目录、同一 Ollama 嵌入，在 flatpak 内执行；读/删走 HTTP dashboard。

## 2. A 组：文件浏览器写操作

| # | 操作 | 状态码 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| 1 | 上传 40 B 文本到 `/a0/probe-edge-20261118` | 200 | 0.020 s | `successful:["probe-upload-20261118.txt"]`；列表出现；`cat` 内容一致 | PASS |
| 2 | 上传 10 MiB 随机二进制 | 200 | 0.066 s | `successful`；磁盘 10,485,760 B；SHA-256 与源一致；上限 100 MiB | PASS |
| 3 | 同名文件二次上传（内容改为 51 B） | 200 | 0.020 s | 无提示直接覆盖，磁盘仅 1 个文件，内容为第二次 | 记录（F4） |
| 4 | 重命名为 `probe-renamed-20261118.txt` | 200 | 0.007 s | 旧名消失、新名在列表；下载内容完整 | PASS |
| 5 | 新建目录 `probe-nonempty` | 200 | — | 列表出现，磁盘 `test -d` 为真 | PASS |
| 6 | 删除 10 MiB 文件 | 200 | 0.010 s | 列表消失，磁盘不存在 | PASS |
| 7 | 删除非空目录（内含 2 个文件） | 200 | 0.008 s | 递归删除，子文件一并消失，无确认 | 记录（F3） |
| 8 | 路径穿越三式（见 §5） | 200 | 0.011 s | `/etc` 39 项；`/etc/passwd` 109 B；`/home/kunweiz` 243 项 | **FAIL** |
| 9 | 不存在文件的读取/删除 | 500 / 200 | — | 下载回 546 B Python traceback；删除回 `{"error":"File not found..."}` | **FAIL**（F2） |
| 10 | 200 个空文件目录列表 | 200 | 0.017 s | 46,248 B；200/200 条全部返回，无截断 | PASS（无分页，F5） |

另：上传 101 MiB 文件返回 **413** `{"error":"File exceeds the 100 MiB size limit."}`，0.41 s；未落盘。

## 3. B 组：记忆写操作

| # | 操作 | 状态码 | 耗时 | 关键输出 | 判定 |
|---|---|---|---|---|---|
| 11 | 写入 1 条 `PROBE-20261118-A1` | —（库调用） | 5.6 s | `id=Cdx8TALde6`，`memory_subdir=default`，`ntotal=9` | PASS |
| 12 | 搜索该 token | 200 | 1.2 s | 返回 9 条，该条排第 1；`total_db_count=9` | PASS |
| 13 | 删除该条 | 200 | 0.027 s | `Memory Cdx8TALde6 deleted successfully`；再搜不命中；count 8 | PASS |
| 14 | 写 20 条 → 批量删 | 200 | 179 s / 0.005 s | 写后 `ntotal=28`、API `total_db_count=28`；删后 count 8；20/20 成功 | PASS |
| 15 | 写入 99,993 字符（构造 10 万） | —（库调用） | 71.1 s | `id=JZVt1yWKGW`，全文保留，尾部 `LONGPROBEEND` 可读；无截断/报错；随后删除 | PASS |
| 16 | 并发写 5 条 | —（库调用） | 17.0 s | 5 个 id 互异，`ntotal=13`，API 5/5 可见；批量删 200 | PASS |
| 17 | 语义检索（干净子库 2 条） | 200 | 43.9 s | 搜「水果」→ 苹果条 rank 1；搜「汽油」→ 汽车条 rank 1 | PASS（见 F6） |

索引一致性：每次写入后 `ntotal == len(docs)`；20 条批量删后从 28 回到 8；终态直接读盘 `NTOTAL=15 / DOCS=15`。

## 4. 缺陷

- **F1（严重）文件浏览器根为 `/`，且 flatpak 权限含 `filesystems=host`**：任何已登录调用者可列出/下载 `/home/kunweiz` 与 `/etc`，并向 `/a0` 之外写入/删除。根因 `helpers/file_browser.py:88 base_dir="/"`；`FileBrowser._entry_path` 只校验 `is_relative_to("/")`，等于不设防。
- **F2（中）错误契约不一致**：不存在文件下载返回 500 + 完整 traceback（含 `/home/kunweiz/...` 绝对路径）；删除返回 200 + `error`；列目录返回 200 + `error`。要求 4xx 且无堆栈。
- **F3（中）非空目录递归删除**：`delete_file` 对目录用 `shutil.rmtree`，但 docstring 写 “Delete a file or empty directory”，UI/API 无 `recursive` 标志或二次确认，误删不可恢复。
- **F4（低）同名上传静默覆盖**：无冲突提示、无重命名、无版本；第二次上传即替换原文件。
- **F5（低）列表无分页**：200 文件 46 KB 尚可；万级目录会线性放大响应体，且 UI 无上限。
- **F6（中）记忆检索阈值噪声**：真实嵌入（qwen3-embedding:4b）下无关文本相似度即达 0.61–0.76；默认库搜「汽油」命中 “number 42”（0.676）；`threshold=0.6` 的 dashboard 查询返回大量无关条目，且无精确 token 兜底（`_find_exact_query_docs` 只用于 delete/forget）。

## 5. 安全项：路径穿越（三条全部未拒绝）

1. **相对穿越** `GET /api/get_work_dir_files?path=../../etc` → **200**，返回 39 项（`alsa`、`fonts`、`gtk-3.0`…）。
2. **绝对路径** `GET /api/download_work_dir_file?path=/etc/passwd` → **200**，109 B，正文含 `kunweiz:x:1000:1001:Kunwei Zhang:/home/kunweiz:/bin/sh`。
3. **编码穿越** `GET /api/get_work_dir_files?path=..%2f..%2fetc` → **200**，返回 39 项。

补充：`path=/home/kunweiz` 列出 243 个宿主家目录条目；`POST /api/upload_work_dir_files` 的 `path=/tmp` 成功写入 `/a0` 外；同一文件随后可经 `delete_work_dir_file` 删除。错误文案：**无**，三式都按正常列表/下载返回，无 4xx、无“Invalid path”。泄露：宿主用户名、家目录名、`/etc/passwd` 内容。未对宿主真实文件执行删除，越界删除仅在沙箱 `/tmp` 的自建文件上验证。

## 6. 清理前后对比

| 项 | 开始 | 结束 | 说明 |
|---|---|---|---|
| `/a0` 列表条数 | 12 | 12 | `probe-edge-20261118/` 及其文件已删；磁盘 `find -name 'probe-*'` = 0 |
| 记忆总数（API `total_db_count`） | 7 | 15（05:17）→17（05:18） | 我的 `PROBE-*` 计数 0（11/13/14/15/16 已删，17 在独立子库后整目录删除）；peer 仍在追加 |
| `NTOTAL / DOCS` | — | 15 / 15 | 索引与文档数一致，无损坏 |
| flatpak 实例 | 1 | 2 | 主实例 1995448 + peer 的 `probe_b10c.py` flatpak run（pid 随其轮次变化）；我的探针均已退出 |
| health | 200 | 200 | 各步抽查均为 200 |

记忆增量全部来自并发 peer（`RW96ZRutwO` 05:02、`SECRET-*` 与 `Code word*` 05:11 起持续追加），**不是我写入，未删除**；因此记忆数未回到 7。文件侧完全恢复。测试前的记忆备份 `/tmp/memory-default-backup-20261118.tgz` 已在确认索引一致后删除。
