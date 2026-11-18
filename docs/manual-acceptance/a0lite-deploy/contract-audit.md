# a0lite 运行时补丁契约审查

- 审查对象：`/home/kunweiz/Desktop/a0lite/flatpak/a0flatpak/`（审查时 16 个模块，修复后 15 个）、`flatpak/agent-zero.sh`、`flatpak/requirements-flatpak.txt`、`flatpak/overrides.txt`、`flatpak/README.md`、launcher 的 manifest 对照。
- 上游参考：`/home/kunweiz/Desktop/agent-zero`，`HEAD = ba9b67df0f54ac78106ae85c552ef5d2458f7c9a`（2026-11-01，浅克隆，未修改）。
- 方法：静态阅读 + `grep`/`sed` 定位 + 下载 PyPI wheel 只读检查（`langchain-community 0.3.19`、`stealth-browser 0.2.0`），**未安装任何包、未执行构建、未运行上游代码**。
- 结论统计：核对 15 项；**确定不匹配 13 处**（运行期 10 处，其中 5 处会直接抛异常或使补丁失效；路径/配置 2 处；文档与依赖清理 1 组），已全部修复；**存疑 16 项**，只能实机确认。

## 0. `apply()` 顺序与两条全局前提

`flatpak/a0flatpak/__init__.py:23-60` 的实际顺序：

```
compat → base_dir → provider_urls → embeddings → vector_store
→ speech → rfc_loop → ocr → parsers → browser → desktop
→ packages → code_exec → serve
```

两条必须成立的前提：

1. **`base_dir.apply()` 必须早于所有读取 `files.get_abs_path()` 的插件模块导入**。当前满足：`desktop.apply()` 才第一次导入 `plugins._desktop.helpers.desktop_session`，此时 `helpers.files._base_dir` 已是 `A0_BASE_DIR`。
2. **`a0flatpak.apply()` 必须早于 `run_ui.py` 的顶层导入**。launcher 用 `import a0flatpak; a0flatpak.apply(); runpy.run_path('run_ui.py', run_name='__main__')` 满足；`systemd/a0-desktop-start:17` 也满足。

另一条隐藏前提：**不要给 launcher 加 `--dockerized=true`**。`helpers/runtime.py:59-65` 的 `is_dockerized()` 会变成 True，`extensions/python/startup_migration/_05_framework_dependencies.py:16-23` 就会读取**上游** `requirements.txt` 并用 `uv pip install` 重装 `tiktoken==0.8.0` 等 cp314 不可用/不匹配的 pin，同时 `helpers/settings.py:575` 会尝试 `chpasswd`。当前不传该参数是刻意且必要的。

---

## 1. `run_uvicorn_with_retries` / `UiServerRuntime.build_asgi_app` / `webapp`

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `run_uvicorn_with_retries` | `helpers/server_startup.py:239-249`：`def run_uvicorn_with_retries(*, host, port, build_asgi_app, flush_callback, access_log=False, log_level="info", ws="wsproto", startup_config=None)` | `serve.py:32` 取模块属性并整体替换；`serve.py:33-37` 用 `*args, **kwargs` + `kwargs.get("build_asgi_app")` | **匹配**：参数是 keyword-only，唯一调用点 `run_ui.py:44-51` 用 `build_asgi_app=` 关键字传入 |
| 调用方 | `run_ui.py:47`：`build_asgi_app=server_runtime.build_asgi_app` | `serve.py:38` 用 `getattr(build, "__self__", None)` 取 runtime | **匹配**：是绑定方法，`__self__` 是实例 |
| `build_asgi_app` | `helpers/ui_server.py:229-256`：`def build_asgi_app(self, startup_monitor)` | `build_wrapped(startup_monitor)` 位置参数调用 | **匹配** |
| `webapp` | `helpers/ui_server.py:75-80`：`@dataclass class UiServerRuntime` 首个字段 `webapp: Flask` | `getattr(..., "webapp", None)` | **匹配**（`webapp` 真实存在；本次修复后已不再依赖它） |
| 替换层 | `helpers/virtual_desktop_routes.py:399-440` 替换的是**类**方法 `UiServerRuntime.build_asgi_app`，不是实例 | `serve.py:4-6` 旧 docstring 说 “replaces that method on the instance” | **不匹配（仅推理/文档）**：行为不受影响，已改写 docstring |
| `/api/health` | `api/health.py:4-26` 已有 `HealthCheck`，`requires_auth=False`、`requires_csrf=False`，经 `helpers/api.py:206-221` 的 `/api/<path:path>` 路由返回 200 | `health.py` 声称“本快照没有该路由”，并在 Flask 上再注册精确规则 | **不匹配（前提错误）**：原规则会遮蔽上游 handler，把响应从 `{"gitinfo":…}` 换成 `{"status":"ok"}` |

**处理**：

- `serve.py` 只保留鉴权包装；`A0_AUTH_KEY` 为空时不再包装。
- 删除 `flatpak/a0flatpak/health.py`（无引用、上游已有路由）。
- 修正 `serve.py` docstring。

结论：**签名与调用约定匹配；health 补丁是冗余覆盖，已移除。**

---

## 2. `ProviderManager._load_providers` / `_raw` / `_options` / YAML 键名

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `_load_providers` | `helpers/providers.py:63-108`，无参数，返回 `None` | `provider_urls.py:65-67` 包装 `load_providers(self)` 并丢弃返回值 | **匹配** |
| `_raw` | `helpers/providers.py:16` 类属性；`:97` 赋值为 `{type: [entry, ...]}`，entry 形如 `{"id": pid, **cfg}` | `_rewrite_raw` 遍历 `raw.values()`，`_rewrite_entry` 用 `entry["id"]` | **匹配** |
| `_options` | `helpers/providers.py:17`、`:100-108` | 未使用 | **匹配**（无需处理） |
| ollama 条目 | `conf/model_providers.yaml:146-155`：`models_list.endpoint_url: "/api/tags"`、`kwargs.api_base: "http://host.docker.internal:11434"` | `_LOCAL_REWRITES["ollama"] = (OLLAMA_URL, f"{OLLAMA_URL}/api/tags")` | **匹配**：消费方 `plugins/_model_config/api/model_search.py:142-166` 对绝对 URL 直接使用 |
| lm_studio 条目 | `conf/model_providers.yaml:99-107`：`models_list.endpoint_url: "/v1/models"`、`default_base: "http://host.docker.internal:1234"`、`kwargs.api_base: ".../v1"` | 只改 `kwargs.api_base` 为 `http://127.0.0.1:11434/v1`，保留相对 `endpoint_url` | **匹配**：`_resolve_url` 优先用 `api_base`，并把 `/v1/models` 去重为 `/models` → `…/v1/models` |
| 嵌入段 | `conf/model_providers.yaml:268-272`（lm_studio，无 `models_list`）、`:286-290`（ollama，无 `models_list`） | `isinstance(models_list, dict)` 保护 | **匹配** |

补充事实（非缺陷）：lm_studio 被别名到 Ollama 的 OpenAI 兼容端点，是刻意语义；`models_list.default_base` 仍保留 Docker 地址，但 `_resolve_url` 在 `api_base` 存在时不会用它。

结论：**结构与键名全部匹配，无需修改。**

---

## 3. `models.get_embedding_model` 的签名、返回类型与导入时机

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| 签名 | `models.py:1012-1019`：`def get_embedding_model(provider: str, name: str, model_config: Optional[ModelConfig] = None, **kwargs: Any)` | `embeddings.py:84`：`(provider, name, model_config=None, **kwargs)` | **匹配** |
| 返回类型 | 返回 `LiteLLMEmbeddingWrapper | LocalSentenceTransformerWrapper`（均实现 langchain `Embeddings` 接口） | 返回 `OllamaEmbeddings`，子类继承 `langchain_core.embeddings.Embeddings`，提供 `embed_documents`/`embed_query`/异步版本，并设 `model_name` | **兼容**：`helpers/vector_db.py:41-58` 依赖 `model.model_name`（存在）；`CacheBackedEmbeddings.from_bytes_store` 只依赖 `Embeddings` 接口 |
| 调用方 | `plugins/_model_config/helpers/model_config.py:937-943`、`plugins/_memory/helpers/memory.py:159-164`、`preload.py:12-21`；`agent.py:844-846` 的 `get_embedding_model()` 返回 `None`（`extensible`，无插件覆盖） | 只改 `models.get_embedding_model` 模块属性，依赖调用方在**调用时**做属性查找 | **匹配**：上述调用都在函数体内 `models.get_embedding_model(...)`，不是 import 时绑定 |
| `models` 可导入性 | `models.py:20-47` 顶层导入 `litellm`、`openai`、`langchain_core.*`、`langchain.embeddings.base`、`helpers.settings` 等；`sentence_transformers` 仅在 `TYPE_CHECKING`（`:49-50`）和函数内出现 | `embeddings.apply()` 直接 `import models` | **匹配（存在可解析的导入环）**：`models.py:25` → `helpers.settings`，而 `helpers/settings.py:12` → `models`；两侧都只在函数体内使用对方（`models` 顶层无 `settings.` 调用，`settings` 顶层无 `models.` 调用），且 `apply()` 在导入 `helpers.settings` 之前先导入 `models`，按安全顺序解析。`langchain` 由 `langchain-community 0.3.19` 的 METADATA（`langchain>=0.3.20,<1`）传递安装 |
| 配置读取时机 | `models.py` 不在导入期读 `A0_*`；但 `a0flatpak` 各模块在**模块导入时**读 `OLLAMA_HOST`、`A0_EMBEDDING_MODEL`，早于 `run_ui.py:101` 的 `dotenv.load_dotenv()` | 旧实现把 `.env` 留到 run_ui 才加载 | **不匹配（清单外）**：`usr/.env` 中的补丁配置不会生效 |

**处理**：在 `__init__.py` 的 `base_dir.apply()` 之后、`provider_urls` 之前加载 `helpers.dotenv.load_dotenv()`（此时 `files._base_dir` 已指向可写根，`usr/.env` 路径正确）。

结论：**签名与返回类型匹配；补了配置加载时机。**

---

## 4. `a0flatpak/vector_store.py` 替换的 faiss 接口

上游使用面（全部为顶层 `import faiss`）：

- `helpers/vector_db.py:5-6`、`:64-72`：`faiss.IndexFlatIP(len(...))` + `MyFaiss(..., distance_strategy=DistanceStrategy.COSINE, relevance_score_fn=cosine_normalizer)`。
- `plugins/_memory/helpers/memory.py:9-11`、`:214-231`：同上；`:416/427/436/464/492` 大量 `await self.db.adelete(ids=...)`；`:555-556` 持久化为 `index.faiss`。
- 上游 `langchain-community==0.3.19`（requirements-flatpak.txt:47）内部：
  - `langchain_community/vectorstores/faiss.py:918-950` `FAISS.delete()` → **`:940` `self.index.remove_ids(...)`**；
  - `:701-720` MMR → `self.index.reconstruct(int(i))`；
  - `:1147-1160` `save_local` → `faiss.write_index`；`:1167-1216` `load_local` → `faiss.read_index`；
  - `:998-1001` 只在 `from_embeddings` 内用 `IndexFlatIP`/`IndexFlatL2`（上游不走该构造路径）；
  - `:312/416` 仅在 `_normalize_L2=True` 时调 `faiss.normalize_L2`（上游显式注释掉 `normalize_L2`，默认 False）。

| 我方 shim（`vector_store.py`） | 结论 |
|---|---|
| `module.IndexFlatIP(d)`、`add`、`search`、`reconstruct_n`、`ntotal`、`d`、`__len__` | **匹配**上游直接使用面 |
| `write_index` / `read_index` + pickle 格式 | **匹配** `save_local`/`load_local` 的调用契约；与真实 faiss 文件不互通（文档已声明） |
| 缺少 `remove_ids` | **不匹配**：`adelete` → `FAISS.delete` 必抛 `AttributeError`。已补 |
| 缺少 `reconstruct` | **潜在不匹配**：MMR 路径会抛；已补 |
| 缺少 `IndexFlatL2` / `normalize_L2` / `IndexFlat.merge_from` | 上游当前路径不可达；**未实现**，列入存疑 |
| `sys.modules["faiss"]` 的 `ModuleType` 无 `__spec__` | 若任何依赖调用 `importlib.util.find_spec("faiss")` 会抛 `ValueError`；当前上游无此调用，列入存疑 |
| `apply()` 的两段 `if existing` | 逻辑冗余但幂等；已合并为一条 |

结论：**接口不完整（delete 必崩），已修 `remove_ids` 与 `reconstruct`。**

---

## 5. `plugins/_kokoro_tts/helpers/runtime.py`

| 符号 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `synthesize_sentences` | `runtime.py:141-143`：`async def synthesize_sentences(sentences: list[str], config: dict[str, Any] \| None = None) -> str` | `speech.py:73-80` 同签名，返回 base64 `str` | **签名匹配**；原请求体未带 `response_format`，而消费方 `api/synthesize.py:19` 与 `webui/js/tts-service.js:290` 硬编码 `audio/wav` → **返回体契约不匹配**，已补 `response_format: "wav"` |
| `is_downloaded` | `runtime.py:135-139`：`async def is_downloaded(config=None) -> bool` | `speech.py:82-83` 同签名，恒 `True` | **匹配** |
| `is_updating` | **不存在**。上游只有模块变量 `runtime.py:36 is_updating_model = False` 和 `is_downloading()`（`:129-133`） | `speech.py:85-86` 注入 `is_updating()` 并赋值到模块 | **不匹配**：符号不存在，且全仓无消费方（grep 仅命中 `is_updating_model`） |
| `is_downloading` | `runtime.py:129-133`；默认 `voice=paradee` 时调 `paradee.model_status()`（`paradee.py:25-26`，只读内存变量，无重依赖） | 未覆盖 | **未覆盖但安全**：`api/status.py:28` 轮询不会崩 |
| `preload` | `runtime.py:92-96`；paradee 分支 `paradee.preload()`，kokoro 分支 `from kokoro import KPipeline` | 未覆盖 | **未覆盖**：全仓无调用方；若被调用，`kokoro` 已被 stub 为空模块，会 `ImportError` |

消费方：`api/synthesize.py:15` 单参调用；`webui/kokoro-tts-store.js` 只读 `result.audio`/`mime_type`。

**处理**：删除不存在的 `is_updating` 注入与函数；`/v1/audio/speech` 请求补 `"response_format": "wav"`，兑现消费方的 WAV 声明。

结论：**主链路签名匹配；`is_updating` 是幻觉符号，已删；补了 WAV 返回格式。**

---

## 6. `plugins/_whisper_stt/helpers/runtime.py`

| 符号 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `transcribe` | `runtime.py:153-155`：`async def transcribe(audio_bytes_b64: str, config=None) -> dict` | `speech.py:106-107` 同签名 | **匹配** |
| `_transcribe` | `runtime.py:164-166`：`(model_name, audio_bytes_b64, *, language=None) -> dict` | `speech.py:100-102` 逐字相同 | **匹配** |
| `normalize_config` | `runtime.py:42`：`(config: dict \| None) -> dict` | `speech.py:109` 调用模块属性 | **匹配** |
| `get_config` | `runtime.py:90`：`() -> dict` | 同上 | **匹配** |
| `_resolve_language` | `runtime.py:189`：`(language: str) -> str \| None` | 同上 | **匹配** |
| `preload` | `runtime.py:106`：`async def preload(model_name: str \| None = None)`（隐式 `None`） | `speech.py:116-117` 返回 `True` | **参数匹配**；返回值差异无消费方（`hooks.py:18-21` 不读返回值） |
| `is_downloaded` | `runtime.py:149`：`async def is_downloaded() -> bool`（零参） | `speech.py:119-120` 多一个可选 `config` 参数 | **兼容**：所有调用点零参（`api/status.py:23`） |
| 返回 dict | 上游返回 whisper 原始结果（含 `text`/`segments`/`language`） | `_transcription_request` 用 `setdefault` 保证三键；消费方只读 `text`/`language`（`api/transcribe.py:19-23`、前端 store） | **匹配** |
| `is_downloading` | `runtime.py:145-146`：返回 `is_updating_model` | 未覆盖 | **未覆盖但安全** |
| `get_loaded_model_name` | `runtime.py:96-97`：返回 `_model_name`，只在 `_preload` 里赋值 | 未覆盖 | **未覆盖**：`loaded_model` 恒 `""`，UI 显示空白；非崩溃 |

**处理**：无改动。

结论：**符号、签名、返回 dict 全部匹配；两处“未覆盖”只影响显示。**

---

## 7. `plugins/_document_query/helpers/parsers/{image,pdf}.py`

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `ImageParser._parse_sync` | `image.py:7-10`：`def _parse_sync(self, document: FetchedDocument, config: dict) -> str` | `ocr.py:112-114`：`lambda self, document, config: …` | **匹配** |
| `PdfParser._parse_sync` | `pdf.py:11-14`：`def _parse_sync(self, document: FetchedDocument, config: dict) -> str` | `ocr.py:92-104` 返回 `def parse(document, config)`；`ocr.py:118` 取类属性 `original` 后 `original(document, config)` | **不匹配（两处）**：包装器缺 `self`（描述符绑定后会多传实例）；`original` 是未绑定函数，调用少传 `self` |
| 调用约定 | `parsers/base.py:36-46`：`asyncio.to_thread(self._parse_sync, document, config)` | 同上 | **不匹配**：必然 `TypeError` |
| `document.content` | `helpers/fetch.py:20-40`：`@dataclass(frozen=True) FetchedDocument` 字段 `content: bytes`、`suffix()` 成员方法、`local_file()` | `getattr(document, "content", b"")`、`getattr(document, "suffix", lambda: "")()` | **匹配** |
| 异常回退 | `pdf.py:14-23`：无文本且 `pdf_ocr_fallback=False` 时抛 `ValueError`；默认 True 时走 `pdf2image`/`pytesseract` | 旧包装器不捕获，Ollama 回退永远不会触发 | **语义不成立**：PDF 扫描件仍会失败 |

**处理**：包装器改为 `def parse(self, document, config)`，内部 `original(self, document, config)`；只在原策略失败时用 Ollama 渲染回退（原策略在此处本来就是可选链）；并在回退前读取 `config.get("pdf_ocr_fallback", True)`，关闭时不再把整份 PDF 送视觉模型。

结论：**修掉两处 `self` 错配，让回退真正可达，并遵守 `pdf_ocr_fallback`。**

---

## 8. `a0flatpak/parsers.py` 替换的 unstructured 兜底

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| 模块与类 | `plugins/_document_query/helpers/parsers/unstructured.py:11-25`：`class UnstructuredParser(BaseParser)`、`mimetypes = ["*"]`、`def _parse_sync(self, document, config)` | `parsers.py:196` 导入同名模块与类 | **匹配** |
| 替换方式 | `UnstructuredParser` 是普通类方法（描述符） | `parsers.py:201-203`：`lambda self, document, config: _catch_all_parse(...)` | **匹配** |
| 文档接口 | `FetchedDocument.content`、`.suffix()` | `_catch_all_parse` 用两者 | **匹配** |
| 策略顺序 | 上游 `langchain_unstructured.UnstructuredLoader(... strategy="hi_res")` | 依次 `unstructured.partition.auto.partition` → soffice → Ollama vision | **语义不同但成立**：见存疑 7 |
| 触发面 | `UnstructuredParser` 是 `mimetypes=["*"]` 的最后一个；`ImageParser._parse_sync` 会委托它（`image.py:9-10`） | `ocr.apply()` 先替换 `ImageParser`；`parsers.apply()` 再替换兜底 | **匹配**（`ocr` 在 `parsers` 之前，`__init__.py:55-59`） |

结论：**符号与签名匹配，无需修改。**

---

## 9. `a0flatpak/browser.py` 与 Patchright / `stealth-browser`

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `hooks.prepare_playwright_cache` | `plugins/_browser/hooks.py:110-117`，返回 `cleanup_playwright_cache()` 的 dict 并加 `binary` | `browser.py:64-77` 用系统 Chrome 的 `{binary, errors, warnings, removed, backup, source}` 替换 | **匹配**：消费方 `helpers/runtime.py:1141-1155` 只读 `errors` 和 `binary`；`startup_migration/_20_browser_playwright_cache.py:38-47` 只读 `errors`/`migrated`/`removed` |
| `hooks.install` | `hooks.py:120-133`，返回 `prepare_playwright_cache()` | `browser.py:79-83` 直接返回同一 dict | **匹配** |
| 真实启动路径 | `plugins/_browser/helpers/runtime.py:1145` `from patchright.async_api import async_playwright`；`:1188` `launch_kwargs["executable_path"] = str(browser_binary)` | 用系统 Chrome 作为 `executable_path` | **匹配**：这才是让浏览器工作的接缝 |
| `stealth_browser` | **上游全仓 0 引用**（`rg stealth_browser` 无结果）；`requirements.txt` 也没有 | `browser.py:87-131` 替换 `stealth_browser.browser.BrowserPool.start`，并依赖 `ULTRA_STEALTH_CHROMIUM_ARGS`、`_browser`、`_current_proxy`、`_setup_proxy_auth` | **不匹配（语义不成立/死代码）**：库 API 本身对得上（wheel 内 `BrowserPool.start(proxy=None)`、`ULTRA_STEALTH_CHROMIUM_ARGS` 由 `.stealth` 导入），但**没有任何上游代码调用它** |

**处理**：删除 `_patch_stealth_browser()` 与 `stealth-browser==0.2.0`、`nodriver>=0.48,<0.51` 两条依赖；改写模块 docstring 为实际路径（Patchright + `executable_path`）。

结论：**hooks 接缝匹配；stealth-browser 接线是无效补丁，已移除。**

---

## 10. `plugins/_desktop` 与 `helpers/virtual_desktop`

| 符号 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `DesktopSessionManager._allocate_endpoint_locked` | `desktop_session.py:1591-1601`，`(self) -> tuple[int,int]` | `desktop.py:244-254` `(self, *args, **kwargs)`，返回主机 display + 空端口 | **匹配**（仅系统会话调用它，`:616` 是唯一调用点） |
| `_session_env` | `:1557-1574`，`(self, session) -> dict` | `desktop.py:256-266` 同签名 | **匹配** |
| `_spawn_desktop_locked` | `:694-736`，`(self, session) -> None` | `desktop.py:268-384` 同签名 | **匹配** |
| `_prepare_desktop_launchers` | `:1033`，`(self, session) -> None` | `desktop.py:98-104` 同签名，调用 `libreoffice.find_soffice()`（`_office/helpers/libreoffice.py:21` 存在） | **匹配** |
| `collect_desktop_status` | `:1715-1764`，零参，返回含 `binaries`、`xpra_html_root` | `desktop.py:152-174` 调用原函数后覆写 `healthy/missing/state` | **匹配** |
| `STATE_DIR` / `SESSION_DIR` / `PROFILE_DIR` | `:30-33`：`STATE_DIR = files.get_abs_path("usr","plugins",PLUGIN_NAME)`，`PROFILE_DIR = STATE_DIR / "profiles"` | 旧 `desktop.py:110-135` 只改 `STATE_DIR`/`SESSION_DIR`，不改 `PROFILE_DIR`，且把 state 放到 `$BASE/plugins/_desktop` | **不匹配**：`_ensure_system_desktop_locked:617` 用旧 `PROFILE_DIR`（只读树）→ `mkdir` 失败；补丁本身还是冗余的（`base_dir.apply()` 已让导入时的 `STATE_DIR` 可写） |
| `PLUGIN_NAME` / `SYSTEM_SESSION_ID` | `:26-27` | `desktop.py:258,269` 使用 | **匹配** |
| `XPRA_PORT_BASE` / `MAX_SESSIONS` / `MAX_SCREEN_WIDTH` / `MAX_SCREEN_HEIGHT` | `:39-44` | `desktop.py:248-249,313` 使用 | **匹配** |
| `_port_is_free` / `_require_binary` / `_wait_for_port` | `:2536-2574`：`_port_is_free(port)`、`_require_binary(name)`、`_wait_for_port(host, port, timeout=15.0, process=None)` | `desktop.py:252,282,336-341` 用 `process=` 关键字 | **匹配** |
| `_xpra_shadow_command` | `:1851-1879`，签名 `(xpra: str, session: DesktopSession) -> list[str]`；字面量列表中 `:1874` 有 `"--speed=80"` | `desktop.py:352-354` 先过滤 `--encoding=`，再 `command.index("--speed=80") + 1` 插入 | **当前匹配，但脆弱**：`--speed=80` 现在是字面量必然存在；升级上游后可能消失并抛 `ValueError` |
| `virtual_desktop.XPRA_HTML_ROOT_CANDIDATES` | `helpers/virtual_desktop.py:27-29`：`(Path("/usr/share/xpra/www"),)` | `desktop.py:192-196` 前置 `/app/share/xpra/www` | **匹配**（tuple 与 Path 比较可用） |
| `XPRA_START_ENV` | `virtual_desktop.py:30-33`：dict | `desktop.py:284,301` 展开 | **匹配** |
| `virtual_desktop.collect_status` | `:156-193`，零参，返回 `binaries`/`packages`/`xpra_html_root` | `desktop.py:203-220` 覆写 | **匹配** |

**处理**：

- 删除 `_patch_state_dirs()` 及其调用（上游在 `base_dir.apply()` 之后导入，`STATE_DIR`/`SESSION_DIR`/`PROFILE_DIR` 天然在可写根，三者保持一致）。
- `--encoding=png` 的插入改为无异常写法：锚点存在则插在其后，否则追加。
- 无头路径把 `session.display` 设为 `desktop_session.DISPLAY_BASE`（120），与 `start-desktop :{display}` 及后续 `_display_env` 的 `DISPLAY` 一致（原实现写 0，但 Xpra 起在 120）。
- `virtual_desktop.collect_status` 的覆写同步设置 `missing`，避免 `healthy: True` 与 `missing: ["Xvfb", …]` 自相矛盾。
- 未改动 `_allocate_endpoint_locked` 的 host-display 语义。

**已知限制（未改）**：主机 `DISPLAY=:0` 时 `_load_system_desktop_from_manifest_locked:656` 的 `if not display` 会拒绝 rehydrate，重启后可能留下旧 xpra 进程；见存疑 2。

结论：**符号全部存在；修掉破坏 `PROFILE_DIR` 不变量的补丁、无头显示号错配、`missing` 自相矛盾，并加固参数插入。**

---

## 11. `helpers/files._base_dir`

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `_base_dir` | `helpers/files.py:23`：`_base_dir = os.path.dirname(os.path.abspath(os.path.join(__file__, "../")))` | `base_dir.py:51` 赋值为可写根 | **匹配** |
| 解析函数 | `files.py:576-583`：`_resolve_path` 直接读模块全局 `_base_dir`；`get_abs_path` 调用它 | 调用时动态查找 | **匹配**（在函数体内引用全局，赋值后立即生效） |
| `usr/...` 使用 | `:610-612` 的 `normalize_a0_path`、`get_base_dir()`（`:640-641`）等 | 所有 `usr/` 解析经 `get_abs_path` | **匹配** |
| 种子复制 | `base_dir.py:45-50` 复制 `conf/prompts/agents/knowledge/instruments/usr`；launcher 另复制 `webui/api/plugins/extensions` | docstring 旧称“launcher 做种子，本模块只报告目录” | **文档不匹配**：模块自己也复制；已改写 docstring |

结论：**符号与语义匹配；修正文档。**（`api/webui/plugins/extensions` 仍由 launcher 负责；直接跳过 launcher 启动时这些目录不会自动补齐——见存疑 10。）

---

## 12. `packages.py` / `code_exec.py` / `rfc_loop.py`

| 目标符号 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `plugins._kokoro_tts.hooks.ensure_dependencies/install` | `hooks.py:34-60`，`(raise_on_error=True) -> bool` / `() -> bool` | `packages.py:22-29` 置为 `noop(*args, **kwargs) -> True` | **符号匹配**；但 `call_plugin_hook` 用 `helpers/modules.py:12-24` 按路径加载**新模块对象**（`module_name="hooks"`，不写入 `sys.modules`），包模块上的替换到不了该副本 |
| `plugins._context_doctor.hooks.*` | `hooks.py:21-60` | 同上 | **同上** |
| `plugins._document_query.hooks.*` | `hooks.py:25-60` | 同上 | **同上** |
| `plugins._desktop.hooks.cleanup_stale_runtime_state` | `hooks.py:96`，`(force=False) -> dict` | `packages.py:70-74` 返回 `_cleanup_result(runtime="host-desktop")` | **匹配且有效**：`_20_desktop_routes.py:9` 是 `from plugins._desktop import hooks`，与补丁同一模块对象 |
| `plugins._office.hooks.cleanup_stale_runtime_state` | `hooks.py:75` | `packages.py:77-89` 包装原函数并 `setdefault("skipped", True)` | **匹配且有效**（`_20_office_routes.py:8` 直接 import） |
| `helpers.plugins.get_plugin_config` | `helpers/plugins.py:624-678`，`(plugin_name, agent=None, project_name=None, agent_profile=None, caller="api")` | `code_exec.py:31-55` `(name, *args, **kwargs)` 包装 | **匹配**：`code_execution_tool.py:606` 在运行时 `plugins.get_plugin_config(...)`，属性查找命中补丁 |
| `helpers.runtime.is_development` | `helpers/runtime.py:63-64` | `rfc_loop.py:22` 赋 `lambda: False` | **匹配**：`job_loop.py:20`、`files.py:610`、`print_style.py:185` 都在调用时属性查找 |

**处理**：在 `packages.py` 增加 `helpers.plugins.call_plugin_hook` 包装，对同一组 `(plugin, hook)` 返回 `True`；保留原有的包模块替换，覆盖直接 import 的调用方。

结论：**符号全部存在；发现并修掉 `call_plugin_hook` 模块身份错配。**

---

## 13. `run_ui.py` 的命令行参数

| 项 | 上游真实代码 | 我方假设 | 结论 |
|---|---|---|---|
| `--port` | `helpers/runtime.py:28`：`parser.add_argument("--port", type=int, default=None, …)` | launcher `--port=5080` | **匹配** |
| `--host` | `helpers/runtime.py:29`：`parser.add_argument("--host", type=str, default=None, …)` | launcher `--host=127.0.0.1` | **匹配** |
| 解析方式 | `:40-46` `parse_known_args()` + 未知参数按 `--key=value` 塞入 `args` | `=value` 形式 | **匹配** |
| 触发 `__main__` | `run_ui.py:99-102` | `runpy.run_path(..., run_name='__main__')` | **匹配** |
| 缺省值 | 端口 `5000`（`:174`）、主机 `localhost`（`run_ui.py:33`） | launcher 固定 `5080` / `127.0.0.1` | **有意偏离**，非缺陷 |
| `--dockerized` | 未传；`is_dockerized()=False` | `rfc_loop` 只补了 `is_development()` | **存疑/隐式契约**：见第 0 节 |

结论：**`--port`/`--host` 均存在且解析正确，无需修改。**

---

## 14. `requirements-flatpak.txt` 与 `overrides.txt`

### 14.1 override 格式

`overrides.txt:1-9` 逐行：

```
# Overrides for the Flatpak build.
#
# langsmith caps zstandard below 0.24, but no zstandard release in that range
# has a CPython 3.14 wheel. The API used by langsmith is unchanged in 0.25.
zstandard>=0.25

# unstructured caps numpy below 2, but no numpy 1.x release has a CPython 3.14
# wheel. The partitioners used here run on numpy 2.
numpy>=2.1
```

| 检查 | 结论 |
|---|---|
| 是否 `uv pip install --override` 接受的形式 | **是**：7 行注释 + 1 空行 + 2 条 PEP 508 requirement；`--override` 是 `--overrides` 的合法别名 |
| `>=` 是否合法 | **是**，但 override 是“绝对替换”语义，不构成 pin；要可复现应写 `==` |
| 是否存在格式非法行 | **无** |
| 被限制的包是否出现 | 断言需修正：`overrides.txt` **只限制 `zstandard`、`numpy`，不含 `langsmith`、`unstructured`**；后两者是“施加约束的包”，由 override 放宽它们对 `zstandard`/`numpy` 的上限。`langsmith`/`numpy`/`zstandard` 在 requirements 中均无直接行，靠 `langchain-core`/`litellm`/`unstructured` 传递引入；`unstructured` 在 `:63` |

`flatpak/README.md:121` 的表述（“langsmith 和 unstructured 把 zstandard、numpy 压低”）与实际一致；`requirements-flatpak.txt:25` 曾引用不存在的 `flatpak/numpy-override.txt`，已改为 `overrides.txt`。

### 14.2 与上游 requirements 的关键冲突

| # | 上游 `requirements.txt` | `requirements-flatpak.txt` | 结论 |
|---|---|---|---|
| 1 | `:36 tiktoken==0.8.0` | `:62 tiktoken>=0.12.0,<1.0` | **有意偏离**（README:135，litellm 在 3.14 的下限） |
| 2 | `:43 pydantic==2.11.7` | `:69 pydantic>=2.12.0,<3.0.0` | **有意偏离**（README:136） |
| 3 | `:37 unstructured[all-docs]==0.16.23` | `:63 unstructured==0.16.23` | **版本相同、extras 删除**；`parsers.py` 仍首选核心 `partition()`，失败才回退（设计内） |
| 4 | `:41` 与 `:47` 重复 `crontab==1.0.1` | `:67` 一条 | **上游自身重复**，此处去重 |
| 5 | `:55 chardet<6` | `:80` 同字 | **一致** |
| 6 | `:10 flask-basicauth==0.2.0` | `:27` 同字（被移到最前） | **一致**；曾有的“两阶段安装”注释已删（launcher 只有一条 `uv pip install`） |
| 7 | `:21 langchain-unstructured==0.1.6` | 删除 | **匹配**：`parsers.py:198-204` 替换了唯一使用点 |
| 8 | `:6 faiss-cpu==1.11.0` | 删除 | **匹配（但 shim 需完整）**：见第 4 项，已补 `remove_ids` |
| 9 | `:35 sentence-transformers==3.0.1` | 删除 | **匹配**：`embeddings.py` 替换工厂 |
| 10 | `:17 kokoro>=0.9.2` | 删除 | **匹配**：`speech.py` 替换 TTS 入口；`soundfile` 保留 |
| 11 | `:25 openai-whisper==20250625` | 删除 | **匹配**：`speech.py:149` 先注册 `whisper` stub，再导入顶层 `import whisper` 的运行时 |
| 12 | `:29 newspaper3k==0.2.8` | 删除 | **匹配**：上游无 `import newspaper`（死依赖） |
| 13 | `:57 pywinpty==3.0.2; sys_platform=="win32"` | 删除 | **匹配**：Linux 构建无用 |
| 14 | 无 | 曾新增 `stealth-browser`、`nodriver` | **已删除**：上游不调用，见第 9 项 |

结论：**override 格式合法；清单第 14 项对“限制的包”的表述不准确，但文件本身无需结构性改动；仅修正了 3 处注释与 2 条死依赖。**

---

## 15. `agent-zero.sh` 的路径 vs manifest

前提：`org.agentzero.AgentZero.yml:170-173` 的 dir source 是 `path: ..`，`. =` 上游 checkout 根；`scripts/build.sh:29` 先把 `flatpak/` 拷进去，`:65` 在其中执行 `flatpak-builder`。`cwd` 必须是上游 checkout。

| # | launcher 行 | 内容 | manifest/构建证据 | 结论 |
|---|---|---|---|---|
| 1 | `:15` | `APP_ROOT=/app/share/agent-zero` | `yml:160-161` `mkdir -p` + `cp -a . /app/share/agent-zero/` | **匹配** |
| 2 | `:16,85,94` | `/app/share/python-deps` | `yml:59-61`（gi/cairo）、`:86-87`（xpra） | **匹配** |
| 3 | `:86` | `/app/lib/gi` | `yml:64-65` | **匹配** |
| 4 | `:100-101` | `/app/bin/uv` | `yml:46` | **匹配** |
| 5 | `:102` | `--override "$APP_ROOT/flatpak/overrides.txt"` | `cp -a .` 带入 `flatpak/overrides.txt` | **匹配** |
| 6 | `:103` | `-r "$APP_ROOT/flatpak/requirements-flatpak.txt"` | 同上 | **匹配** |
| 7 | `:53,55` | `flatpak/prompts/agent.system.main.environment.md` | 文件存在于 `a0lite/flatpak/prompts/`；`cp -a .` 带入 | **匹配** |
| 8 | `:19` | `/app/share/agent-zero/models` | `yml:163` + `:29` 扩展点 + `Models.yml:55,57,70` | **匹配** |
| 9 | `:22,119` | `$MODELS_ROOT/bin/ollama` | `Models.yml:55` | **匹配** |
| 10 | `:70` | `$MODELS_ROOT/models` | `Models.yml:70` | **匹配** |
| 11 | `:74` | `$MODELS_ROOT/lib/ollama` | `Models.yml:57` | **匹配** |
| 12 | `:73` | `/app/share/agent-zero/cuda` | `yml:164` + `:37` + `Cuda.yml:14` | **匹配** |
| 13 | `:74` | `$CUDA_ROOT/cuda_v12` | `Cuda.yml:56` | **匹配** |
| 14 | `:74` | `$CUDA_ROOT/cuda_v13` | `Cuda.yml:57` 显式 `rm -rf …/cuda_v13` | **不匹配（死路径，无害）** |
| 15 | `:31,37-39` | `mkdir -p "$BASE_DIR/usr/plugins"`；`if [ ! -f "$BASE_DIR/usr/.env" ] && [ -f "$APP_ROOT/usr/.env" ]` | 上游 `usr/` 无 `.env`（只有 `.gitkeep`、`agents/`、`knowledge/`、`plugins/`、`skills/`、`workdir/`） | **不匹配**：条件恒假，整个 `usr/` 从不 seed；`usr/workdir`（`settings.py:604` 的默认工作目录）不会出现 |
| 16 | `:32` | `for name in conf prompts agents knowledge instruments webui` | 上游顶层无 `instruments/`（`.gitignore:22` 忽略） | **不匹配（空转）**：`[ -d ]` 保护，不报错 |
| 17 | `:45-46` | `if [ ! -e /a0 ] && [ -w / ]; then ln -s "$BASE_DIR" /a0` | 无 manifest 对应；沙箱 `/` 通常只读 | **存疑（高危）**：`/a0` 被 `message_queue.py:13`、`get_work_dir_files.py:20`、`settings.py:604` 真实使用 |
| 18 | `:62-67` | 合并 `api plugins extensions` | 上游三者存在；`cp -a .` 已带入 | **匹配** |
| 19 | `:148-153` | `cd $APP_ROOT` + `runpy.run_path('run_ui.py')` + `--port/--host` | `run_ui.py` 在 dir 源根 | **匹配** |
| 20 | `:8-11,149-150` | `python -c` 作为解释器入口 | `python -c` 的 `sys.argv[0] == "-c"`，argparse 正常 | **匹配** |

**处理**：

- `usr` 种子条件改为 `[ ! -e "$BASE_DIR/usr/.gitkeep" ] && [ -d "$APP_ROOT/usr" ]`，使上游 `usr/` 真正被复制（含 `workdir`、`skills` 等）。
- 未改 `cuda_v13`（无害）与 `instruments`（有 `-d` 保护）。

结论：**主路径全部匹配；修掉 `usr` 种子门控。`/a0` 是本项最大的运行期风险。**

---

## 已改动文件

### 1. `flatpak/a0flatpak/ocr.py`

**before**

```python
def _parse_pdf_with_fallback(original: Any):
    def parse(document: Any, config: dict) -> str:
        text = original(document, config)
```

**after**

```python
def _parse_pdf_with_fallback(original: Any):
    def parse(self, document: Any, config: dict) -> str:
        # The original extractor is the optional strategy here: PyMuPDF and the
        # Tesseract fallback both fail when their native pieces are absent, and
        # that is exactly when the Ollama pass below must take over.
        try:
            text = original(self, document, config)
        except Exception:
            text = ""
        if isinstance(text, str) and text.strip():
            return text
        if not config.get("pdf_ocr_fallback", True):
            return text if isinstance(text, str) else ""
```

理由：类属性上的普通函数会被描述符绑定，`self._parse_sync(document, config)` 会传 3 个位置参数；`original` 是未绑定函数，必须补 `self`。原实现两处都缺，必然 `TypeError`，且 Ollama 回退不可达。补上 `pdf_ocr_fallback` 检查，与上游 `pdf.py:19` 的配置语义一致。

### 2. `flatpak/a0flatpak/desktop.py`

**before**

```python
        command = desktop_session._xpra_shadow_command(xpra, session)
        command = [arg for arg in command if not arg.startswith("--encoding=")]
        command.insert(command.index("--speed=80") + 1, "--encoding=png")
```

**after**

```python
        command = desktop_session._xpra_shadow_command(xpra, session)
        command = [arg for arg in command if not arg.startswith("--encoding=")]
        anchor = command.index("--speed=80") + 1 if "--speed=80" in command else len(command)
        command.insert(anchor, "--encoding=png")
```

理由：上游 `_xpra_shadow_command`（`desktop_session.py:1851-1879`）当前确有 `--speed=80`（`:1874`），但该函数是字面量列表，升级后可能消失；`index()` 无保护会直接 `ValueError`。新写法保持“插在 `--speed` 之后”的语义，缺失时追加。

无头路径与状态负载：

```python
-        session.display = _display_number(host) if host else 0
+        session.display = (
+            _display_number(host) if host else desktop_session.DISPLAY_BASE
+        )

+        status["missing"] = missing
```

理由：`start-desktop` 实际用 `:{session.display or 120}`，原实现把 `session.display` 写成 0，导致后续 `_display_env` 的 `DISPLAY=:0` 与真实 `:120` 不一致；`virtual_desktop.collect_status` 的 `missing` 也必须同步覆写，否则 `healthy: True` 与 `missing: ["Xvfb", …]` 同时出现。

**同时删除** `_patch_state_dirs()` 及 `apply()` 中的调用：

```python
-def _patch_state_dirs() -> None:
-    ...
-    desktop_session.STATE_DIR = state_dir
-    desktop_session.SESSION_DIR = state_dir / "sessions"
-    desktop_session.SESSION_DIR.mkdir(parents=True, exist_ok=True)
-    desktop_session._a0flatpak_state_patched = True
-
...
-    _patch_state_dirs()
```

理由：`base_dir.apply()` 已先于 `desktop_session` 导入执行，`STATE_DIR/SESSION_DIR/PROFILE_DIR` 在导入时就是 `$A0_BASE_DIR/usr/plugins/_desktop/...`；旧补丁把 `STATE_DIR` 改到 `$BASE/plugins/_desktop`（插件代码目录），却漏改 `PROFILE_DIR`，导致 `_ensure_system_desktop_locked:617` 仍用只读路径，`mkdir` 失败。

### 3. `flatpak/a0flatpak/speech.py`

**before**

```python
    async def is_downloaded(config: dict[str, Any] | None = None) -> bool:
        return True

    def is_updating(config: dict[str, Any] | None = None) -> bool:
        return False

    tts_runtime.synthesize_sentences = synthesize_sentences
    tts_runtime.is_downloaded = is_downloaded
    tts_runtime.is_updating = is_updating
```

**after**

```python
    response = httpx.post(
        f"{OLLAMA_URL}/v1/audio/speech",
        json={
            "model": SPEECH_MODEL,
            "input": text,
            "voice": SPEECH_VOICE,
            "response_format": "wav",
        },
        timeout=SPEECH_TIMEOUT,
    )

    async def is_downloaded(config: dict[str, Any] | None = None) -> bool:
        return True

    tts_runtime.synthesize_sentences = synthesize_sentences
    tts_runtime.is_downloaded = is_downloaded
```

理由：上游没有 `is_updating`（只有变量 `is_updating_model` 和 `is_downloading()`），全仓无消费方，注入是无效代码。请求补 `response_format: "wav"`，因为 `plugins/_kokoro_tts/api/synthesize.py:19` 与 `webui/js/tts-service.js:290` 固定按 `audio/wav` 播放。

### 4. `flatpak/a0flatpak/serve.py`

**before**：包装后调用 `health.register(webapp)`，并在 `key` 为空时也包装。

**after**

```python
    def run_uvicorn_with_retries(*args, **kwargs):
        build = kwargs.get("build_asgi_app")
        if build is not None and key:
            from a0flatpak import auth

            def build_wrapped(startup_monitor):
                return auth.AuthMiddleware(build(startup_monitor), key)

            kwargs["build_asgi_app"] = build_wrapped

        return original(*args, **kwargs)
```

理由：`api/health.py` 已提供 `/api/health`（200、`requires_auth=False`）；在 Flask 上再注册精确规则会遮蔽它并丢掉 `gitinfo`。鉴权包装只在 `A0_AUTH_KEY` 非空时安装。

### 5. `flatpak/a0flatpak/health.py`

**删除**（29 行）。理由同 4；无其他引用。

### 6. `flatpak/a0flatpak/vector_store.py`

**before**

```python
        def reconstruct_n(self, start: int, count: int) -> Any:
            return self._vectors[int(start) : int(start) + int(count)]

        def __len__(self) -> int:
            return self.ntotal
```

**after**

```python
        def reconstruct_n(self, start: int, count: int) -> Any:
            return self._vectors[int(start) : int(start) + int(count)]

        def reconstruct(self, index: int) -> Any:
            return self._vectors[int(index)]

        def remove_ids(self, ids: Any) -> int:
            """Drop rows by index. ``FAISS.delete`` calls this after a delete."""
            keep = np.ones(self.ntotal, dtype=bool)
            keep[np.asarray(ids, dtype="int64")] = False
            removed = self.ntotal - int(keep.sum())
            self._vectors = self._vectors[keep]
            self.ntotal = len(self._vectors)
            return removed

        def __len__(self) -> int:
            return self.ntotal
```

并把 `apply()` 的两段 `if existing` 合并：

```python
    existing = sys.modules.get("faiss")
    if existing is not None:
        return
```

理由：`langchain_community/vectorstores/faiss.py:940` 的 `delete()` 必须调用 `self.index.remove_ids(...)`；上游 `_memory` 在 `memory.py:416/427/436/464/492` 大量 `adelete`，没有该方法会直接 `AttributeError`。`reconstruct` 覆盖 MMR 路径（`:720`）。

### 7. `flatpak/a0flatpak/browser.py`

**删除** `_patch_stealth_browser()` 与 `apply()` 中的调用；改写顶层 docstring 为 Patchright + `executable_path`。

理由：上游没有 `stealth_browser`/`nodriver` 的任何引用；真实启动路径是 `plugins/_browser/helpers/runtime.py:1145,1188`。保留 `prepare_playwright_cache`/`install` 的 hooks 替换即可。

### 8. `flatpak/a0flatpak/packages.py`

**新增**

```python
_NOOP_CALL_HOOKS = frozenset(
    (module_path.split(".")[1], attribute)
    for module_path, attribute in _NOOP_PLUGIN_HOOKS
)

def _patch_call_plugin_hook() -> None:
    from helpers import plugins
    if getattr(plugins, "_a0flatpak_hooks_patched", False):
        return
    original = plugins.call_plugin_hook

    def call_plugin_hook(plugin_name, hook_name, default=None, *args, **kwargs):
        if (plugin_name, hook_name) in _NOOP_CALL_HOOKS:
            return True
        return original(plugin_name, hook_name, default, *args, **kwargs)

    plugins.call_plugin_hook = call_plugin_hook
    plugins._a0flatpak_hooks_patched = True
```

并在 `apply()` 首行调用。理由：`helpers/modules.py:12-24` 用 `spec_from_file_location` 加载钩子文件，`module_name` 只是 `"hooks"` 且不写入 `sys.modules`；`helpers/plugins.py:917-946` 的 `call_plugin_hook` 因此拿到的是新模块对象，包模块上的 `noop` 替换不会生效。`_kokoro_tts` 启动迁移（`_20_tts_dependencies.py:7`）会真实执行 `uv pip install onnxruntime`。

### 9. `flatpak/a0flatpak/__init__.py`

在 `base_dir.apply()` 之后新增：

```python
    from helpers import dotenv

    dotenv.load_dotenv()
```

理由：各补丁模块在导入时读取 `OLLAMA_HOST`、`A0_EMBEDDING_MODEL`、`A0_OCR_MODEL`、`A0_SPEECH_MODEL` 等；`run_ui.py:101` 的 `load_dotenv()` 来得太晚。

### 10. `flatpak/a0flatpak/base_dir.py`

docstring 由“只报告目录，launcher 负责种子”改为“launcher 预种子；`apply` 补齐缺失目录并重定向解析器”，与 `base_dir.py:45-52` 的实际行为一致。

### 11. `flatpak/agent-zero.sh`

**before**

```bash
if [ ! -f "$BASE_DIR/usr/.env" ] && [ -f "$APP_ROOT/usr/.env" ]; then
    cp -a "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
fi
```

**after**

```bash
if [ ! -e "$BASE_DIR/usr/.gitkeep" ] && [ -d "$APP_ROOT/usr" ]; then
    cp -a "$APP_ROOT/usr/." "$BASE_DIR/usr/" 2>/dev/null || true
fi
```

理由：上游 `usr/` 没有 `.env`，旧条件恒假；`usr/workdir`（默认工作目录）永远不会被 seed。`.gitkeep` 是 bundle 自带标记，复制后即存在，可防止每次启动重复复制。

### 12. `flatpak/requirements-flatpak.txt`

- `:7`：`vector index replaced by an Ollama-backed store` → `vector index replaced by a numpy-backed shim`（实现是 numpy，不是 Ollama）。
- `:14`：`document parsing moves to Ollama vision models` → `extras dropped; core partitioner stays, Ollama covers images and scanned pages`（`parsers.py` 仍首选 `unstructured.partition.auto`）。
- `:26`：`flatpak/numpy-override.txt` → `flatpak/overrides.txt`（前者不存在）。
- 删除 `:26-28` 的“两阶段安装”注释（launcher 只有一条 `uv pip install`）。
- 删除 `stealth-browser==0.2.0`、`nodriver>=0.48,<0.51`（上游不调用）。

### 13. `flatpak/README.md`

`| plugin/ | built-in plugin… |` → `| prompts/ | environment prompt override |`。`flatpak/plugin/` 不存在；WPS 相关文件由 `wps-*` 与 Wps 扩展承担。

---

## 存疑项（静态无法判定，必须实机确认）

1. **`/` 是否可写 → `/a0` 是否建立**。`agent-zero.sh:45-46` 只在 `[ -w / ]` 时建链，而 `helpers/message_queue.py:13`（`/a0/usr/uploads`）、`api/get_work_dir_files.py:20`（`/a0`）、`helpers/settings.py:604`（默认 `workdir_path`）都真实依赖它。Flatpak 沙箱的 `/` 通常只读。**这是构建前最该当心的一点。**
2. **`DISPLAY=:0` 的会话 rehydrate**。`_load_system_desktop_from_manifest_locked`（`desktop_session.py:656`）用 `if not display` 拒绝 0；主机 display 恰为 0 时，重启后旧 xpra 进程可能残留、新会话另起端口。未改（需要重写上游加载器或改变 manifest 语义）。
3. **Xpra 编码**。补丁在服务端参数里放 `--encoding=png`，但 `virtual_desktop.session_url`（`helpers/virtual_desktop.py:121-155`）默认 `encoding="jpeg"`，HTML5 客户端会从 URL 请求 jpeg；headless 分支没有 `--encoding=png`。这是“参数存在但可能不生效”的语义问题，需要实际打开 Desktop 画布观察编码协商。
4. **Ollama 语音端点与模型**。`speech.py` 请求 `/v1/audio/speech`、`/v1/audio/transcriptions`，模型默认 `lfm3-omni:2b-q4_K_M`；仓库自己的 `docs/setup/host-ollama.md` 标注为 “Unverified behaviour”，且模型卡未列音频输入。符号契约成立，服务能力未知。
5. **Embedding 模型名映射**。`provider="huggingface"` 且 `name` 不以 `sentence-transformers/` 开头时，原名会被当作 Ollama 模型名发送，可能 404；`DEFAULT_EMBEDDING_MODEL=qwen3-embedding:4b-q4_K_M` 是否已拉取未知。另：`VectorDB.__init__` 调用 `embed_query("example")` 取维度，Ollama 未启动时初始化失败。
6. **faiss shim 的剩余表面**：`normalize_L2`、`IndexFlatL2`、`IndexFlat.merge_from` 未实现；当前上游路径不可达（`normalize_L2=False`、不走 `from_embeddings`、不调 `merge_from`），但 `langchain` 升级或未来调用会命中。`types.ModuleType("faiss")` 的 `__spec__` 为 `None`，若依赖执行 `find_spec("faiss")` 会抛 `ValueError`。
7. **`unstructured` 去 extras 后的 `partition()`**：`parsers.py` 把它当第一策略；PDF/图片可能因缺少 `pdfminer.six` 等可选依赖抛异常并落到 Ollama 回退（设计允许），但解析质量与耗时需实测。
8. **`uv` 解析**：`numpy>=2.1` 与 `unstructured==0.16.23` 的 `numpy<2`、`zstandard>=0.25` 与 `langsmith<0.4` 的上限，必须靠 `uv pip install --dry-run` 或真实安装验证；`tiktoken>=0.12,<1.0` 与 `litellm==1.104.0` 同样。
9. **鉴权中间件与 Socket.IO/WebSocket**：`AuthMiddleware` 包在 `ASGIApp(socketio, other_asgi_app=...)` 外层，cookie/bearer 校验逻辑对 websocket 走 `websocket.close`；需要实际开 UI、带 key 和不带 key 各试一次。
10. **跳过 launcher 的启动路径**：`base_dir.apply()` 只补齐 `conf/prompts/agents/knowledge/instruments/usr`，不补 `api/plugins/extensions/webui`；launcher 才复制这些。直接 `python -c "import a0flatpak; a0flatpak.apply(); …"` 会缺 API 路由与前端资源（`systemd/a0-desktop-start` 依赖 launcher 已 seed 的目录）。
11. **`preload.py` 未被执行**：launcher 不调用它，`migration.migrate_dotenv()` 与 `settings.set_root_password()` 被跳过；当前依赖 `run_ui.py:101` 的 `dotenv.load_dotenv()`，行为是否等价需实测。
12. **`_neutralise_module` 的 stub**：`whisper`/`soundfile`/`kokoro` 被注册为空模块；已静态确认上游只在函数内使用 `whisper.load_model`、`kokoro.KPipeline`、`sf.*`，补丁函数不触碰它们；但任何未覆盖的路径（如 kokoro `preload`）会 `ImportError`。
13. **文档解析的 60 秒总超时**：`plugins/_document_query/helpers/document_query.py:468` 默认 `per_document_timeout=60`，`parsers/base.py:40-59` 用 `asyncio.wait_for` 包住整个 `_parse_sync`；而 `parsers.py:31` 的 `A0_OCR_TIMEOUT` 默认 300 秒/页。多页扫描件会在第一页尚未返回时被外层判超时。需要调小 `A0_OCR_TIMEOUT`、减少渲染页数，或提高插件的 `per_document_timeout`；属配置问题，不是符号问题。
14. **`_office` 的 cleanup 仍执行原始逻辑**：`packages.py:104-113` 的 `office_cleanup` 调用 `original(force=force)`。上游 `_office/hooks.py:383-399` 的 `dpkg-query` 分支有 `shutil.which` 保护，`:410-470` 的 apt 分支在非 root / 无 `apt-get` 时早退，`_kill_old_processes`/`_retire_supervisor_program` 也各自检查 `pkill`/`supervisorctl`；因此 Flatpak 中不会真的安装包，只会执行迁移与进程清理。模块 docstring 的“document-level cleanup keeps original behaviour”已限定这一取舍；启动不受影响。
15. **旧 faiss 索引没有降级**：`vector_store.py:78-80` 的 `read_index` 遇到真 faiss 文件直接 `ValueError`；`_memory/helpers/memory.py:180-193` 在哈希校验通过后直接 `load_local`，没有“读不了就重建”的分支。从旧镜像带过来的 `index.faiss` 会让记忆初始化失败一次；删掉该文件即可重建。
16. **`/desktop` 的双重鉴权**：`A0_AUTH_KEY` 通过 `AuthMiddleware` 后，`VirtualDesktopGateway.is_authorized` 仍要求 Flask 登录会话（`helpers/virtual_desktop_routes.py:380-402`）。只用 key、不走 `/login` 的客户端访问 `/desktop` 仍会 401。这是上游行为，补丁未改。

---

## 清单外发现（未改，供决策）

- `desktop.py` 的 `_patch_desktop_status` / `_patch_status_checks` 只把 `xpra`、`xpra-html5` 计入 `missing`，`collect_desktop_status` 仍会计算 `soffice/thunar/xfce4-*` 并写进 `binaries`；这是刻意降级，不是符号问题。
- `browser.py` 的 `install()` 现在返回 `prepare_playwright_cache()` 的 dict，键集合与上游 `cleanup_playwright_cache()` 不完全相同（缺 `primary`、`migrated`）；消费方不读这两键，但日志函数会因此少打一条 info。
- `flatpak/README.md:122` 的 “every entry resolves to a wheel except two pure-Python sdists” 仍然准确（`flask-basicauth`、`crontab`），但与已删除的“两阶段安装”注释不再配套。
- `Cuda.yml:23` 与 `Models.yml:25` 的注释把扩展挂载点写成 `lib/ollama`，实际是 `share/agent-zero/cuda` 与 `models/lib/ollama`；代码正确，注释过期。
- `agent-zero.sh:74` 的 `cuda_v13` 与 `:32` 的 `instruments` 是无害死路径；未改，避免扩大 diff。
