# Models 扩展盘点：`xiaomi-ocr` 能否被 Ollama 加载

对象：本机已装 `org.agentzero.AgentZero.Models`（user 安装，`kunweiz`）。
方式：只读。未启动 `ollama serve`，未 `flatpak run` 应用，未安装/卸载，未删除任何 blob。
时间：2026-11-17 23:25–23:40。

**结论：能。** `xiaomi-ocr:latest` 在本机有完整 manifest，位于 `models/manifests-v2/ollama.com/library/xiaomi-ocr/latest`（指向 blob 的符号链接），manifest 引用的模型层、投影层、参数层全部存在且 sha256 与体积逐字节吻合；ollama 0.40.13 的解析顺序是"先 `manifests-v2`、再回落 `manifests`"，且源码专门支持这种指向 blobs 的符号链接形式。此前 `functional-probes.md` 第 770 行"没有对应的 manifest 条目"的判断只看了旧的 `models/manifests` 目录，漏掉了 `manifests-v2`，该判断不成立。

---

## 1. 部署位置与目录结构

```
$ flatpak --user info org.agentzero.AgentZero.Models
            ID: org.agentzero.AgentZero.Models
           Ref: runtime/org.agentzero.AgentZero.Models/x86_64/1.0
          Arch: x86_64
        Branch: 1.0
        Origin: models-local
    Installation: user
Installed Size: 5.4 GB
        Commit: f011ae9bf72cb9fe0414820ae621c18a275511beb626791a3f14a23c30dc8b27
       Subject: Export org.agentzero.AgentZero.Models
          Date: 2026-11-01 10:12:43 +0000
```

```
$ ls -la ~/.local/share/flatpak/runtime/org.agentzero.AgentZero.Models/x86_64/1.0/
drwxr-xr-x 1 kunweiz kunweiz  38 Nov  1 18:14 f011ae9bf72cb9fe0414820ae621c18a275511beb626791a3f14a23c30dc8b27
lrwxrwxrwx 1 kunweiz kunweiz  64 Nov  1 18:14 active -> f011ae9b...
```

实际内容在 `.../x86_64/1.0/active/files/`（下称 `$M`）：

```
$ ls -la $M
-rw-r--r-- 1 kunweiz kunweiz    0 Nov  1 18:14 .ref
drwxr-xr-x 1 kunweiz kunweiz   12 Jan  1  1970 bin
drwxr-xr-x 1 kunweiz kunweiz   12 Jan  1  1970 lib
drwxr-xr-x 1 kunweiz kunweiz   68 Jan  1  1970 models

$ du -sh $M
5.1G	.../active/files

$ ls -la $M/bin
-rwxr-xr-x 2 kunweiz kunweiz 43783760 Jan  1  1970 ollama

$ find $M/lib -maxdepth 3 -type d
$M/lib
$M/lib/ollama
$M/lib/ollama/vulkan

$ ls -la $M/lib/ollama | head
-rw-r--r-- 2 kunweiz kunweiz   11345 DLPACK_LICENSE
-rwxr-xr-x 2 kunweiz kunweiz  816976 libggml-base.so.0.28.0
-rw-r--r-- 2 kunweiz kunweiz 1288488 libggml-cpu-alderlake.so
-rw-r--r-- 2 kunweiz kunweiz 1464616 libggml-cpu-cannonlake.so
...（libggml-cpu-*.so 共 14 个微架构变体、libllama*.so、libggml-*.so，合计 73 MB）

$ ls -la $M/models
drwxr-xr-x 1 kunweiz kunweiz 1988 Jan  1  1970 blobs
drwxr-xr-x 1 kunweiz kunweiz   36 Jan  1  1970 manifests
drwxr-xr-x 1 kunweiz kunweiz   20 Jan  1  1970 manifests-v2
drwxr-xr-x 1 kunweiz kunweiz  760 Jan  1  1970 metadata
```

体积分布：`bin` 42 MB、`lib` 73 MB、`models/blobs` 5.0 GB、`models/metadata` 48 KB。

判断：结构完整——二进制、CPU 内核、blobs、两套 manifest 目录、metadata 缓存都在。`lib/ollama` 里没有 `cuda_v12`/`cuda_v13`，与 manifest 的设计一致（CUDA 内核由独立的 Cuda 扩展提供）。

需要注意的一点：`app/org.agentzero.AgentZero/.../files/share/agent-zero/models` 是空目录（挂载点），运行时由 Flatpak 把本扩展挂上去；扩展未安装时它保持为空。

---

## 2. manifests 清单

```
$ find $M/models/manifests -type f | sort
$M/models/manifests/registry.ollama.ai/library/lfm3-omni/2b-q4_K_M
$M/models/manifests/registry.ollama.ai/library/qwen3-embedding/4b-q4_K_M

$ find $M/models/manifests -type f | wc -l
2
```

旧布局里**只有两个**文件，确实没有 `registry.ollama.ai/library/xiaomi-ocr/latest`。但新布局不是普通文件，而是符号链接，`find -type f` 看不见：

```
$ ls -laR $M/models/manifests-v2
.../manifests-v2/ollama.com/library:
drwxr-xr-x 1 kunweiz kunweiz 18 Jan  1  1970 lfm3-omni
drwxr-xr-x 1 kunweiz kunweiz 18 Jan  1  1970 qwen3-embedding
drwxr-xr-x 1 kunweiz kunweiz 12 Jan  1  1970 xiaomi-ocr

.../manifests-v2/ollama.com/library/lfm3-omni:
lrwxrwxrwx 1 kunweiz kunweiz 89 Nov  1 18:14 2b-q4_K_M -> ../../../../blobs/sha256-4c0ee9400634babb880868b873bcebf09fbbf1a5328e550bdbaff25888f1f7e2

.../manifests-v2/ollama.com/library/qwen3-embedding:
lrwxrwxrwx 1 kunweiz kunweiz 89 Nov  1 18:14 4b-q4_K_M -> ../../../../blobs/sha256-df5bd2e3c74cd8d069d21dc038f1b359fcdc9458fce1c99bd43c9eb1518ff907

.../manifests-v2/ollama.com/library/xiaomi-ocr:
lrwxrwxrwx 1 kunweiz kunweiz 89 Nov  1 18:14 latest -> ../../../../blobs/sha256-a3420f7b17e0827c9a477ff4395172e2e582fdc62b606044b6ca7c08e378c79a
```

```
$ find $M/models -type l -printf '%p -> %l\n'
（上面三条，全部指向 blobs）

$ find $M/models -xtype l
（无输出：没有断链）
```

判断：

- 三个模型都在 `manifests-v2` 里，包括 `xiaomi-ocr/latest`。
- 旧布局的两个文件是历史兼容副本（`lfm3` 1136 字节、`qwen3` 694 字节，比 v2 的 973/531 字节多了一层"manifest 自身"的包装）。`xiaomi-ocr` 只有 v2 布局，因为它是本机 `ollama create` 生成的，新版本只写 v2。
- 之前 `functional-probes.md` 只对 `models/manifests` 做 `find -type f`，因此漏判。这个错误值得记下来：**对 ollama 的模型库做静态盘点时，`find -type f` 会漏掉 v2 布局，必须同时看符号链接。**

---

## 3. blobs 清单与引用关系

```
$ find $M/models/blobs -type f -printf '%s %f\n' | sort -n
          18  sha256-ae40a217c1c4002e9358f0f6597a349acaace0cfb95dc53db7ce646d57a56271
          33  sha256-fc258d6aa9b979530ec86c8531955e2a87dcd852f63c9eaf10ce7ea5a0538c28
         120  sha256-7af043870a286761ef59b71c690ca2c163bc5a1d89b3bf32b228fe380882efd0
         242  sha256-e5983aafcdb73fd771661df195142ea7594c216fca8852fd1041745895f42d08
         265  sha256-2ca34c70bbf2dc85cb69688daf0b423bdc361504ea29d7f5a35c19f739d8ee0d
         531  sha256-df5bd2e3c74cd8d069d21dc038f1b359fcdc9458fce1c99bd43c9eb1518ff907
         824  sha256-a3420f7b17e0827c9a477ff4395172e2e582fdc62b606044b6ca7c08e378c79a
         973  sha256-4c0ee9400634babb880868b873bcebf09fbbf1a5328e550bdbaff25888f1f7e2
       10574  sha256-4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c
   207346624  sha256-634d6bc95781ebf4a3f06570a59859fa5082d488db540fd474bc6b4061aec90e
   529297664  sha256-1e497ff06b91a3d822c543066df3e9ef69c62c5423be09d739dfa1db55630d3a
   949841248  sha256-92907148363ed89f67c46a09264bf2635d4069a66ced26db75abd63370eddb7e
  1099630080  sha256-9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2
  2496703776  sha256-2b0cf8f17b4c723c27303015383c27ec4bf2d8314bb677d05e920dd70bb0f16b
（14 个文件，合计 5,282,832,972 字节）
```

### 3.1 `xiaomi-ocr` 的 manifest 全文

`$M/models/blobs/sha256-a3420f7b…`（824 字节，即 `manifests-v2/.../latest` 的目标）：

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": {
    "mediaType": "application/vnd.docker.container.image.v1+json",
    "digest": "sha256:7af043870a286761ef59b71c690ca2c163bc5a1d89b3bf32b228fe380882efd0",
    "size": 120
  },
  "layers": [
    {
      "mediaType": "application/vnd.ollama.image.model",
      "digest": "sha256:1e497ff06b91a3d822c543066df3e9ef69c62c5423be09d739dfa1db55630d3a",
      "size": 529297664,
      "from": "Xiaomi-OCR-0.Q4_K_M.gguf"
    },
    {
      "mediaType": "application/vnd.ollama.image.projector",
      "digest": "sha256:634d6bc95781ebf4a3f06570a59859fa5082d488db540fd474bc6b4061aec90e",
      "size": 207346624,
      "from": "Xiaomi-OCR-0.mmproj-bf16.gguf"
    },
    {
      "mediaType": "application/vnd.ollama.image.params",
      "digest": "sha256:fc258d6aa9b979530ec86c8531955e2a87dcd852f63c9eaf10ce7ea5a0538c28",
      "size": 33
    }
  ],
  "runner": "llamacpp",
  "format": "gguf"
}
```

配套的两个小 blob：

```
$ cat sha256-7af043…（config，120 字节）
{"model_format":"gguf","model_family":"qwen35","model_families":["qwen35"],"model_type":"752.39M","file_type":"Q4_K_M"}

$ cat sha256-fc258d…（params，33 字节）
{"num_ctx":8192,"temperature":0}
```

判断：manifest 结构与 `lfm3-omni` 完全同构（同样的 `schemaVersion`/`runner: llamacpp`/`format: gguf`），参数与 `docs/setup/host-ollama.md` 第 41–46 行的 Modelfile（`num_ctx 8192`、`temperature 0`）逐字一致。

### 3.2 全部 manifest 的 digest 匹配（重点）

脚本逐个读取三个 v2 manifest 与两个旧 manifest，把 `config`/`layers` 里的 digest 与 blobs 目录对照：

```
--- xiaomi-ocr:latest (manifests-v2 symlink)
    config sha256:7af043870a28 size=120 present=True
    layer model      1e497ff06b91 declared=   529297664 actual=   529297664 OK
    layer projector  634d6bc95781 declared=   207346624 actual=   207346624 OK
    layer params     fc258d6aa9b9 declared=          33 actual=          33 OK
--- lfm3-omni:2b-q4_K_M (v2)
    config sha256:e5983aafcdb7 size=242 present=True
    layer model      9f8d30e9d4fd declared=  1099630080 actual=  1099630080 OK
    layer projector  92907148363e declared=   949841248 actual=   949841248 OK
    layer license    4d28ca14dedc declared=       10574 actual=       10574 OK
    layer params     ae40a217c1c4 declared=          18 actual=          18 OK
--- qwen3-embedding:4b-q4_K_M (v2)
    config sha256:2ca34c70bbf2 size=265 present=True
    layer model      2b0cf8f17b4c declared=  2496703776 actual=  2496703776 OK

referenced: 13  of which missing: []
unreferenced blobs:
   a3420f7b17e0827c9a477ff4395172e2e582fdc62b606044b6ca7c08e378c79a 824
```

唯一的"未被 manifest 层引用"的 blob 就是 `a3420f7b` 本身——它是 manifest 内容，由符号链接引用，不是缺块。

逐字节复核（文件名即内容摘要）：

```
$ sha256sum sha256-a3420f7b…
a3420f7b17e0827c9a477ff4395172e2e582fdc62b606044b6ca7c08e378c79a  ...
$ sha256sum sha256-1e497ff0…
1e497ff06b91a3d822c543066df3e9ef69c62c5423be09d739dfa1db55630d3a  ...
$ sha256sum sha256-634d6bc9…
634d6bc95781ebf4a3f06570a59859fa5082d488db540fd474bc6b4061aec90e  ...
```

两个 GGUF 的文件头：

```
1e497ff06b91: GGUF  general.architecture qwen35  general.name "Xiaomi OCR 0"  general.size_label 752M
634d6bc95781: GGUF  general.architecture clip    general.type mmproj      general.size_label 101M
```

判断：OCR 的模型层与投影层都在 blobs 里，**而且被 `xiaomi-ocr` 的 manifest 明确引用**，体积与摘要都精确匹配；两个文件的 GGUF magic 与声明的架构（`qwen35` 主模型、`clip` 投影器）一致。不存在"有 blob 但无 manifest 指向"的情况。

---

## 4. ollama 二进制

```
$ $M/bin/ollama --version
Warning: could not connect to a running Ollama instance
Warning: client version is 0.40.13
（退出码 0）

$ ldd $M/bin/ollama | grep -i 'not found'
（无输出：沙盒外直接运行不缺库）
```

```
$ for a in qwen35 qwen3vl_merger clip lfm3; do printf '%s: ' "$a"; strings -a $M/bin/ollama | grep -c "$a"; done
qwen35: 49
qwen3vl_merger: 1
clip: 35
lfm3: 365
```

判断：版本 0.40.13，与 manifest 里 `ollama_version: 0.40.13` 的 metadata 一致。二进制内含 `qwen35`（49 处）与 `qwen3vl_merger`（vision projector 类型），说明 llama.cpp 后端认识这两个架构——这是"能加载"之外、"能推理"的必要条件。

---

## 5. 静态可加载性证明

`ollama show`/`list` 都需要 server，离线不可用，因此改用上游源码 + digest 匹配来证明。源码取自 `github.com/ollama/ollama` 标签 `v0.40.13` 的 `manifest/paths.go` 与 `manifest/manifest.go`。

### 5.1 名称解析：先 v2，后 legacy

```go
const (
	legacyDirName     = "manifests"
	v2DirName         = "manifests-v2"
	defaultPublicHost = "registry.ollama.ai"
	v2CanonicalHost   = "ollama.com"
)

func resolveManifestPath(n model.Name) (string, string, error) {
	...
	v2Path, err := V2PathForName(n)          // manifests-v2/ollama.com/library/<name>/<tag>
	if err != nil { return "", "", err }
	if runtime.GOOS == "windows" {
		_, err = filepath.EvalSymlinks(v2Path)
	} else {
		_, err = os.Stat(v2Path)             // 跟随符号链接
	}
	if err == nil {
		root, err := V2Path()
		return v2Path, root, err             // 命中即返回
	} else if !os.IsNotExist(err) {
		return "", "", err
	}

	legacyRoot, err := Path()
	... // 仅当 v2 不存在才回落到 manifests/
}
```

`canonicalV2Name` 把 `registry.ollama.ai` 归一到 `ollama.com`，`v2NameFilepath` 拼成 `<host>/<namespace>/<model>/<tag>`——正好对应磁盘上的 `ollama.com/library/xiaomi-ocr/latest`。

### 5.2 符号链接 manifest 是一等公民

```go
if info.Mode()&os.ModeSymlink != 0 {
	base := filepath.Base(target)
	if !blobFilenamePattern.MatchString(base) {
		return nil, fmt.Errorf("manifest symlink target %q is not a sha256 blob", target)
	}
	digest := strings.ToLower(strings.TrimPrefix(base, "sha256-"))
	blobPath, err := BlobsPath("sha256:" + digest)
	...
	if !sameFile(target, blobPath) {
		return nil, fmt.Errorf("manifest symlink target %q does not match blob %q", target, blobPath)
	}
	...
}
```

```go
func (m *unverifiedManifestFile) verifiedData() ([]byte, string, error) {
	data, err := io.ReadAll(m.file)
	sum := sha256.Sum256(data)
	digest := fmt.Sprintf("%x", sum)
	if err := m.checkDigest(digest); err != nil { return nil, "", err }
	return data, digest, nil
}
```

这解释了两件事：为什么 v2 条目是符号链接（manifest 内容按 blob 存、按名链接），以及为什么我们的三条链接能通过校验——目标名是 `sha256-a3420f7b…`，`sameFile` 比对通过，读出的内容 sha256 也等于该摘要。

还有一个容易踩的细节：符号链接分支是**提前 return** 的，它跳过了后面那句

```go
if !pathWithin(target, resolvedRoot) {
    return nil, fmt.Errorf("manifest path %q resolves outside manifest directory", path)
}
```

也就是说，链接指向 `manifests-v2/` 之外的 `blobs/` 是被显式允许的；禁止"解析到目录外"的规则只作用于普通文件。

### 5.3 列表也认 v2

```go
func namedManifestRefs(continueOnError bool) (map[model.Name]namedManifestRef, error) {
	manifestsV2, err := V2Path()
	if err := collectManifestRefs(refs, manifestsV2, continueOnError); err != nil { ... }
	manifests, err := Path()
	...
}

// collectManifestRefs 内部
matches, _ := filepath.Glob(filepath.Join(root, "*", "*", "*", "*"))
for _, match := range matches {
	fi, err := os.Lstat(match)   // 对符号链接返回链接本身
	if !fi.IsDir() {             // 所以 "latest" 被视为文件条目
		rel, _ := filepath.Rel(root, match)
		n := parseStoredManifestFilepath(rel)
		...
	}
}
```

判断：`/api/tags` 会列出 `xiaomi-ocr:latest`，`/api/chat` 用同名请求时会先命中 v2 路径。这条链路上没有任何一环依赖旧 `manifests/` 目录。

### 5.4 仍需 server 才能验证的部分

真正的"加载"（mmap 权重、建 KV cache、推理）只能在 `ollama serve` 内发生，本轮被明令禁止。因此严格地说，本报告证明的是：**名称可解析、manifest 可通过摘要校验、全部层 blob 存在且完整、后端认识该架构**。这四条覆盖了"能否被加载"的全部静态前提；唯一的剩余风险是运行时显存/内存不足，而那是资源问题，不是清单问题。

---

## 6. 与目标机事实对照

```
本机（构建机）
  Models commit : f011ae9bf72cb9fe0414820ae621c18a275511beb626791a3f14a23c30dc8b27
  Installed Size: 5.4 GB
  manifest      : manifests-v2/.../xiaomi-ocr/latest 存在，指向 824 字节 manifest blob
  配置中体积     : model_type 752.39M、file_type Q4_K_M（与文档 "0.74 GB" 吻合）
```

目标机（既有记录 `recon-target.md:324`、`target-prep.md:171`）：

```
/api/tags 返回 xiaomi-ocr:latest
ollama list 片段：xiaomi-ocr:latest   0.74 GB
```

判断：两边一致——同一个 0.74 GB 的 Q4_K_M 模型、同一个名字与 tag。本机 manifest 并未缺失，所以不存在"本机 Models 与目标机不是同一份打包产物"的推断空间。`README.md` 第 169 行"Ollama inside the sandbox: … xiaomi-ocr:latest"与 `docs/setup/host-ollama.md` 第 13 行的描述，均与磁盘现状相符。

---

## 7. 顺带核实：D4 的上游默认值

### 7.1 `per_document_timeout` 的默认值

```
$ grep -rn 'per_document_timeout' plugins/_document_query/
plugins/_document_query/README.md:26:| per_document_timeout | 60 | Max time for a single document parse |
plugins/_document_query/default_config.yaml:8:per_document_timeout: 60     # max time for a single document parse
plugins/_document_query/helpers/document_query.py:468:            per_doc_timeout = self.config.get("per_document_timeout", 60)
plugins/_document_query/helpers/parsers/liteparse.py:82:            timeout = float(config.get("per_document_timeout", 60))
plugins/_document_query/webui/config.html:12:            per_document_timeout: 60,
plugins/_document_query/webui/config.html:51:            this.ensureNumber('per_document_timeout', 60, 1);
plugins/_document_query/webui/config.html:110-111: @change / x-model.number
```

默认值 **60 秒**，出现在两个执行点：

- `document_query.py:468` 取值，第 473 行作为 `timeout` 传入 `_parse_document`，第 512 行再传给 `parser.parse(...)`。
- `liteparse.py:82` 又独立读一次，作为 `subprocess.run(..., timeout=...)` 的上限。

也就是说 LiteParse 这条路径上有两层 60 秒：外层 `asyncio.wait_for` 与内层子进程超时，谁先到谁生效。

### 7.2 `asyncio.wait_for` 的包裹范围

`plugins/_document_query/helpers/parsers/base.py`：

```python
36	    async def parse(
37	        self,
38	        document: FetchedDocument,
39	        config: dict,
40	        timeout: float = 60.0,
41	        thread_offload: bool = True,
42	    ) -> str:
43	        try:
44	            if thread_offload:
45	                return await asyncio.wait_for(
46	                    asyncio.to_thread(self._parse_sync, document, config),
47	                    timeout=timeout,
48	                )
49	            else:
50	                return await asyncio.wait_for(
51	                    self._parse_async(document, config),
52	                    timeout=timeout,
53	                )
54	        except asyncio.TimeoutError:
55	            PrintStyle.error(
56	                f"Parser {self.__class__.__name__} timed out after {timeout}s on {document.uri}"
57	            )
58	            raise ValueError(f"Document parsing timed out after {timeout}s: {document.uri}")
```

包裹范围：只包住 **单个 parser 的单次解析调用**（第 45–48 行包 `asyncio.to_thread(_parse_sync)`，第 50–53 行包 `_parse_async`）。函数签名默认 `timeout=60.0`（第 40 行）。超时被转成 `ValueError` 抛出（第 58 行），由 `_parse_document` 捕获并记入 `errors_seen`，然后尝试下一个 parser（`document_query.py:505-524`）。因此单文档超时不会中断整批，只会让该文档落到下一个解析器或最终报 "No parser succeeded"。

注意：`wait_for` 取消的是*等待*，`asyncio.to_thread` 里的线程不会被强杀，超时后该线程仍可能跑完——这是 `BaseParser` 这一层的既有语义，不是本机的问题。

---

## 8. 结论

**`xiaomi-ocr` 在本机能被 Ollama 加载。** 依据：`models/manifests-v2/ollama.com/library/xiaomi-ocr/latest` 存在（符号链接），指向 824 字节的合法 v2 manifest；该 manifest 的 config（120 B）、模型层（529,297,664 B）、投影层（207,346,624 B）、参数层（33 B）全部存在，声明体积与实际体积逐条相等，文件名摘要与内容 sha256 逐字节吻合（含 `1e497ff0…`、`634d6bc9…` 两个 GGUF）；ollama 0.40.13 的 `resolveManifestPath` 先查 `manifests-v2` 并用 `os.Stat` 跟随符号链接，`openManifestFileLocked` 专为这种 "symlink → blobs/sha256-*" 形式写了校验分支，且该二进制的 strings 里含 `qwen35` 与 `qwen3vl_merger`。唯一未验证的是真实推理输出，因为那需要启动 `ollama serve`，超出本次只读授权。
