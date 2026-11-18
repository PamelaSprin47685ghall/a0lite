# 上游源码体检

体检对象：Agent Zero 上游源码 checkout。本文件只记录事实与命令原文，不构成构建说明。

## 1. Checkout

- 路径：`/home/kunweiz/Desktop/agent-zero`
- 获取方式：`cd /home/kunweiz/Desktop && git clone --depth 1 https://github.com/agent0ai/agent-zero agent-zero`
- 结果：新建克隆（此前 Desktop 下无 `agent-zero` 目录），耗时约 6 秒。
- 体积：`du -sh .` → `86M`；其中 `.git` → `29M`；不含 `.git` → `57M`。

## 2. HEAD

```
git -C /home/kunweiz/Desktop/agent-zero rev-parse HEAD
ba9b67df0f54ac78106ae85c552ef5d2458f7c9a

git log -1 --format='%H %ad %s'
ba9b67df0f54ac78106ae85c552ef5d2458f7c9a Sun Nov 1 22:10:32 2026 +0100
docs: refresh Launcher screenshot in README
```

工作树干净（`git status --porcelain` 无输出）。浅克隆，只有一个提交深度。

## 3. 关键路径存在性

逐项执行 `ls -d`。全部存在。

| 路径 | 结果 | 类型 |
| --- | --- | --- |
| `run_ui.py` | 存在 | 普通文件 |
| `requirements.txt` | 存在 | 普通文件 |
| `conf/model_providers.yaml` | 存在 | 普通文件 |
| `plugins/_memory` | 存在 | 目录 |
| `plugins/_desktop` | 存在 | 目录 |
| `plugins/_kokoro_tts` | 存在 | 目录 |
| `plugins/_whisper_stt` | 存在 | 目录 |
| `helpers/server_startup.py` | 存在 | 普通文件 |
| `models.py` | 存在 | 普通文件 |
| `helpers/providers.py` | 存在 | 普通文件 |
| `helpers/virtual_desktop.py` | 存在 | 普通文件 |

核验命令：

```
cd /home/kunweiz/Desktop/agent-zero && for p in run_ui.py requirements.txt conf/model_providers.yaml plugins/_memory plugins/_desktop plugins/_kokoro_tts plugins/_whisper_stt helpers/server_startup.py models.py helpers/providers.py helpers/virtual_desktop.py; do [ -e "$p" ] && echo "EXIST $p" || echo "MISSING $p"; done
```

## 4. requirements.txt 关键行原文

命令：

```
grep -n -E '^(torch|triton|onnxruntime|kokoro|misaki|spacy|openai-whisper|faiss-cpu|sentence-transformers|unstructured|langchain-unstructured|tiktoken|pydantic|numpy|zstandard|langsmith)' requirements.txt
```

实际命中 9 行（`requirements.txt` 共 75 行）：

```
6:faiss-cpu==1.11.0
17:kokoro>=0.9.2
21:langchain-unstructured==0.1.6
25:openai-whisper==20250625
35:sentence-transformers==3.0.1
36:tiktoken==0.8.0
37:unstructured[all-docs]==0.16.23
38:unstructured-client==0.31.0
43:pydantic==2.11.7
```

未出现的包：`torch`、`triton`、`onnxruntime`、`misaki`、`spacy`、`numpy`、`zstandard`、`langsmith`。这些在上游清单里没有显式行，只能由 `kokoro`、`sentence-transformers`、`openai-whisper`、`faiss-cpu` 传递引入。

### 与 flatpak 版的差异线索

`flatpak/requirements-flatpak.txt` 的文件头写明：它由上游 `requirements.txt` 派生，**移除了本地推理栈**，所有模型改由内置 Ollama 提供。逐项对照：

| 包 | 上游 `requirements.txt` | flatpak `requirements-flatpak.txt` |
| --- | --- | --- |
| `faiss-cpu` | `==1.11.0` | 移除（向量索引改用 Ollama） |
| `sentence-transformers` | `==3.0.1` | 移除（embeddings 走 Ollama `/api/embed`） |
| `torch` / `torchvision` | 无显式行（经传递依赖） | 移除 |
| `triton` / `nvidia-*` | 无显式行 | 移除 |
| `onnxruntime` | 无显式行 | 移除（TTS/OCR 走 Ollama） |
| `kokoro` | `>=0.9.2` | 移除 |
| `misaki` / `spacy` | 无显式行 | 移除 |
| `openai-whisper` | `==20250625` | 移除（转写走 Ollama） |
| `unstructured[all-docs]` | `==0.16.23` | 仅保留 `unstructured==0.16.23`，去掉 `[all-docs]` extra |
| `tiktoken` | `==0.8.0` | `>=0.12.0,<1.0`（litellm 在 Python 3.14 上要求） |
| `pydantic` | `==2.11.7` | `>=2.12.0,<3.0.0`（同上） |

两条可直接用于判断的注释原文：

```
# Everything resolves to a wheel on Python 3.14 except flask-basicauth and
# crontab, which ship as pure-Python sdists only.
```

```
# `unstructured` declares `numpy<2`, but no numpy 1.x wheel exists for cp314.
# The bound is a compatibility guard, not a requirement: the partitioners this
# build uses run on numpy 2, which flatpak/numpy-override.txt relaxes.
```

含义：flatpak 版按 **Python 3.14** 选版本，上游清单的 `tiktoken==0.8.0`、`pydantic==2.11.7` 在 cp314 上没有可用 wheel，两套清单不能混用。

## 5. dir source 跳过规则与 tmp

主 manifest `flatpak/org.agentzero.AgentZero.yml` 的 dir source 原文（第 169–174 行）：

```
    sources:
      - type: dir
        path: ..
        skip:
          - .git
          - tmp
```

结论：

- `agent-zero/.git` 会被 skip，不进入构建上下文（省下 29M）。
- `agent-zero/tmp` 会被 skip。实测该目录存在，仅含一个 0 字节的 `.gitkeep`：`du -sh tmp` → `0`。
- build 阶段还有第二道清理（第 162 行）：`rm -rf /app/share/agent-zero/.git /app/share/agent-zero/tmp /app/share/agent-zero/.flatpak-builder`。
- 未被 skip 的其余内容全部会进镜像：约 `57M`，其中 `webui/` 19M、`docs/` 21M、`tests/` 2.9M、`plugins/` 9.6M。

## 6. 构建前必须注意的三件事

**第一，这个 checkout 会在构建中被写脏，不能当只读源码复用。**
`scripts/build.sh` 会执行 `cp -a "$HERE/flatpak" "$A0_SRC/"`、`cp -a "$HERE/docs" "$A0_SRC/"`，生成 `wps-office-mcp-deps.tar.gz`，并用 `sed -i` 改写 `$A0_SRC/flatpak/org.agentzero.AgentZero.Wps.yml` 里的 sha256 pin。也就是说构建后 `/home/kunweiz/Desktop/agent-zero` 会多出 `flatpak/`、`docs/` 两个未跟踪目录，`Wps.yml` 的校验和也可能与仓库版本不同。若要重跑干净构建，先清掉这两处，不要 `git reset`（这是浅克隆，且改动全在未跟踪文件里）。

**第二，`path: ..` 是相对 manifest 的位置，不是相对 a0lite。**
dir source 的上界是 manifest 文件所在 `flatpak/` 目录的父目录。只有在 `scripts/build.sh` 已经把 `flatpak/` 复制进 checkout 之后，`..` 才等于 `agent-zero` 根。若绕过 build.sh、直接在 a0lite 仓库里跑 `flatpak-builder flatpak/org.agentzero.AgentZero.yml`，`..` 会解析成 `/home/kunweiz/Desktop`，把整个桌面目录当成构建上下文拷进去。必须走 `A0_SRC=/home/kunweiz/Desktop/agent-zero scripts/build.sh`。

**第三，上游清单与 flatpak 清单是两套依赖栈，不能互换。**
上游 `requirements.txt` 带完整本地推理栈（faiss-cpu、kokoro、sentence-transformers、openai-whisper、`unstructured[all-docs]`），flatpak 版全部删除、改由 Ollama 承担，并按 Python 3.14 抬高了 `tiktoken`（`>=0.12.0`）和 `pydantic`（`>=2.12.0`）。用上游清单会引入 torch 系源码构建与 cp314 无 wheel 的版本钉死；flatpak 镜像内必须使用 `flatpak/requirements-flatpak.txt`，上游那份只在此处作为差异参照，不参与安装。

## 7. 其他体检备注

- `a0lite/docs` 只有 `docs/setup/host-ollama.md` 一个文件；与上游 `docs/` 比对无同名文件，`cp -a` 合并不会覆盖上游文档。
- `usr/` 与 `tmp/` 受 `.gitignore` 管理（`usr/**` 只保留 `.gitkeep`），克隆后基本为空骨架，不构成体积来源。
- 未执行 `build.sh`，未安装任何软件，未改动 a0lite 仓库既有文件（本文件为唯一新增）。
